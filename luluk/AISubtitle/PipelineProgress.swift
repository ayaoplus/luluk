//
//  PipelineProgress.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕流水线对外暴露的进度快照。actor → AsyncStream → MainActor → UI。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.2。
//

import Foundation

/// 进度快照。每次状态变化（开始切片 / 转写完一段 / 翻译完一段 / 完成 / 失败）
/// `AISubtitleService` 都会推一份新的进入 progressStream。
///
/// UI（M4 才写）订阅这个 stream 实时刷新进度面板。
struct PipelineProgress: Sendable, Equatable {
    /// ffmpeg silencedetect 决定的总段数。-1 表示还没切完，未知。
    var totalSegments: Int

    /// 已完成 whisper 转写的段数。
    var transcribedSegments: Int

    /// 已完成翻译并写入 SRT 的段数。
    var translatedSegments: Int

    /// 流水线 start() 至今的秒数。
    var elapsedSeconds: Double

    /// 第一段从 start() 到翻译完成的耗时。SPEC §7.6 锁定基线 ~11s。
    var firstSubtitleLatency: Double?

    /// 基于已完成段速率推算的总耗时。前几段不稳定，> 2 段才有意义。
    var estimatedTotalSeconds: Double?

    /// 累计 token（DeepSeek 这类按 token 计费的 provider 用）。
    var tokensUsed: Int

    /// 当前主翻译 provider 的 displayName。
    var currentProvider: String

    /// 最近一次错误。silentFallback 类型也会出现在这里给 UI 提示，
    /// 但 state 仍可能是 .running（流水线没停）。
    var lastError: SubtitleError?

    /// 整体阶段。
    var state: State

    enum State: Sendable, Equatable {
        case idle
        case splitting              // ffmpeg 切片中
        case running                // 正常流水线
        case fallback(reason: String)
        case completed
        case cancelled
        case failed(SubtitleError)
    }

    /// 初始状态：刚 init service 还没 start 时。
    static func initial(provider: String) -> PipelineProgress {
        PipelineProgress(
            totalSegments: -1,
            transcribedSegments: 0,
            translatedSegments: 0,
            elapsedSeconds: 0,
            firstSubtitleLatency: nil,
            estimatedTotalSeconds: nil,
            tokensUsed: 0,
            currentProvider: provider,
            lastError: nil,
            state: .idle
        )
    }
}
