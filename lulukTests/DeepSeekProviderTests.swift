//
//  DeepSeekProviderTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  DeepSeekProvider 纯函数单元测试：prompt 构造 + 响应解析 + CJK 占比。
//  HTTP 部分需要 stub URLSession，留 M5（多 provider 整体补）。
//

import Testing
import Foundation
@testable import luluk

struct DeepSeekProviderTests {

    // MARK: - System prompt

    @Test func systemPromptIncludesTargetLanguageName() {
        let p = DeepSeekProvider.makeSystemPrompt(target: .simplifiedChinese)
        // SPEC §7.3：必须传带括号的双语名，不能是 ISO 码 "zh"
        #expect(p.contains("简体中文 (Simplified Chinese)"))
        #expect(!p.contains("\"zh\""))
        // 必须明确输出 JSON 格式约束
        #expect(p.contains("translations"))
    }

    // MARK: - User prompt

    @Test func userPromptIsValidJSONWithLinesAndContext() throws {
        let batch = [
            SrtLine(index: 1, startTime: 0, endTime: 1, text: "こんにちは"),
            SrtLine(index: 2, startTime: 1, endTime: 2, text: "元気ですか"),
        ]
        let context = [
            SrtLine(index: 0, startTime: 0, endTime: 0, text: "前文 1"),
        ]
        let body = DeepSeekProvider.makeUserPrompt(
            batch: batch, context: context, source: .japanese
        )
        let data = body.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["lines"] as? [String]) == ["こんにちは", "元気ですか"])
        #expect((obj["context"] as? [String]) == ["前文 1"])
        // sourceLang 也用 llmPromptName，不能是 "ja"
        let lang = obj["sourceLang"] as? String
        #expect(lang?.contains("Japanese") == true)
    }

    @Test func userPromptSourceLangAutoWhenNil() throws {
        let body = DeepSeekProvider.makeUserPrompt(
            batch: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "hi")],
            context: [],
            source: nil
        )
        let obj = try JSONSerialization.jsonObject(with: body.data(using: .utf8)!) as! [String: Any]
        #expect(obj["sourceLang"] as? String == "auto")
    }

    // MARK: - Request body

    @Test func requestBodyHasModelMessagesAndJSONFormat() throws {
        let body = DeepSeekProvider.buildRequestBody(
            model: "deepseek-v4-flash",
            batch: [SrtLine(index: 1, startTime: 0, endTime: 1, text: "x")],
            context: [],
            source: nil,
            target: .simplifiedChinese
        )
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(obj["model"] as? String == "deepseek-v4-flash")
        #expect(obj["stream"] as? Bool == false)
        let format = obj["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_object")
        // messages 必须含 system + user
        let messages = obj["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
    }

    // MARK: - Response 解析

    @Test func parsesValidChatResponse() throws {
        // DeepSeek 真实响应结构（最小）。content 是模型吐出的 JSON 字符串。
        let raw = """
        {
          "id": "abc",
          "choices": [{
            "index": 0,
            "message": {
              "role": "assistant",
              "content": "{\\"translations\\":[\\"你好\\",\\"再见\\"]}"
            },
            "finish_reason": "stop"
          }],
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 20,
            "total_tokens": 120
          }
        }
        """.data(using: .utf8)!
        let parsed = try DeepSeekProvider.parseChatResponse(raw)
        #expect(parsed.translations == ["你好", "再见"])
        #expect(parsed.totalTokens == 120)
    }

    @Test func throwsWhenChoicesMissing() {
        let raw = Data("{\"id\":\"x\"}".utf8)
        #expect(throws: SubtitleError.self) {
            _ = try DeepSeekProvider.parseChatResponse(raw)
        }
    }

    @Test func throwsWhenInnerContentNotValidJSON() {
        let raw = """
        {"choices":[{"message":{"content":"this is not json"}}]}
        """.data(using: .utf8)!
        #expect(throws: SubtitleError.self) {
            _ = try DeepSeekProvider.parseChatResponse(raw)
        }
    }

    @Test func throwsWhenInnerHasWrongShape() {
        let raw = """
        {"choices":[{"message":{"content":"{\\"foo\\":\\"bar\\"}"}}]}
        """.data(using: .utf8)!
        #expect(throws: SubtitleError.self) {
            _ = try DeepSeekProvider.parseChatResponse(raw)
        }
    }

    @Test func usageMissingDefaultsToZero() throws {
        let raw = """
        {"choices":[{"message":{"content":"{\\"translations\\":[\\"a\\"]}"}}]}
        """.data(using: .utf8)!
        let parsed = try DeepSeekProvider.parseChatResponse(raw)
        #expect(parsed.totalTokens == 0)
    }

    // MARK: - CJK 占比

    @Test func cjkRatioForChineseText() {
        #expect(DeepSeekProvider.cjkRatio("你好世界") == 1.0)
    }

    @Test func cjkRatioForEnglishText() {
        #expect(DeepSeekProvider.cjkRatio("Hello World") == 0.0)
    }

    @Test func cjkRatioMixedText() {
        // 4 中文 + 5 英文（标点不算）→ 4/9 ≈ 0.44
        let r = DeepSeekProvider.cjkRatio("你好世界, hello")
        #expect(r > 0.4 && r < 0.5)
    }

    @Test func cjkRatioIgnoresPunctuationAndWhitespace() {
        // 全是标点和空白 → counted=0 → 默认 1.0（不误判）
        #expect(DeepSeekProvider.cjkRatio(" .,!? ") == 1.0)
    }

    @Test func cjkRatioJapaneseHiraganaIsNotCJKIdeograph() {
        // 平假名 / 片假名不在 4E00-9FFF 范围内，不算 CJK 表意字符。
        // 这是预期行为：日文译文（含假名）会触发 drift 警告，
        // 但 V1 target 固定中文，所以"译文里的日文 = 漂移"是合理判定。
        let r = DeepSeekProvider.cjkRatio("こんにちは")
        #expect(r == 0.0)
    }
}
