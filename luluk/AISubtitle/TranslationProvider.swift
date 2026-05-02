//
//  TranslationProvider.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  字幕翻译服务的统一抽象。同一前端要服务两类用户：
//   - 普通观众 → luluk Cloud（M5）
//   - 极客 → 自带 DeepSeek/MiniMax/OpenAI/Custom（M3 起逐个加）
//   - 兜底 → 本地 NLLB（M5）
//
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.1.1。
//

import Foundation

/// 翻译一批字幕的统一协议。
///
/// 每个具体实现负责：
/// - 构造 prompt（System + User）
/// - 调对应 endpoint（多数走 OpenAI 兼容 client）
/// - 解析返回 JSON 回填 SrtLine
/// - 抛 ``SubtitleError`` 系列错误
protocol TranslationProvider: Sendable {

    /// UI 显示用名字（如 "DeepSeek" / "DeepSeek (你的 Key)"）。
    var displayName: String { get }

    /// 是否就绪（已配 key + endpoint 可达）。M3 范围：仅检查 key 非空。
    var isReady: Bool { get async }

    /// 翻译一批字幕。
    /// - Parameters:
    ///   - batch: 待翻译的字幕（最多 ``TranslationProviderConfig.batchSize``=8 行）。
    ///   - context: 前 ``TranslationProviderConfig.contextSize``=3 行作为上下文，
    ///     **不翻译**，仅给模型参考避免代词指代漂移（SPEC §5.3）。
    ///   - source: 源语言。nil 表示 whisper 自检的，provider 自己决定 prompt 怎么处理。
    ///   - target: 目标语言。V1 固定 .simplifiedChinese。
    /// - Returns: 跟 batch 同长、idx/start/end 对齐、text 替换为译文的 SrtLine 数组。
    /// - Throws: ``SubtitleError``。
    func translate(
        batch: [SrtLine],
        context: [SrtLine],
        source: Language?,
        target: Language
    ) async throws -> [SrtLine]

    /// 单行重译，给 batch 整批失败的退化路径用（SPEC §7.2）。
    /// 默认实现 = 调 ``translate`` 传 batch=[line]。
    func translateSingle(
        line: SrtLine,
        context: [SrtLine],
        source: Language?,
        target: Language
    ) async throws -> SrtLine

    /// 累计消耗 token。按 token 计费的 provider（DeepSeek/OpenAI/MiniMax）实现，
    /// 本地 NLLB / 其他默认返回 0。
    var cumulativeTokens: Int { get async }
}

extension TranslationProvider {
    /// 默认 single 实现：复用 batch 接口，size=1。
    func translateSingle(
        line: SrtLine,
        context: [SrtLine],
        source: Language?,
        target: Language
    ) async throws -> SrtLine {
        let result = try await translate(
            batch: [line],
            context: context,
            source: source,
            target: target
        )
        guard let first = result.first else {
            throw SubtitleError.translationBatchMalformed(reason: "single line empty response")
        }
        return first
    }

    /// 默认 0：不按 token 计费的 provider 不需要实现。
    var cumulativeTokens: Int { get async { 0 } }
}

/// 流水线 + provider 共享的常量。各 provider 实现不允许私改。
enum TranslationProviderConfig {
    /// 单批翻译的最大行数。SPEC §5.3 锁定。
    static let batchSize = 8

    /// 上下文窗口大小（不翻译，仅参考）。SPEC §5.3 锁定。
    static let contextSize = 3

    /// 译文 CJK 字符占比下限。SPEC §7.3：< 15% 触发"语言漂移"重译。
    static let minCJKRatioForChinese = 0.15
}
