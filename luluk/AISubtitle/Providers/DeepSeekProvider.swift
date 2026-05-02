//
//  DeepSeekProvider.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  DeepSeek 翻译服务（OpenAI 兼容协议 + json_object 响应格式）。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.5 + SPEC §6.1。
//
//  关键决策：
//   - endpoint：https://api.deepseek.com/chat/completions（不是 /v1，DeepSeek 直接平铺）
//   - model：默认 deepseek-v4-flash（快、便宜，字幕翻译够用）
//   - response_format：json_object，输出 {"translations":[...]} 严格按 batch 顺序
//   - prompt：显式"简体中文 (Simplified Chinese)"，绝不能传 ISO 码（SPEC §7.3）
//   - CJK 占比验证：< 15% → 抛 translationLanguageDrift（service 层决定是否重试）
//

import Foundation

actor DeepSeekProvider: TranslationProvider {

    // MARK: - 配置

    /// 用户的 API key（sk-...）。空字符串视为未配置。
    let apiKey: String

    /// 模型名。默认 `deepseek-v4-flash`。M4 上 UI 后用户可选 pro。
    let model: String

    /// API endpoint。可注入用于 mock。
    let endpoint: URL

    /// HTTP 请求超时（秒）。字幕翻译批次小但偶发慢，给 60s 余量。
    let requestTimeout: TimeInterval

    /// 注入的 URLSession，方便测试用 stub。
    private let urlSession: URLSession

    /// 累计消耗的 total_tokens。每次成功 translate 后递增。
    private var _cumulativeTokens: Int = 0

    init(
        apiKey: String,
        model: String = "deepseek-v4-flash",
        endpoint: URL = URL(string: "https://api.deepseek.com/chat/completions")!,
        requestTimeout: TimeInterval = 60,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        self.urlSession = urlSession
    }

    // MARK: - TranslationProvider

    nonisolated var displayName: String { "DeepSeek (\(model))" }

    var isReady: Bool { !apiKey.isEmpty }

    var cumulativeTokens: Int { _cumulativeTokens }

    func translate(
        batch: [SrtLine],
        context: [SrtLine],
        source: Language?,
        target: Language
    ) async throws -> [SrtLine] {
        guard !apiKey.isEmpty else {
            throw SubtitleError.providerNotConfigured(providerName: displayName)
        }
        guard !batch.isEmpty else { return [] }

        let body = Self.buildRequestBody(
            model: model,
            batch: batch,
            context: context,
            source: source,
            target: target
        )
        let (data, status) = try await postJSON(body)

        switch status {
        case 200:
            break
        case 401:
            throw SubtitleError.providerInvalidKey(providerName: displayName)
        case 429:
            throw SubtitleError.providerRateLimited(providerName: displayName)
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SubtitleError.providerHTTPError(
                providerName: displayName,
                status: status,
                body: String(bodyStr.prefix(500))
            )
        }

        let parsed = try Self.parseChatResponse(data)
        _cumulativeTokens += parsed.totalTokens

        // 把 translations 跟 batch 行配对（按位置，DeepSeek 必须按 lines 顺序输出）
        guard parsed.translations.count == batch.count else {
            throw SubtitleError.translationBatchMalformed(
                reason: "expected \(batch.count) translations, got \(parsed.translations.count)"
            )
        }

        // CJK 占比验证（SPEC §7.3）：仅对 target=zh 启用
        if target == .simplifiedChinese {
            let joined = parsed.translations.joined(separator: "")
            let ratio = Self.cjkRatio(joined)
            if ratio < TranslationProviderConfig.minCJKRatioForChinese {
                throw SubtitleError.translationLanguageDrift(cjkRatio: ratio)
            }
        }

        return zip(batch, parsed.translations).map { (orig, text) in
            SrtLine(
                index: orig.index,
                startTime: orig.startTime,
                endTime: orig.endTime,
                text: text
            )
        }
    }

    // MARK: - HTTP

    /// POST JSON body 到 endpoint。返回 (data, statusCode)。
    /// 网络错误 → 抛 providerNetworkUnreachable。
    private func postJSON(_ jsonBody: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = jsonBody

        do {
            let (data, response) = try await urlSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let urlErr as URLError {
            // 网络层错误（断网、超时、DNS 解不出）统一归为不可达
            throw SubtitleError.providerNetworkUnreachable(
                providerName: "DeepSeek (\(urlErr.code.rawValue))"
            )
        } catch {
            throw SubtitleError.providerNetworkUnreachable(providerName: "DeepSeek")
        }
    }

    // MARK: - Prompt 构造（pure，可单测）

    /// 构造 chat completions 请求 body。
    /// - SystemMessage：固定规则 + 显式"简体中文 (Simplified Chinese)"
    /// - UserMessage：JSON 输入 {context, lines, sourceLang}
    /// - response_format：json_object，强制返回 JSON
    static func buildRequestBody(
        model: String,
        batch: [SrtLine],
        context: [SrtLine],
        source: Language?,
        target: Language
    ) -> Data {
        let systemPrompt = makeSystemPrompt(target: target)
        let userPrompt = makeUserPrompt(batch: batch, context: context, source: source)

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.3,
            "stream": false
        ]
        // 失败的话给个空 body，translate 调用会因 HTTP 400 抛错
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    static func makeSystemPrompt(target: Language) -> String {
        """
        你是一名专业的影视字幕翻译，把字幕翻译成 \(target.llmPromptName)。

        规则:
        1. 输入是 JSON 对象，包含:
           - sourceLang: 源语言（"auto" 表示未指定，按字面判断）
           - context: 已译过的若干行，仅供你参考避免代词指代漂移，**不要重复输出**
           - lines: 待翻译的若干行原文，按出现顺序排列
        2. 严格按 lines 顺序输出译文，长度必须等于 lines 长度。
        3. 输出 JSON: {"translations": ["译文1", "译文2", ...]}。除此之外不要输出任何额外文本。
        4. 译文必须是 \(target.llmPromptName)，不要保留外文音译占位词，更不要把识别不清的外文转成假名/英文。
        5. 如果某行原文是音译噪声或明显的识别错误（≥3 字符且明显不是真实词），输出"（？）"占位。
        6. 不要加序号、时间戳、说话人名前缀。保持口语化、自然。
        """
    }

    static func makeUserPrompt(
        batch: [SrtLine],
        context: [SrtLine],
        source: Language?
    ) -> String {
        let payload: [String: Any] = [
            "sourceLang": source?.llmPromptName ?? "auto",
            "context": context.map { $0.text },
            "lines": batch.map { $0.text }
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - 响应解析（pure，可单测）

    struct ParsedResponse: Equatable {
        let translations: [String]
        let totalTokens: Int
    }

    /// 解析 DeepSeek chat completions 响应：
    ///   choices[0].message.content 是模型生成的 JSON 字符串，再 parse 一次拿 translations。
    static func parseChatResponse(_ data: Data) throws -> ParsedResponse {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SubtitleError.translationBatchMalformed(reason: "outer JSON: \(error.localizedDescription)")
        }
        guard let root = json as? [String: Any] else {
            throw SubtitleError.translationBatchMalformed(reason: "outer JSON not an object")
        }

        // 提取 choices[0].message.content
        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SubtitleError.translationBatchMalformed(reason: "missing choices[0].message.content")
        }

        // content 是模型吐出的 JSON 字符串，再 parse
        guard let contentData = content.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let translations = inner["translations"] as? [String] else {
            throw SubtitleError.translationBatchMalformed(
                reason: "inner JSON missing 'translations' array. content=\(String(content.prefix(200)))"
            )
        }

        // total_tokens 缺失也不致命，按 0 处理
        let usage = root["usage"] as? [String: Any]
        let totalTokens = (usage?["total_tokens"] as? Int) ?? 0

        return ParsedResponse(translations: translations, totalTokens: totalTokens)
    }

    // MARK: - CJK 占比

    /// 算字符串里 CJK 表意字符的占比（不含标点和空白）。
    /// 用于 SPEC §7.3 语言漂移检测。
    static func cjkRatio(_ s: String) -> Double {
        var cjk = 0
        var counted = 0
        for scalar in s.unicodeScalars {
            // 跳过空白和标点
            if scalar.properties.isWhitespace { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            counted += 1
            let v = scalar.value
            // CJK Unified + Ext A + Ext B（简体中文 99% 落在前两个区间）
            if (0x4E00...0x9FFF).contains(v) ||
               (0x3400...0x4DBF).contains(v) ||
               (0x20000...0x2A6DF).contains(v) {
                cjk += 1
            }
        }
        if counted == 0 { return 1.0 }  // 空字符串视作"100% 通过"，避免误判
        return Double(cjk) / Double(counted)
    }
}
