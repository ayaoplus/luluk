//
//  SRTMergerTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  SRTMerger 流式合并 / 时间偏移 / 原子写测试。
//

import Testing
import Foundation
@testable import luluk

struct SRTMergerTests {

    // MARK: - 测试 fixture：临时输出 URL

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("luluk-srtmerger-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("video.zh.srt")
    }

    private static func cleanup(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 顺序段的基本写入

    @Test func writesSingleSegmentToFile() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        let lines = [
            SrtLine(index: 1, startTime: 0, endTime: 2, text: "Hello"),
            SrtLine(index: 2, startTime: 2, endTime: 4, text: "World"),
        ]
        try await merger.append(lines: lines, segmentIndex: 0, offsetInOriginalVideo: 0)
        try await merger.finalize()

        let content = try String(contentsOf: url, encoding: .utf8)
        let parsed = SrtLine.parse(content)
        #expect(parsed.count == 2)
        #expect(parsed[0].text == "Hello")
        #expect(parsed[1].text == "World")
    }

    // MARK: - 时间偏移：段相对时间 → 视频绝对时间

    @Test func appliesOffsetToTimestamps() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        // 段 1 内部相对时间 0-2 秒，但段在原视频里从 45 秒开始
        let lines = [SrtLine(index: 1, startTime: 0, endTime: 2, text: "段内第一行")]
        try await merger.append(lines: lines, segmentIndex: 1, offsetInOriginalVideo: 45)
        try await merger.finalize()

        let parsed = SrtLine.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(parsed[0].startTime == 45)
        #expect(parsed[0].endTime == 47)
    }

    // MARK: - 关键场景：乱序段到达，最终输出按段顺序排列

    @Test func reordersOutOfOrderSegments() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        // 模拟流水线：段 2 先回来（短而简单），段 0 次之，段 1 最后
        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 2, text: "段 2 内容")],
            segmentIndex: 2,
            offsetInOriginalVideo: 90
        )
        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 2, text: "段 0 内容")],
            segmentIndex: 0,
            offsetInOriginalVideo: 0
        )
        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 2, text: "段 1 内容")],
            segmentIndex: 1,
            offsetInOriginalVideo: 45
        )
        try await merger.finalize()

        let parsed = SrtLine.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(parsed.count == 3)
        // 文件里应该按时间（即 segmentIndex）顺序
        #expect(parsed[0].text == "段 0 内容")
        #expect(parsed[1].text == "段 1 内容")
        #expect(parsed[2].text == "段 2 内容")
        // 索引应连续（1, 2, 3）不论到达顺序
        #expect(parsed[0].index == 1)
        #expect(parsed[1].index == 2)
        #expect(parsed[2].index == 3)
    }

    // MARK: - 增量刷新：每次 append 文件都应该立刻可见

    @Test func incrementalFlushVisibleAfterEachAppend() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 2, text: "first")],
            segmentIndex: 0,
            offsetInOriginalVideo: 0
        )
        // 不调 finalize，文件应该已经有内容（FSEventStream 才能 reload）
        let after1 = try String(contentsOf: url, encoding: .utf8)
        #expect(SrtLine.parse(after1).count == 1)

        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 2, text: "second")],
            segmentIndex: 1,
            offsetInOriginalVideo: 10
        )
        let after2 = try String(contentsOf: url, encoding: .utf8)
        #expect(SrtLine.parse(after2).count == 2)
    }

    // MARK: - 错误：重复段

    @Test func rejectsDuplicateSegment() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "first try")],
            segmentIndex: 0,
            offsetInOriginalVideo: 0
        )
        await #expect(throws: SRTMerger.MergerError.self) {
            try await merger.append(
                lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "second try")],
                segmentIndex: 0,
                offsetInOriginalVideo: 0
            )
        }
    }

    // MARK: - 错误：finalize 后 append

    @Test func rejectsAppendAfterFinalize() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        try await merger.finalize()
        await #expect(throws: SRTMerger.MergerError.self) {
            try await merger.append(
                lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "too late")],
                segmentIndex: 0,
                offsetInOriginalVideo: 0
            )
        }
    }

    // MARK: - 段索引可见性（测试用 introspection）

    @Test func segmentIndicesReflectAppendedSegments() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "x")],
            segmentIndex: 5,
            offsetInOriginalVideo: 0
        )
        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "y")],
            segmentIndex: 2,
            offsetInOriginalVideo: 0
        )
        let indices = await merger.segmentIndices()
        #expect(indices == [2, 5])
    }

    // MARK: - 原子写：临时文件用完不残留

    @Test func atomicWriteLeavesNoTempFile() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "x")],
            segmentIndex: 0,
            offsetInOriginalVideo: 0
        )
        try await merger.finalize()

        // 检查输出目录里只有最终文件，没有 .tmp 残留
        let dir = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tmpFiles = contents.filter { $0.contains(".tmp.") }
        #expect(tmpFiles.isEmpty, "残留临时文件: \(tmpFiles)")
    }

    // MARK: - 空段不写 0 字节文件（mpv 不接受 0-byte SRT，会报 Unsupported sub）

    @Test func emptySegmentDoesNotCreateZeroByteFile() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        // 视频开头无语音 → whisper 转写空 → Sanitize 剩 0 行 → append([]) 这种场景
        try await merger.append(
            lines: [],
            segmentIndex: 0,
            offsetInOriginalVideo: 0
        )

        // 关键断言：输出文件不应该被创建（即便段已经记下）
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "空段不应该创建 0 字节 SRT 文件——mpv 会报 Unsupported sub")

        // 段计数仍应记下
        let indices = await merger.segmentIndices()
        #expect(indices == [0])
    }

    @Test func fileAppearsOnFirstNonEmptyAppend() async throws {
        let url = Self.makeTempURL()
        defer { Self.cleanup(url) }
        let merger = SRTMerger(outputURL: url)

        // 前两段空（无语音）
        try await merger.append(lines: [], segmentIndex: 0, offsetInOriginalVideo: 0)
        try await merger.append(lines: [], segmentIndex: 1, offsetInOriginalVideo: 45)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // 第 3 段才有内容 → 文件这时才出现
        try await merger.append(
            lines: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "你好")],
            segmentIndex: 2,
            offsetInOriginalVideo: 90
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("你好"))
    }
}
