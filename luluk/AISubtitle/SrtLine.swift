//
//  SrtLine.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕引擎核心数据结构：单行字幕。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.4。
//

import Foundation

/// 一行字幕。
///
/// 序列化格式遵循 SubRip (.srt) 标准：
/// ```
/// 1
/// 00:00:01,234 --> 00:00:05,678
/// 你好世界
///
/// ```
///
/// 时间用 `TimeInterval`（秒）存储，序列化时转 `HH:MM:SS,mmm`。
struct SrtLine: Sendable, Codable, Equatable {
    /// SRT 序号（1-based）。Sanitizer / SRTMerger 会重新编号。
    var index: Int

    /// 起始时间（秒）。
    var startTime: TimeInterval

    /// 结束时间（秒）。`endTime > startTime` 是不变式但本类型不强制——构造者负责。
    var endTime: TimeInterval

    /// 字幕文本。可含换行（双语字幕：原文\n译文）。空字符串通常被下游 drop。
    var text: String

    /// 持续时间（秒）。可能为 0（whisper 偶发输出零时长行）。
    var duration: TimeInterval { endTime - startTime }

    init(index: Int, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    // MARK: - 序列化

    /// 序列化成 SRT 文本块（含末尾空行，便于直接拼接）。
    func srtFormatted() -> String {
        let start = SrtLine.formatTimestamp(startTime)
        let end = SrtLine.formatTimestamp(endTime)
        return "\(index)\n\(start) --> \(end)\n\(text)\n\n"
    }

    /// 解析多行 SRT 文本为 `[SrtLine]`。
    ///
    /// 容错策略：
    /// - 接受 `\n` 和 `\r\n` 行分隔
    /// - 自动剥离 UTF-8 BOM
    /// - 允许时间戳用 `,` 或 `.` 分隔毫秒（VLC 写出的有些用 `.`）
    /// - 索引行非数字 → 跳过整个 block
    /// - 时间戳格式不对 → 跳过整个 block
    /// - 文本可以多行（直到下一个空行）
    static func parse(_ srtContent: String) -> [SrtLine] {
        // 剥 BOM + 统一行分隔
        var content = srtContent
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")

        // 按双换行（空行）切分 block
        let blocks = content.components(separatedBy: "\n\n")
        var result: [SrtLine] = []

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }

            // 第 1 行：序号（必须是整数）
            guard let idx = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }

            // 第 2 行：时间戳 `HH:MM:SS,mmm --> HH:MM:SS,mmm`
            let timeLine = lines[1]
            guard let (start, end) = parseTimestampLine(timeLine) else { continue }

            // 第 3 行至末尾：文本
            let text = lines.dropFirst(2).joined(separator: "\n")

            result.append(SrtLine(index: idx, startTime: start, endTime: end, text: text))
        }
        return result
    }

    // MARK: - 时间戳工具

    /// 把秒数格式化成 `HH:MM:SS,mmm`。
    /// 负数会被 clamp 到 0。
    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let totalMillis = Int((total * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis / 60_000) % 60
        let s = (totalMillis / 1000) % 60
        let ms = totalMillis % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// 解析单个时间戳 `HH:MM:SS,mmm` 或 `HH:MM:SS.mmm` 为秒。
    static func parseTimestamp(_ s: String) -> TimeInterval? {
        // 把 `,` 和 `.` 统一成 `.`，方便后面用 Double 解析毫秒
        let normalized = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        // 第三段可能是 "SS" 或 "SS.mmm"
        let secStr = String(parts[2])
        guard let sec = Double(secStr) else { return nil }
        if h < 0 || m < 0 || sec < 0 { return nil }
        return TimeInterval(h * 3600 + m * 60) + sec
    }

    /// 解析 `HH:MM:SS,mmm --> HH:MM:SS,mmm`。
    private static func parseTimestampLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else { return nil }
        return (start, end)
    }
}
