//
//  Sanitizer.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  Whisper 输出幻觉清理。纯函数模块、无状态、可单元测试。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3 + SPEC §7.1（4 类幻觉规范）。
//

import Foundation

/// 清理 whisper 转写中常见的 4 类幻觉。
///
/// ## 4 类幻觉（按 SPEC §7.1）
///
/// 1. **重复字符**：`はっはっはっ...` 持续 30 秒 → 简化为 1-2 次模式。
/// 2. **重复短模式**：`あっはぁっはぁっ...` → 简化。
/// 3. **长时长 + 高频结尾词**：`おやすみなさい` 占 30 秒 → 替换 "（无对白）"。
/// 4. **SDH 非言语标注**：`*sigh*` `[music]` `(laughs)` → 直接丢弃。
///
/// ## 设计原则
///
/// - 保守：宁可漏过一些幻觉，也不能把正常对白当幻觉删。阈值默认值偏严格。
/// - 显式参数化：阈值通过参数传入，方便后续在真实视频上调优而不改算法。
/// - 输出端编号连续：`clean()` 重新分配 `index`（drop 后的行不留空号）。
enum Sanitizer {

    /// 决定一行字幕的处置方式。
    enum Decision: Equatable, Sendable {
        /// 原样保留（仅可能重新编号）。
        case keep
        /// 用新文本替换（用于重复模式简化、长时长占位）。
        case rewrite(String)
        /// 丢弃整行（用于 SDH 标注）。
        case drop
    }

    /// 检测到的幻觉类型（用于 UI 显示统计或调试）。
    enum HallucinationType: Equatable, Sendable {
        case repeatedChar
        case repeatedPattern
        case longSilenceFiller
        case sdh
    }

    // MARK: - 主入口

    /// 清理整段字幕。
    ///
    /// - Parameters:
    ///   - lines: 原始字幕（whisper 转写后未处理）。
    ///   - longLineDurationThreshold: 类 3 判定阈值——单行超过这个时长 + 是高频结尾词才视为幻觉。默认 15s（保守）。
    /// - Returns: 清理后的字幕，索引重新分配为连续 1-based。
    static func clean(
        _ lines: [SrtLine],
        longLineDurationThreshold: TimeInterval = 15.0
    ) -> [SrtLine] {
        var result: [SrtLine] = []
        var newIndex = 1
        for line in lines {
            switch decide(line, longLineDurationThreshold: longLineDurationThreshold) {
            case .keep:
                var copy = line
                copy.index = newIndex
                result.append(copy)
                newIndex += 1
            case .rewrite(let newText):
                var copy = line
                copy.text = newText
                copy.index = newIndex
                result.append(copy)
                newIndex += 1
            case .drop:
                continue
            }
        }
        return result
    }

    /// 单行决策。可独立调用做单元测试。
    static func decide(
        _ line: SrtLine,
        longLineDurationThreshold: TimeInterval = 15.0
    ) -> Decision {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .drop }

        // 类 4：SDH 标注（最先判定，因为是整行包含格式）
        if isSDH(text) { return .drop }

        // 类 3：长时长 + 高频结尾词
        if isLongSilenceFiller(line: line, text: text, threshold: longLineDurationThreshold) {
            return .rewrite("（无对白）")
        }

        // 类 1 / 类 2：重复字符或短模式
        if let simplified = simplifyRepeated(text), simplified != text {
            return .rewrite(simplified)
        }

