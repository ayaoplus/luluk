//
//  TranscriptionResult.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕引擎数据结构：一段音频转写后的结果。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3。
//

import Foundation

/// whisper-cli 跑完一段后的输出。raw 数据，未经 Sanitizer 清理。
///
/// `lines` 的时间戳已被 WhisperRunner 加上 `AudioSegment.originalStartTime`
/// 偏移，所以是相对**原视频**的绝对时间，下游可以直接 merge。
struct TranscriptionResult: Sendable, Equatable {
    /// 跟 ``AudioSegment/index`` 一致，方便上游按段号对齐排序。
    let segmentIndex: Int

    /// whisper 检测出的语言（如果调用时 language=nil，由 whisper 自动检测）。
    /// 已显式指定 language 时，原样回写。
    let language: Language?

    /// 转写出的字幕行，时间戳已映射回原视频绝对时间。
    let lines: [SrtLine]

    /// 平均置信度（0~1）。SPEC §7.4 进阶用：低置信度可触发整段重检。
    /// whisper-cli `--output-json` 不直接给，需要 `--output-json-full` 解析 token avg_logprob，
    /// V1 暂时填 nil。
    let confidence: Double?

    init(segmentIndex: Int, language: Language?, lines: [SrtLine], confidence: Double? = nil) {
        self.segmentIndex = segmentIndex
        self.language = language
        self.lines = lines
        self.confidence = confidence
    }
}
