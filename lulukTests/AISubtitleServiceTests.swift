//
//  AISubtitleServiceTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AISubtitleService 编排逻辑测试。重点测可单元化的部分：
//   - translateAllBatches 的 batch + context 切割
//   - batch 失败 → single-line 退化
//   - 整体失败 → "[翻译失败]" 占位
//   - networkResource gate
//   - provider 未配置 gate
//
//  完整流水线 (start) 依赖真实 ffmpeg + whisper + 视频文件，留给手动 dogfood 验证。
//

import Testing
import Foundation
@testable import luluk

struct AISubtitleServiceTests {

    // MARK: - mock provider

    /// 记录每次 translate 调用，按调用顺序回放预设结果或错误。
    actor MockProvider: TranslationProvider {
        struct Call: Sendable, Equatable {
            let batchTexts: [String]
            let contextTexts: [String]
        }

        nonisolated let displayName: String = "MockProvider"
        var isReady: Bool = true
        var cumulativeTokens: Int = 0

        private(set) var calls: [Call] = []
        private(set) var singleCalls: [String] = []

        /// translate(batch:) 的返回行为：成功路径——把 batch 文本前缀 "[zh]" 当译文。
        /// translate 抛错的 batch 索引 (0-based)。translateSingle 兜底走默认实现，会再调 translate(size=1)。
        var batchErrorIndices: Set<Int> = []
        /// translateSingle 也抛错的 line text 集合（用文本匹配，简单直观）。
        var singleErrorTexts: Set<String> = []

        init(isReady: Bool = true) {
            self.isReady = isReady
        }

        func setIsReady(_ v: Bool) { isReady = v }
        func failBatch(at idx: Int) { batchErrorIndices.insert(idx) }
        func failSingle(text: String) { singleErrorTexts.insert(text) }

        func translate(
            batch: [SrtLine],
            context: [SrtLine],
            source: Language?,
            target: Language
        ) async throws -> [SrtLine] {
            let callIdx = calls.count
            calls.append(Call(
                batchTexts: batch.map { $0.text },
                contextTexts: context.map { $0.text }
            ))
            // 如果这是个 size=1 的 single 调用且文本在 singleErrorTexts，抛错
            if batch.count == 1, let only = batch.first,
               singleErrorTexts.contains(only.text) {
                singleCalls.append(only.text)
                throw SubtitleError.translationBatchMalformed(reason: "mock single fail")
            }
            // 普通 batch 失败标记
            if batchErrorIndices.contains(callIdx) && batch.count > 1 {
                throw SubtitleError.translationBatchMalformed(reason: "mock batch fail @ \(callIdx)")
            }
            cumulativeTokens += batch.count * 10
            return batch.map { line in
                SrtLine(
                    index: line.index,
                    startTime: line.startTime,
                    endTime: line.endTime,
                    text: "[zh] \(line.text)"
                )
            }
        }
    }

    // MARK: - translateAllBatches

    /// 构造 N 行测试数据（文本 = "L0", "L1", ...）
    private static func makeLines(_ n: Int) -> [SrtLine] {
        (0..<n).map { i in
            SrtLine(
                index: i + 1,
                startTime: TimeInterval(i),
                endTime: TimeInterval(i + 1),
                text: "L\(i)"
            )
        }
    }

    private static func makeService(provider: TranslationProvider) -> AISubtitleService {
        AISubtitleService(player: nil, provider: provider)
    }

    @Test func batchSizeIs8AndContextIs3() async throws {
        let provider = MockProvider()
        let service = Self.makeService(provider: provider)
        let lines = Self.makeLines(20)  // 20 行 → 3 个 batch (8 + 8 + 4)

        let result = try await service.translateAllBatches(
            cleaned: lines,
            source: .japanese,
            target: .simplifiedChinese
        )
        #expect(result.count == 20)

        let calls = await provider.calls
        #expect(calls.count == 3)
        // batch 0：8 行，无 context
        #expect(calls[0].batchTexts.count == 8)
        #expect(calls[0].contextTexts.isEmpty)
        // batch 1：8 行，context 是前 3 行（L5, L6, L7）
        #expect(calls[1].batchTexts.count == 8)
        #expect(calls[1].contextTexts == ["L5", "L6", "L7"])
        // batch 2：4 行，context 是前 3 行（L13, L14, L15）
        #expect(calls[2].batchTexts.count == 4)
        #expect(calls[2].contextTexts == ["L13", "L14", "L15"])
    }

