//
//  SRTMerger.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  增量合并多段字幕到单个 .srt 文件。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3。
//

import Foundation

/// 流水线增量字幕合并器。
///
/// ## 责任
///
/// - 接收乱序到达的段（`segmentIndex` 不一定按顺序），按段索引排序后写入。
/// - 给每行重新分配连续的 SRT 编号（1-based）。
/// - 按 `offsetInOriginalVideo` 把段内相对时间转换成原视频绝对时间。
/// - **原子写**：写临时文件再 `rename`，避免 FSEventStream 看到半成品。
///
/// ## 用法
///
/// ```swift
/// let merger = SRTMerger(outputURL: URL(fileURLWithPath: "/path/to/video.zh.srt"))
/// try await merger.append(lines: seg0Lines, segmentIndex: 0, offsetInOriginalVideo: 0)
/// try await merger.append(lines: seg2Lines, segmentIndex: 2, offsetInOriginalVideo: 90)
/// // 段 1 还没回来，文件里只有段 0 的内容
/// try await merger.append(lines: seg1Lines, segmentIndex: 1, offsetInOriginalVideo: 45)
/// // 文件刷新为段 0 + 段 1 + 段 2 的合并
/// try await merger.finalize()
/// ```
///
/// ## 不变式
///
/// - 同一 `segmentIndex` 不应该 append 多次（重复 append 会报错或覆盖，本实现选择 fatalError 提示 bug）。
/// - 时间戳不重叠是 caller 责任（whisper 输出本身有序，AudioSplitter 按静音点切，理论上不会重叠）。
actor SRTMerger {

    enum MergerError: Error, Equatable {
        /// 同一段被 append 两次。
        case duplicateSegment(segmentIndex: Int)
        /// 文件写入失败（磁盘满、权限等）。
        case writeFailed(underlying: String)
        /// `finalize()` 后再调 `append`。
        case finalized
    }

    /// 输出文件最终路径（如 `/path/to/video.zh.srt`）。
    private let outputURL: URL

    /// 临时文件路径（写入用，写完 atomic rename 到 `outputURL`）。
    /// 命名 `<final>.tmp.<random>` 避免不同 PlayerCore 撞临时文件。
    private let tempURL: URL

    /// 已收集的段：segmentIndex → 该段处理过 offset 后的行数组。
    /// 用 `[Int: [SrtLine]]` 而非 `[(Int, [SrtLine])]` 因为我们要按 key 排序输出。
    private var segments: [Int: [SrtLine]] = [:]

    /// 是否已 finalize。
    private var isFinalized = false

    init(outputURL: URL) {
        self.outputURL = outputURL
        // 临时文件：相同目录下，原子 rename 才生效（rename 不能跨 volume）
        let dir = outputURL.deletingLastPathComponent()
        let name = outputURL.lastPathComponent
        let randomSuffix = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        self.tempURL = dir.appendingPathComponent(".\(name).tmp.\(randomSuffix)")
    }

    // MARK: - 追加一段

    /// 追加一段翻译完成的字幕。
    /// 调完后立刻刷新文件（让 FSEventStream 在新段到达时就触发 reload）。
    func append(
        lines: [SrtLine],
        segmentIndex: Int,
        offsetInOriginalVideo: TimeInterval
    ) async throws {
        if isFinalized {
            throw MergerError.finalized
        }
        if segments[segmentIndex] != nil {
            throw MergerError.duplicateSegment(segmentIndex: segmentIndex)
        }

        // 把段内相对时间转换为视频绝对时间
        let adjusted = lines.map { line in
            SrtLine(
                index: line.index,  // 临时占位，下面 flushToFile 时会全局重编号
                startTime: line.startTime + offsetInOriginalVideo,
                endTime: line.endTime + offsetInOriginalVideo,
                text: line.text
            )
        }
        segments[segmentIndex] = adjusted

        try flushToFile()
    }

    /// 流水线全部完成时调。当前实现等同 `flushToFile()`，留 hook 给将来加"清理临时态"或"写元数据 footer"。
    func finalize() async throws {
        try flushToFile()
        isFinalized = true
    }

    // MARK: - 内部：刷新到磁盘

    /// 收集所有段，按 segmentIndex 排序，重新分配连续 SRT 索引，写入临时文件，rename 到最终文件。
    private func flushToFile() throws {
        // 按 segmentIndex 升序遍历，保证文件内时间单调递增
        let sortedKeys = segments.keys.sorted()
        var output = ""
        var globalIndex = 1
        for key in sortedKeys {
            guard let lines = segments[key] else { continue }
            for line in lines {
                var copy = line
                copy.index = globalIndex
                output.append(copy.srtFormatted())
                globalIndex += 1
            }
        }

        // 写临时文件
        let tempPath = tempURL.path
        do {
            try output.write(to: tempURL, atomically: false, encoding: .utf8)
        } catch {
            throw MergerError.writeFailed(underlying: "write \(tempPath): \(error.localizedDescription)")
        }

        // 原子 rename 到最终路径（同卷）
        let fm = FileManager.default
        do {
            // FileManager.replaceItemAt 在目标不存在时也工作（macOS 11+）
            // 但更稳的是 _NSFileManagerReplaceItemOptions 兼容路径：
            // 1) 目标不存在 → 直接 moveItem
            // 2) 目标存在 → replaceItemAt
            if fm.fileExists(atPath: outputURL.path) {
                _ = try fm.replaceItemAt(outputURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            // rename 失败时清理临时文件，避免磁盘垃圾
            try? fm.removeItem(at: tempURL)
            throw MergerError.writeFailed(underlying: "rename \(tempPath) → \(outputURL.path): \(error.localizedDescription)")
        }
    }

    // MARK: - 测试用 introspection

    /// 仅给单元测试用：当前已收到的段索引。
    func segmentIndices() -> [Int] {
        Array(segments.keys).sorted()
    }
}
