//
//  SubtitleError.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕流水线统一错误类型。4 级分类对应不同 UI 行为
//  （fatal 弹窗 / userActionable 引导 / silentFallback 静默切 provider /
//   recoverableRetry 内部重试）。
//
//  对应 docs/AI_SUBTITLE_DESIGN.md §1.3。
//

import Foundation

/// 流水线各模块抛出的统一错误类型。
enum SubtitleError: Error, Equatable {
    // MARK: - Fatal: 整个流水线无法继续

    /// whisper-cli binary 找不到（首次启动未下载且 PATH 也没有）。
    case whisperBinaryMissing

    /// ffmpeg / ffprobe 找不到。
    case ffmpegBinaryMissing

    /// whisper 模型文件缺失（path 已知，UI 引导用户下载）。
    case modelMissing(expectedPath: String)

    /// 视频文件 mpv 能开但 ffmpeg 读不出（罕见，一般是 codec 问题）。
    case videoFileUnreadable(reason: String)

    /// 视频是网络流，AI 字幕 V1 不支持。
    case networkResourceNotSupported

    // MARK: - UserActionable: UI 弹窗让用户处理

    /// 所有 provider 都用尽（用户 key 失效 + 本地 NLLB 不在 + Cloud 余额光）。
    case allProvidersExhausted

    /// 当前 provider 没配 API key（M3 范围内 deepseek key 没设就归这个）。
    case providerNotConfigured(providerName: String)

    /// 模型下载失败。
    case modelDownloadFailed(url: URL, message: String)

    /// 磁盘空间不足。
    case insufficientDiskSpace

    /// 输出目录不可写（视频在只读卷上）。
    case outputDirectoryNotWritable(path: String)

    // MARK: - SilentFallback: 静默切 provider，进度面板提示

    /// provider 限流（429 / quota）。
    case providerRateLimited(providerName: String)

    /// provider key 失效（401）。
    case providerInvalidKey(providerName: String)

    /// 网络不通（离线）。
    case providerNetworkUnreachable(providerName: String)

    /// provider HTTP 错误（5xx 或非预期 status）。
    case providerHTTPError(providerName: String, status: Int, body: String)

    // MARK: - RecoverableRetry: 内部自动重试，用户感知不到

    /// whisper 转写超时（卡住）。
    case transcriptionTimeout(segmentIndex: Int)

    /// whisper-cli 进程非 0 退出。
    case transcriptionFailed(segmentIndex: Int, stderr: String)

    /// 翻译 batch JSON 解析失败 → 拆成单行重译。
    case translationBatchMalformed(reason: String)

    /// 译文 CJK 占比过低（SPEC §7.3：< 15% 触发重译）。
    case translationLanguageDrift(cjkRatio: Double)

    /// Sanitizer 丢弃一行（不算错误，只是日志）。M3 不会主动 throw 这个。
    case sanitizerLineDropped(reason: String)
}

extension SubtitleError {
    /// 简短描述，给进度面板 / log 用。
    var shortDescription: String {
        switch self {
        case .whisperBinaryMissing: return "未找到 whisper-cli"
        case .ffmpegBinaryMissing: return "未找到 ffmpeg"
        case .modelMissing(let p): return "模型文件缺失: \(p)"
        case .videoFileUnreadable(let r): return "视频不可读: \(r)"
        case .networkResourceNotSupported: return "暂不支持网络流字幕生成"
        case .allProvidersExhausted: return "所有翻译服务都不可用"
        case .providerNotConfigured(let n): return "\(n) 未配置"
        case .modelDownloadFailed(_, let m): return "模型下载失败: \(m)"
        case .insufficientDiskSpace: return "磁盘空间不足"
        case .outputDirectoryNotWritable(let p): return "字幕目录不可写: \(p)"
        case .providerRateLimited(let n): return "\(n) 限流"
        case .providerInvalidKey(let n): return "\(n) Key 无效"
        case .providerNetworkUnreachable(let n): return "\(n) 网络不可达"
        case .providerHTTPError(let n, let s, _): return "\(n) HTTP \(s)"
        case .transcriptionTimeout(let i): return "段 \(i) 转写超时"
        case .transcriptionFailed(let i, _): return "段 \(i) 转写失败"
        case .translationBatchMalformed(let r): return "翻译响应格式错: \(r)"
        case .translationLanguageDrift(let r): return String(format: "译文非中文（CJK %.1f%%）", r * 100)
        case .sanitizerLineDropped(let r): return "丢弃幻觉行: \(r)"
        }
    }
}