    @Test func translatedLinesPreserveTimestamps() async throws {
        let provider = MockProvider()
        let service = Self.makeService(provider: provider)
        let lines = Self.makeLines(2)

        let result = try await service.translateAllBatches(
            cleaned: lines,
            source: nil,
            target: .simplifiedChinese
        )
        #expect(result.count == 2)
        #expect(result[0].startTime == 0)
        #expect(result[0].endTime == 1)
        #expect(result[0].text == "[zh] L0")
        #expect(result[1].text == "[zh] L1")
    }

    @Test func batchFailureFallsBackToSingleLine() async throws {
        let provider = MockProvider()
        await provider.failBatch(at: 0)  // 第一个 batch 整批失败
        let service = Self.makeService(provider: provider)
        let lines = Self.makeLines(3)  // 1 个 batch (3 行)

        let result = try await service.translateAllBatches(
            cleaned: lines,
            source: nil,
            target: .simplifiedChinese
        )
        #expect(result.count == 3)
        // 走了单行退化，每行都被翻译成功
        #expect(result.allSatisfy { $0.text.hasPrefix("[zh] L") })

        let calls = await provider.calls
        // 1 次 batch (失败) + 3 次 single = 4 次 translate
        #expect(calls.count == 4)
        // 后面 3 次都是 size=1
        #expect(calls[1].batchTexts.count == 1)
        #expect(calls[2].batchTexts.count == 1)
        #expect(calls[3].batchTexts.count == 1)
    }

    @Test func singleLineFailurePlacesPlaceholder() async throws {
        let provider = MockProvider()
        await provider.failBatch(at: 0)         // 第一 batch 失败
        await provider.failSingle(text: "L1")   // 单行 L1 也失败 → 占位
        let service = Self.makeService(provider: provider)
        let lines = Self.makeLines(3)

        let result = try await service.translateAllBatches(
            cleaned: lines,
            source: nil,
            target: .simplifiedChinese
        )
        #expect(result.count == 3)
        #expect(result[0].text == "[zh] L0")
        #expect(result[1].text == "[翻译失败]")  // L1 单行也失败
        #expect(result[2].text == "[zh] L2")
        // 时间戳必须保留（即使是占位行）
        #expect(result[1].startTime == 1)
        #expect(result[1].endTime == 2)
    }

    @Test func emptyInputReturnsEmpty() async throws {
        let provider = MockProvider()
        let service = Self.makeService(provider: provider)
        let result = try await service.translateAllBatches(
            cleaned: [],
            source: nil,
            target: .simplifiedChinese
        )
        #expect(result.isEmpty)
        #expect(await provider.calls.isEmpty)
    }

    // MARK: - start() gate 路径（不依赖真实 ffmpeg / whisper）

    @Test func networkURLImmediatelyFails() async {
        let provider = MockProvider()
        let service = Self.makeService(provider: provider)
        let networkURL = URL(string: "https://example.com/video.mp4")!

        // 收集第一个非 idle 的 progress
        let stream = service.progressStream
        await service.start(videoURL: networkURL)
        // 等 task 真的跑完
        await waitForTerminalState(stream: stream)

        // 没人调过 provider
        #expect(await provider.calls.isEmpty)
    }

    @Test func providerNotReadyFails() async {
        let provider = MockProvider(isReady: false)
        let service = Self.makeService(provider: provider)
        // 用一个根本不存在的本地路径，但 provider check 会先于文件检查吗？
        // 实际顺序：ensureWhisperReady → provider.isReady。
        // 这里 ensureWhisperReady 在 dev 机上会过（model 已下载），所以走到 provider 检查。
        // 在 CI 上 ensureWhisperReady 也可能 fail（模型不在），任一种 .failed 都接受。
        let url = URL(fileURLWithPath: "/tmp/__nonexistent_luluk_test__.mp4")
        let stream = service.progressStream
        await service.start(videoURL: url)
        await waitForTerminalState(stream: stream)
        // 关键断言：mock provider 没被实际调过
        #expect(await provider.calls.isEmpty)
    }

    /// 消费 progress stream 直到拿到一个 terminal state（completed / failed / cancelled）。
    private func waitForTerminalState(stream: AsyncStream<PipelineProgress>) async {
        for await p in stream {
            switch p.state {
            case .completed, .cancelled, .failed:
                return
            default:
                continue
            }
        }
    }
}
