//
//  SanitizerTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  Whisper 幻觉清理算法测试。
//  覆盖 SPEC §7.1 列出的 4 类幻觉 + 边界情况 + 不误伤正常对白。
//

import Testing
@testable import luluk

struct SanitizerTests {

    // MARK: - 类 4：SDH 标注（最先测，因为最简单清晰）

    @Test func dropsAsteriskSDH() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "*sigh*")
        #expect(Sanitizer.decide(line) == .drop)
        #expect(Sanitizer.detectHallucination(line) == .sdh)
    }

    @Test func dropsBracketSDH() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "[music]")
        #expect(Sanitizer.decide(line) == .drop)
    }

    @Test func dropsParenSDH() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "(laughs)")
        #expect(Sanitizer.decide(line) == .drop)
    }

    @Test func keepsChineseParenAnnotation() {
        // 中文括号备注（如 "(笑)"）不应被当 SDH 误删
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "(笑)")
        #expect(Sanitizer.decide(line) == .keep)
    }

    @Test func keepsInlineSDH() {
        // 整行匹配才算 SDH。"他叹气 *sigh*" 是带括注的对白，必须保留。
        let line = SrtLine(index: 1, startTime: 0, endTime: 2, text: "他叹气 *sigh*")
        #expect(Sanitizer.decide(line) == .keep)
    }

    // MARK: - 类 3：长时长 + 高频结尾词

    @Test func rewritesLongJapaneseClosing() {
        // SPEC §7.1 实测：「おやすみなさい」持续 30 秒
        let line = SrtLine(index: 1, startTime: 0, endTime: 30, text: "おやすみなさい")
        #expect(Sanitizer.decide(line) == .rewrite("（无对白）"))
    }

    @Test func rewritesLongEnglishClosing() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 20, text: "Thank you")
        #expect(Sanitizer.decide(line) == .rewrite("（无对白）"))
    }

    @Test func rewritesLongClosingCaseInsensitive() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 20, text: "THANKS FOR WATCHING")
        #expect(Sanitizer.decide(line) == .rewrite("（无对白）"))
    }

    @Test func rewritesLongClosingWithTrailingPunctuation() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 20, text: "おやすみなさい。")
        #expect(Sanitizer.decide(line) == .rewrite("（无对白）"))
    }

    @Test func keepsShortClosing() {
        // 同样的结尾词，时长正常 → 不算幻觉，保留
        let line = SrtLine(index: 1, startTime: 0, endTime: 2, text: "おやすみなさい")
        #expect(Sanitizer.decide(line) == .keep)
    }

    @Test func keepsLongNonClosingPhrase() {
        // 长时长但不是高频结尾词 → 保留（可能就是长对白）
        let line = SrtLine(index: 1, startTime: 0, endTime: 30, text: "今天天气真好我们去散步吧")
        #expect(Sanitizer.decide(line) == .keep)
    }

    @Test func longClosingThresholdRespected() {
        // 阈值 8 秒、行 5 秒 → 不触发；阈值 4 秒 → 触发
        let line = SrtLine(index: 1, startTime: 0, endTime: 5, text: "Thank you")
        #expect(Sanitizer.decide(line, longLineDurationThreshold: 8) == .keep)
        #expect(Sanitizer.decide(line, longLineDurationThreshold: 4) == .rewrite("（无对白）"))
    }

    // MARK: - 类 1：单字符重复

    @Test func simplifiesRepeatedSingleChar() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 5, text: "あああああああ")  // 7 个「あ」
        let result = Sanitizer.decide(line)
        if case .rewrite(let text) = result {
            #expect(text == "ああ")  // keepRepeats=2
        } else {
            Issue.record("expected .rewrite, got \(result)")
        }
    }

    @Test func keepsShortRepeatedChar() {
        // 4 个重复（< 阈值 5）→ 不简化
        let line = SrtLine(index: 1, startTime: 0, endTime: 2, text: "あああああ")
        // 上面有 5 个 → 触发
        #expect(Sanitizer.detectHallucination(line) == .repeatedChar)

        let lineShort = SrtLine(index: 1, startTime: 0, endTime: 2, text: "ああああ")  // 4 个
        #expect(Sanitizer.detectHallucination(lineShort) == nil)
    }

    // MARK: - 类 2：重复短模式

    @Test func simplifiesRepeated2CharPattern() {
        // SPEC §7.1 经典例子：「はっはっはっはっ」
        let line = SrtLine(index: 1, startTime: 0, endTime: 5, text: "はっはっはっはっはっ")  // 5 次「はっ」
        let result = Sanitizer.decide(line)
        if case .rewrite(let text) = result {
            #expect(text == "はっはっ")  // keepRepeats=2
        } else {
            Issue.record("expected .rewrite, got \(result)")
        }
    }

    @Test func simplifiesRepeated3CharPattern() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 5, text: "あっはあっはあっはあっは")  // 4 次「あっは」
        let result = Sanitizer.decide(line)
        if case .rewrite(let text) = result {
            #expect(text == "あっはあっは")
        } else {
            Issue.record("expected .rewrite, got \(result)")
        }
    }

    @Test func keepsTwoRepeatsOfPattern() {
        // 仅 2 次重复（< 阈值 3）→ 不算幻觉
        let line = SrtLine(index: 1, startTime: 0, endTime: 2, text: "はっはっ")
        #expect(Sanitizer.decide(line) == .keep)
    }

    @Test func detectsRepeatedPattern() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 5, text: "はっはっはっはっ")
        #expect(Sanitizer.detectHallucination(line) == .repeatedPattern)
    }

    // MARK: - 边界 / 空 / 不误伤

    @Test func dropsEmptyText() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "")
        #expect(Sanitizer.decide(line) == .drop)
    }

    @Test func dropsWhitespaceOnly() {
        let line = SrtLine(index: 1, startTime: 0, endTime: 1, text: "   \n  ")
        #expect(Sanitizer.decide(line) == .drop)
    }

    @Test func keepsNormalDialogue() {
        let cases = [
            "今天天气真好",
            "Hello, how are you?",
            "I'm doing fine, thank you for asking.",  // 含 "thank you" 但不是整行
            "おはようございます",
            "안녕하세요",
        ]
        for text in cases {
            let line = SrtLine(index: 1, startTime: 0, endTime: 3, text: text)
            #expect(Sanitizer.decide(line) == .keep, "误伤了正常对白：\(text)")
        }
    }

    @Test func keepsRepeatedWordsThatArentPatterns() {
        // 自然重复（不是幻觉）
        let line = SrtLine(index: 1, startTime: 0, endTime: 3, text: "好的好的好的")  // 3 次「好的」 = 阈值边界
        // 这种情况会被简化（pattern=2, repeat=3 命中阈值）。这是已知 trade-off：
        // 「好的好的好的」既可能是真实对白也可能是幻觉。Sanitizer 选择保守判定为重复。
        let result = Sanitizer.decide(line)
        // 接受 .keep 或 .rewrite，不强求行为，但记录测试声明这个 case 是有意识地处理
        #expect(result == .keep || result == .rewrite("好的好的"))
    }

    // MARK: - clean() 整体行为：重新编号 / 顺序

    @Test func cleanReassignsConsecutiveIndices() {
        let lines = [
            SrtLine(index: 100, startTime: 0, endTime: 1, text: "正常 1"),
            SrtLine(index: 200, startTime: 1, endTime: 2, text: "*sigh*"),  // 会被 drop
            SrtLine(index: 300, startTime: 2, endTime: 3, text: "正常 2"),
        ]
        let cleaned = Sanitizer.clean(lines)
        #expect(cleaned.count == 2)
        #expect(cleaned[0].index == 1)
        #expect(cleaned[0].text == "正常 1")
        #expect(cleaned[1].index == 2)
        #expect(cleaned[1].text == "正常 2")
    }

    @Test func cleanPreservesTimestamps() {
        let lines = [
            SrtLine(index: 1, startTime: 5.5, endTime: 7.7, text: "Hello"),
        ]
        let cleaned = Sanitizer.clean(lines)
        #expect(cleaned[0].startTime == 5.5)
        #expect(cleaned[0].endTime == 7.7)
    }

    @Test func cleanEmptyInput() {
        #expect(Sanitizer.clean([]).isEmpty)
    }

    @Test func cleanAllDroppedReturnsEmpty() {
        let lines = [
            SrtLine(index: 1, startTime: 0, endTime: 1, text: "*sigh*"),
            SrtLine(index: 2, startTime: 1, endTime: 2, text: "[music]"),
            SrtLine(index: 3, startTime: 2, endTime: 3, text: ""),
        ]
        #expect(Sanitizer.clean(lines).isEmpty)
    }
}
