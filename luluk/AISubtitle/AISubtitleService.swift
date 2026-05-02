//
//  AISubtitleService.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕流水线顶层编排 actor。每个 PlayerCore 1 个实例。
//
//  数据流（对应 docs/AI_SUBTITLE_DESIGN.md §1.1）：
//      AudioSplitter → [AudioSegment]
//                        ↓ 段级并发 ≤ 3（service 内 semaphore）
//                        ↓ whisper 进程槽 ≤ 5（WhisperProcessPool 全局）
//                      WhisperRunner → TranscriptionResult
//                        ↓
//                      Sanitizer
//                        ↓ 切 batch=8 + context=3
//                      TranslationProvider.translate
//                        ↓
//                      SRTMerger.append（offset=0，因 WhisperRunner 已加绝对偏移）
//

import Foundation

actor AISubtitleService: ProgressReporter {

    // MARK: - 注入依赖

    /// 保留 player 的 weak ref，避免 service ↔ player 循环引用。
    /// M3 范围内 player 仅用于回调（暂未实现，留给 SubtitleFileWatcher 在 M5）。
    private weak var player: PlayerCore?

    /// 当前翻译 provider。M3 单 provider，M5 起会有切换 + fallback 链。
    private let provider: TranslationProvider

    /// whisper binary / 模型路径管理。M3 走 ensureWhisperReady 检查，缺文件 → fatal。
    private let modelDownloader: ModelDownloader

    /// 全局 whisper 进程槽池（多视频共享上限 5）。
    private let pool: WhisperProcessPool

    // MARK: - 段级并发 semaphore（service 本地，上限 3）

    /// SPEC §5.3 锁定：单视频内段级并发 = 3。
    private let maxConcurrentSegments = 3
    private var inUseSlots = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - 流水线运行时状态

    private var currentTask: Task<Void, Never>?
    private var sessionDir: URL?
    private var startedAt: Date?
    private var firstSubtitleAt: Date?

    // MARK: - 进度

    private var progress: PipelineProgress
    private let progressContinuation: AsyncStream<PipelineProgress>.Continuation

    /// 进度流，UI 订阅。nonisolated 让 MainActor 能直接拿到 stream。
    nonisolated let progressStream: AsyncStream<PipelineProgress>

    // MARK: - 初始化

    init(
        player: PlayerCore?,
        provider: TranslationProvider,
        modelDownloader: ModelDownloader = ModelDownloader(),
        pool: WhisperProcessPool = .shared
    ) {
        self.player = player
        self.provider = provider
        self.modelDownloader = modelDownloader
        self.pool = pool
        self.progress = .initial(provider: provider.displayName)

        // 建一对 stream + continuation。closure 只跑一次填 cont，之后 cont 长期持有。
        var capturedContinuation: AsyncStream<PipelineProgress>.Continuation!
        self.progressStream = AsyncStream<PipelineProgress> { c in capturedContinuation = c }
        self.progressContinuation = capturedContinuation
        self.progressContinuation.yield(self.progress)
    }

    // MARK: - 公开 API

    /// 启动流水线。如果已有正在跑的任务，先取消并 await 它结束再启新的。
    /// - Parameters:
    ///   - videoURL: 本地视频文件 URL。网络流应在调用前 gate（service 也会再校验一次）。
    ///   - sourceLanguage: nil = 让 whisper 自检（SPEC §7.6 不推荐，但 M3 没 UI 让用户选）。
    ///   - targetLanguage: V1 固定中文。
    func start(
        videoURL: URL,
        sourceLanguage: Language? = nil,
        targetLanguage: Language = .simplifiedChinese
    ) async {
        // 先停掉旧的（切换视频时）
        if let old = currentTask {
            old.cancel()
            await old.value
        }
        // 重置状态
        progress = .initial(provider: provider.displayName)
        startedAt = Date()
        firstSubtitleAt = nil
        progressContinuation.yield(progress)

        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.runPipeline(
                videoURL: videoURL,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
        self.currentTask = task
    }

    /// 取消当前流水线。fire-and-forget——cleanup 由 task 自己在 catch 路径完成。
    func cancel() {
        currentTask?.cancel()
    }

    // MARK: - 流水线主体

    private func runPipeline(
        videoURL: URL,
        sourceLanguage: Language?,
        targetLanguage: Language
    ) async {
        NSLog("%@", "[luluk-ai] runPipeline start: \(videoURL.path)")

        // 早期校验：本地文件
        guard videoURL.isFileURL else {
            NSLog("%@", "[luluk-ai] FAIL: not a file URL (\(videoURL.absoluteString))")
            updateState(.failed(.networkResourceNotSupported))
            return
        }

        // 1. 文件就绪
        let paths: WhisperPaths
        do {
            paths = try await modelDownloader.ensureWhisperReady()
            NSLog("%@", "[luluk-ai] whisper ready: bin=\(paths.binary.path) model=\(paths.model.path) vad=\(paths.vadModel.path)")
        } catch ModelDownloadError.binaryMissing(let searched) {
            NSLog("%@", "[luluk-ai] FAIL whisper binary missing, searched: \(searched.joined(separator: ", "))")
            updateState(.failed(.whisperBinaryMissing))
            return
        } catch let ModelDownloadError.modelMissing(p, _) {
            NSLog("%@", "[luluk-ai] FAIL whisper model missing: \(p)")
            updateState(.failed(.modelMissing(expectedPath: p)))
            return
        } catch let ModelDownloadError.vadModelMissing(p) {
            NSLog("%@", "[luluk-ai] FAIL VAD model missing: \(p)")
            updateState(.failed(.modelMissing(expectedPath: p)))
            return
        } catch {
            NSLog("%@", "[luluk-ai] FAIL ensureWhisperReady: \(error)")
            updateState(.failed(.modelMissing(expectedPath: error.localizedDescription)))
            return
        }

        // 2. provider 就绪
        let providerReady = await provider.isReady
        NSLog("%@", "[luluk-ai] provider \(provider.displayName) isReady=\(providerReady)")
        guard providerReady else {
            updateState(.failed(.providerNotConfigured(providerName: provider.displayName)))
            return
        }

        // 3. session 临时目录 + 输出 SRT 路径
        let session: URL
        do {
            session = try makeSessionDirectory(for: videoURL)
        } catch {
            NSLog("%@", "[luluk-ai] FAIL makeSessionDirectory: \(error)")
            updateState(.failed(.outputDirectoryNotWritable(path: error.localizedDescription)))
            return
        }
        sessionDir = session

        // SPEC：输出写视频同目录的 <basename>.zh.srt
        let outputURL = videoURL
            .deletingPathExtension()
            .appendingPathExtension("zh.srt")

        // 提前校验同目录可写
        let videoDir = videoURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: videoDir) else {
            NSLog("%@", "[luluk-ai] FAIL output dir not writable: \(videoDir)")
            updateState(.failed(.outputDirectoryNotWritable(path: outputURL.deletingLastPathComponent().path)))
            cleanupSession()
            return
        }
        NSLog("%@", "[luluk-ai] session=\(session.path) output=\(outputURL.path)")

        // 4. 组件实例化
        let splitter: AudioSplitter
        do {
            splitter = try AudioSplitter()
        } catch {
            NSLog("%@", "[luluk-ai] FAIL ffmpeg/ffprobe missing: \(error)")
            updateState(.failed(.ffmpegBinaryMissing))
            cleanupSession()
            return
        }
        let runner = WhisperRunner(paths: paths)
        let merger = SRTMerger(outputURL: outputURL)

        NSLog("%@", "[luluk-ai] splitter ready, starting pipeline")
        updateState(.splitting)

        // 5. 跑流水线
        do {
            let stream = splitter.split(videoURL: videoURL, outputDir: session)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await segment in stream {
                    try Task.checkCancellation()
                    NSLog("%@", "[luluk-ai] segment #\(segment.index) yielded duration=\(String(format: "%.1f", segment.duration))s offset=\(String(format: "%.1f", segment.originalStartTime))s")
                    // 拿 service-local 槽（≤3）
                    await acquireSlot()
                    incrementTotalSegments()
                    if progress.state != .running {
                        updateState(.running)
                    }
                    group.addTask { [weak self] in
                        defer {
                            // releaseSlot 是 actor-isolated 同步方法，
                            // 在 nonisolated 子任务里走 Task 包一层。
                            Task { await self?.releaseSlot() }
                        }
                        do {
                            try await self?.processSegment(
                                segment: segment,
                                runner: runner,
                                merger: merger,
                                source: sourceLanguage,
                                target: targetLanguage
                            )
                            NSLog("%@", "[luluk-ai] segment #\(segment.index) DONE")
                        } catch {
                            NSLog("%@", "[luluk-ai] segment #\(segment.index) FAIL: \(error)")
                            throw error
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await merger.finalize()
            NSLog("%@", "[luluk-ai] pipeline COMPLETED, output written")
            updateState(.completed)
        } catch is CancellationError {
            NSLog("%@", "[luluk-ai] pipeline CANCELLED")
            updateState(.cancelled)
        } catch let e as SubtitleError {
            NSLog("%@", "[luluk-ai] pipeline FAILED with SubtitleError: \(e.shortDescription)")
            updateState(.failed(e))
        } catch let e as AudioSplitterError {
            NSLog("%@", "[luluk-ai] pipeline FAILED with AudioSplitterError: \(e)")
            updateState(.failed(.videoFileUnreadable(reason: String(describing: e))))
        } catch {
            NSLog("%@", "[luluk-ai] pipeline FAILED with unknown error: \(error)")
            updateState(.failed(.videoFileUnreadable(reason: error.localizedDescription)))
        }

        cleanupSession()
    }

    // MARK: - 单段处理（transcribe → sanitize → translate batches → merge）

    private func processSegment(
        segment: AudioSegment,
        runner: WhisperRunner,
        merger: SRTMerger,
        source: Language?,
        target: Language
    ) async throws {
        // 拿全局 whisper 进程槽（5），实际 spawn 进程
        let result = try await pool.withSlot {
            try await runner.transcribe(audio: segment, language: source)
        }
        try Task.checkCancellation()

        let cleaned = Sanitizer.clean(result.lines)
        incrementTranscribed()

        // 空段也 append（占位段索引，让 SRTMerger 知道 segment 完成）
        if cleaned.isEmpty {
            try await merger.append(
                lines: [],
                segmentIndex: segment.index,
                offsetInOriginalVideo: 0
            )
            recordTranslatedSegment()
            return
        }

        // 切 batch=8 + context=3，逐 batch 翻译
        let translated = try await translateAllBatches(
            cleaned: cleaned,
            source: source ?? result.language,
            target: target
        )

        // 注意：cleaned 里时间戳已经是绝对时间（WhisperRunner 加过 originalStartTime），
        // SRTMerger 的 offset 必须传 0，否则会重复偏移。
        try await merger.append(
            lines: translated,
            segmentIndex: segment.index,
            offsetInOriginalVideo: 0
        )
        recordTranslatedSegment()
    }

    /// 把整段切成多个 batch，逐个调 provider；batch 失败 → 单行重试 → 再失败 → 占位。
    /// internal 给单元测试调用（@testable import luluk）。
    func translateAllBatches(
        cleaned: [SrtLine],
        source: Language?,
        target: Language
    ) async throws -> [SrtLine] {
        var translated: [SrtLine] = []
        var cursor = 0
        let batchSize = TranslationProviderConfig.batchSize
        let contextSize = TranslationProviderConfig.contextSize

        while cursor < cleaned.count {
            try Task.checkCancellation()
            let end = min(cursor + batchSize, cleaned.count)
            let batch = Array(cleaned[cursor..<end])
            let ctxStart = max(0, cursor - contextSize)
            let context = Array(cleaned[ctxStart..<cursor])

            do {
                let chunk = try await provider.translate(
                    batch: batch,
                    context: context,
                    source: source,
                    target: target
                )
                translated.append(contentsOf: chunk)
            } catch {
                // batch 整体失败 → 单行重译（SPEC §7.2）
                for line in batch {
                    try Task.checkCancellation()
                    do {
                        let single = try await provider.translateSingle(
                            line: line,
                            context: context,
                            source: source,
                            target: target
                        )
                        translated.append(single)
                    } catch {
                        // 单行也失败 → 占位，不让整段瘫掉
                        translated.append(SrtLine(
                            index: line.index,
                            startTime: line.startTime,
                            endTime: line.endTime,
                            text: "[翻译失败]"
                        ))
                    }
                }
                // 记录但不抛：service 已用占位降级
                let providerError: SubtitleError
                if let se = error as? SubtitleError {
                    providerError = se
                } else {
                    providerError = .translationBatchMalformed(reason: error.localizedDescription)
                }
                progress.lastError = providerError
                progressContinuation.yield(progress)
            }
            cursor = end
        }
        return translated
    }

    // MARK: - 进度更新（actor-isolated）

    private func updateState(_ state: PipelineProgress.State) {
        progress.state = state
        progress.elapsedSeconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        progressContinuation.yield(progress)
    }

    private func incrementTotalSegments() {
        // splitter 流式 yield，total 不可预知，每 yield 一段就 +1
        if progress.totalSegments < 0 {
            progress.totalSegments = 1
        } else {
            progress.totalSegments += 1
        }
        progressContinuation.yield(progress)
    }

    private func incrementTranscribed() {
        progress.transcribedSegments += 1
        progressContinuation.yield(progress)
    }

    private func recordTranslatedSegment() {
        progress.translatedSegments += 1
        if firstSubtitleAt == nil {
            firstSubtitleAt = Date()
            if let s = startedAt {
                progress.firstSubtitleLatency = Date().timeIntervalSince(s)
            }
        }
        // 异步刷 token 累计（actor-isolated 调用）
        Task { [weak self] in
            await self?.refreshTokenUsage()
        }
        progress.elapsedSeconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        progressContinuation.yield(progress)
    }

    private func refreshTokenUsage() async {
        let tokens = await provider.cumulativeTokens
        progress.tokensUsed = tokens
        progressContinuation.yield(progress)
    }

    // MARK: - 段级 semaphore

    private func acquireSlot() async {
        if inUseSlots < maxConcurrentSegments {
            inUseSlots += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            slotWaiters.append(c)
        }
    }

    private func releaseSlot() {
        if let next = slotWaiters.first {
            slotWaiters.removeFirst()
            next.resume()
        } else {
            inUseSlots = max(0, inUseSlots - 1)
        }
    }

    // MARK: - Session 临时目录

    /// 建一个 `~/Library/Caches/luluk/sessions/<basename>-<random>/` 临时目录，
    /// 给 AudioSplitter / WhisperRunner 写中间文件。
    private func makeSessionDirectory(for videoURL: URL) throws -> URL {
        let fm = FileManager.default
        let cachesRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let base = videoURL.deletingPathExtension().lastPathComponent
        let random = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        let dir = cachesRoot
            .appendingPathComponent("luluk", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(base)-\(random)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanupSession() {
        if let dir = sessionDir {
            try? FileManager.default.removeItem(at: dir)
            sessionDir = nil
        }
    }
}

// MARK: - ProgressReporter conformance

protocol ProgressReporter: Sendable {
    var progressStream: AsyncStream<PipelineProgress> { get }
}