        return .keep
    }

    /// 仅检测幻觉类型，不修改。给 UI 统计用。
    static func detectHallucination(_ line: SrtLine) -> HallucinationType? {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if isSDH(text) { return .sdh }
        if isLongSilenceFiller(line: line, text: text, threshold: 15.0) {
            return .longSilenceFiller
        }
        if hasRepeatedRun(text, period: 1, minRepeats: 5) { return .repeatedChar }
        if hasRepeatedRun(text, period: 2, minRepeats: 3) { return .repeatedPattern }
        if hasRepeatedRun(text, period: 3, minRepeats: 3) { return .repeatedPattern }
        return nil
    }

    // MARK: - 类 4：SDH 标注

    /// 判定一行**整体**是否是非言语标注。
    /// 必须整行匹配（`*sigh*` 而不是 `他叹气 *sigh*`），避免误删含括注的真实对白。
    private static func isSDH(_ text: String) -> Bool {
        // `*xxx*`：星号包围
        if text.hasPrefix("*") && text.hasSuffix("*") && text.count >= 2 {
            return true
        }
        // `[xxx]`：方括号包围
        if text.hasPrefix("[") && text.hasSuffix("]") && text.count >= 2 {
            return true
        }
        // `(xxx)`：圆括号包围 + 内部仅 ASCII 字母/空格（避免误删 "(笑)" 这种中文括注）
        if text.hasPrefix("(") && text.hasSuffix(")") && text.count >= 2 {
            let inner = String(text.dropFirst().dropLast())
            let asciiAlphaSpace = inner.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isWhitespace)
            }
            if asciiAlphaSpace && !inner.isEmpty { return true }
        }
        return false
    }

    // MARK: - 类 3：长时长 + 高频结尾词

    /// 高频结尾词列表（保守、低误伤）。
    /// 大小写不敏感、空白不敏感、半角全角空格归一化后比较。
    private static let commonClosingPhrases: Set<String> = [
        // 日语
        "おやすみなさい",
        "おやすみ",
        "さようなら",
        "ありがとうございました",
        "ありがとうございます",
        "ありがとう",
        // 英语
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "goodbye",
        "good night",
        "bye",
        "bye bye",
        // 韩语
        "안녕히 계세요",
        "감사합니다",
    ]

    private static func isLongSilenceFiller(line: SrtLine, text: String, threshold: TimeInterval) -> Bool {
        guard line.duration >= threshold else { return false }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "　", with: " ")  // 全角空格 → 半角
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 还要剥句末标点（。！？.!?）以匹配 "おやすみなさい。"
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "。.!?！？、 "))
        return commonClosingPhrases.contains(stripped)
    }

    // MARK: - 类 1 / 类 2：重复字符或短模式

    /// 简化重复模式。返回 `nil` 表示不是重复（保持原样）。
    ///
    /// 算法：依次尝试 period=1（单字符）、period=2、period=3 找最长连续重复段，
    /// 把 ≥ minRepeats 次的重复段简化为 2 次模式重复（保留少量信号）。
    private static func simplifyRepeated(_ text: String) -> String? {
        var simplified = text
        // 单字符重复 ≥ 5 次（"あああああ"）→ 保留 2 个
        if let next = collapseRepeatedRun(simplified, period: 1, minRepeats: 5, keepRepeats: 2) {
            simplified = next
        }
        // 2 字符模式重复 ≥ 3 次（"はっはっはっ"）→ 保留 2 次
        if let next = collapseRepeatedRun(simplified, period: 2, minRepeats: 3, keepRepeats: 2) {
            simplified = next
        }
        // 3 字符模式重复 ≥ 3 次（"あっはぁっはぁっは"）→ 保留 2 次
        if let next = collapseRepeatedRun(simplified, period: 3, minRepeats: 3, keepRepeats: 2) {
            simplified = next
        }
        return simplified == text ? nil : simplified
    }

    /// 检测 `text` 中是否存在 period 长的模式连续重复 ≥ minRepeats 次。
    private static func hasRepeatedRun(_ text: String, period: Int, minRepeats: Int) -> Bool {
        let chars = Array(text)
        guard chars.count >= period * minRepeats else { return false }
        var i = 0
        while i + period * minRepeats <= chars.count {
            let pattern = Array(chars[i..<(i + period)])
            var rep = 1
            var j = i + period
            while j + period <= chars.count && Array(chars[j..<(j + period)]) == pattern {
                rep += 1
                j += period
            }
            if rep >= minRepeats { return true }
            i += 1
        }
        return false
    }

    /// 把第一处 ≥ minRepeats 次重复段折叠成 keepRepeats 次。
    /// 返回新字符串（修改了），或 `nil`（没找到该 period 的重复）。
    private static func collapseRepeatedRun(
        _ text: String,
        period: Int,
        minRepeats: Int,
        keepRepeats: Int
    ) -> String? {
        let chars = Array(text)
        guard chars.count >= period * minRepeats else { return nil }
        var i = 0
        while i + period * minRepeats <= chars.count {
            let pattern = Array(chars[i..<(i + period)])
            var rep = 1
            var j = i + period
            while j + period <= chars.count && Array(chars[j..<(j + period)]) == pattern {
                rep += 1
                j += period
            }
            if rep >= minRepeats {
                let prefix = String(chars[0..<i])
                let collapsed = String(repeating: String(pattern), count: keepRepeats)
                let suffix = String(chars[j..<chars.count])
                return prefix + collapsed + suffix
            }
            i += 1
        }
        return nil
    }
}
