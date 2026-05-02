//
//  Language.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  V1 支持的源/目标语言枚举。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.4 + SPEC §6（V1 6 种语言）。
//

import Foundation

/// V1 支持的语言（5 语对：en/ja/ko/ru/es ↔ zh）。
///
/// `rawValue` 是 ISO 639-1 两字母代码。
///
/// - Important: 调 LLM 时**绝对不要**直接传 `rawValue`（"zh" 会让 LLM 输出英文），
///              用 ``llmPromptName``。详见 SPEC §7.3。
enum Language: String, CaseIterable, Sendable, Codable {
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case spanish = "es"
    case simplifiedChinese = "zh"

    /// 给 LLM system prompt 用的显式语言名。
    ///
    /// SPEC §7.3 实测：传 ISO 码（"zh"）会让模型偶发误解读为英文。
    /// 必须传带括号的双语名（"简体中文 (Simplified Chinese)"）才能稳定。
    var llmPromptName: String {
        switch self {
        case .simplifiedChinese: return "简体中文 (Simplified Chinese)"
        case .english: return "English"
        case .japanese: return "日本語 (Japanese)"
        case .korean: return "한국어 (Korean)"
        case .russian: return "русский (Russian)"
        case .spanish: return "español (Spanish)"
        }
    }

    /// whisper-cli 的 `--language` 参数取值。
    /// whisper 接受 ISO 639-1，跟 `rawValue` 一致。
    var whisperCode: String { rawValue }

    /// UI 显示名（用户在设置面板看到）。
    var displayName: String {
        switch self {
        case .simplifiedChinese: return "中文（简体）"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .russian: return "俄语"
        case .spanish: return "西班牙语"
        }
    }

    /// CJK 字符判定（用于翻译输出语言验证，SPEC §7.3）。
    /// 译文是 `simplifiedChinese` 时，CJK 占比 < 15% 触发重译。
    var isCJK: Bool {
        switch self {
        case .simplifiedChinese, .japanese, .korean: return true
        default: return false
        }
    }
}
