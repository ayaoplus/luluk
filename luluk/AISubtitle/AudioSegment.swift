//
//  AudioSegment.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕引擎数据结构：一个被切出来的音频段（whisper 的输入单位）。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3。
//

import Foundation

/// 音频段。AudioSplitter 切出来 → WhisperRunner 转写。
///
/// 每段是 16kHz mono WAV（whisper.cpp 的输入要求）。
/// `originalStartTime` 用于把 whisper 输出的相对时间戳映射回原视频绝对时间。
struct AudioSegment: Sendable, Equatable {
    /// 0-based 段号。同视频内连续递增。SRTMerger 用它排序。
    let index: Int

    /// 临时 WAV 文件 URL。AudioSplitter 写到 outputDir 下，
    /// AISubtitleService 在 cancel/finalize 时统一清理。
    let wavURL: URL

    /// 该段在原视频中的起始时间（秒）。
    /// whisper 输出的时间戳是 [0, duration]，需 + originalStartTime 才是绝对时间。
    let originalStartTime: TimeInterval

    /// 该段时长（秒）。等于 wav 文件实际时长。
    let duration: TimeInterval

    init(index: Int, wavURL: URL, originalStartTime: TimeInterval, duration: TimeInterval) {
        self.index = index
        self.wavURL = wavURL
        self.originalStartTime = originalStartTime
        self.duration = duration
    }
}
