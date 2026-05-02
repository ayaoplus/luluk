//
//  AudioSplitter.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  把视频切成 ~45s 的 16kHz mono WAV 段（whisper.cpp 的输入格式）。
//  在静音点对齐切口，避免在话语中间断开。
//
//  流程（参考 SPEC §5.2 + ai-subtitle-prototype/pipeline/audio_split.py）：
//    1. ffprobe 探时长（SPEC §7.4 锁定：不依赖 mpv）
//    2. ffmpeg silencedetect 一次性扫全片，解析 stderr 拿到静音区间
//    3. 计算切点：每 ~targetSegmentDuration 秒在最近的静音中点切
//    4. 逐段 spawn ffmpeg 提取 WAV，每提取完一段 yield 一个 AudioSegment
//
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3。
//

import Foundation

enum AudioSplitterError: Error, Equatable {
    /// 找不到 ffmpeg/ffprobe（应用目录 + PATH 都没有）。
    case ffmpegBinaryMissing(name: String, searched: [String])

    /// ffprobe 跑完但拿不到 duration（视频损坏 / 非视频文件）。
    case durationProbeFailed(stderr: String)

    /// ffmpeg 进程非 0 退出。
    case processFailed(command: String, exitCode: Int32, stderr: String)

    /// 输出 WAV 文件不存在或为空（ffmpeg 自报成功但实际没写出）。
    case outputMissing(path: String)
}

/// AudioSplitter：spawn ffmpeg + 解析 silencedetect → AsyncThrowingStream<AudioSegment>。
actor AudioSplitter {

    /// 默认切段长度 45 秒（SPEC §5.2 流水线设计）。
    static let defaultSegmentDuration: TimeInterval = 45.0

    /// silencedetect 阈值。-30dB + ≥0.5s 静默才算"安静处可切"。
    /// 值取自 ai-subtitle-prototype/pipeline/audio_split.py 实测。
    static let silenceNoiseDb: Double = -30.0
    static let silenceMinDuration: Double = 0.5

    /// 切点容忍偏移：targetSegmentDuration ± toleranceSeconds 内找静音中点；
    /// 找不到就在 target 处硬切。避免段长太离谱。
    static let toleranceSeconds: TimeInterval = 15.0

    private let ffmpegPath: String
    private let ffprobePath: String

    /// 是否启用 silencedetect 全片扫描对齐切点。
    /// **M3 默认 false**：1 小时视频 silencedetect 要 ~90s，跟 SPEC §5.2
    /// 锁的"首字幕 11s"承诺冲突。直接硬切的代价是段边界偶尔切在话语中间，
    /// whisper VAD 会处理 padding，中间可能丢 1 行字幕——可接受。
    /// M5 优化方案：silencedetect 跑 background，第一段硬切先出，
    /// 后续段等 silencedetect 完成再用精确切点。
    let useSilenceDetection: Bool

    /// 默认构造器：自动定位 ffmpeg/ffprobe（应用目录优先 → PATH）。
    init(useSilenceDetection: Bool = false) throws {
        self.ffmpegPath = try Self.locateBinary("ffmpeg")
        self.ffprobePath = try Self.locateBinary("ffprobe")
        self.useSilenceDetection = useSilenceDetection
    }

    /// 测试 / 显式注入用的构造器。
    init(ffmpegPath: String, ffprobePath: String, useSilenceDetection: Bool = false) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
        self.useSilenceDetection = useSilenceDetection
    }

    // MARK: - 公开 API

    /// 切音频。返回一个 AsyncThrowingStream，每段切好就 yield 一个 AudioSegment。
    ///
    /// - Parameters:
    ///   - videoURL: 本地视频文件 URL（不支持 stream，调用方在更上层 gate）。
    ///   - outputDir: 临时 WAV 写到这里。AudioSplitter 不删 WAV，由调用方在
    ///     pipeline 完成/cancel 时清理。
    ///   - targetSegmentDuration: 目标段长，实际段长是 [target-tolerance, target+tolerance]。
    /// - Returns: AsyncThrowingStream，task cancel 时会杀掉正在跑的 ffmpeg。
    nonisolated func split(
        videoURL: URL,
        outputDir: URL,
        targetSegmentDuration: TimeInterval = AudioSplitter.defaultSegmentDuration
    ) -> AsyncThrowingStream<AudioSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runSplit(
                        videoURL: videoURL,
                        outputDir: outputDir,
                        targetSegmentDuration: targetSegmentDuration,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 算法核心

    /// 探时长 + 找静音点 + 计算切点 + 逐段提取。
    private func runSplit(
        videoURL: URL,
        outputDir: URL,
        targetSegmentDuration: TimeInterval,
        continuation: AsyncThrowingStream<AudioSegment, Error>.Continuation
    ) async throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        NSLog("%@", "[luluk-ai/splitter] ffmpeg=\(ffmpegPath) ffprobe=\(ffprobePath)")

        NSLog("%@", "[luluk-ai/splitter] probeDuration starting")
        let t0 = Date()
        let duration = try probeDuration(videoURL: videoURL)
        NSLog("%@", "[luluk-ai/splitter] probeDuration DONE: \(String(format: "%.1f", duration))s in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

        // M3 默认跳过 silencedetect（长视频扫全片要数分钟，跟首字幕 11s 承诺冲突）。
        let silences: [(start: TimeInterval, end: TimeInterval)]
        if useSilenceDetection {
            NSLog("%@", "[luluk-ai/splitter] detectSilences starting (scans whole file)")
            let t1 = Date()
            silences = try detectSilences(videoURL: videoURL)
            NSLog("%@", "[luluk-ai/splitter] detectSilences DONE: \(silences.count) silences in \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
        } else {
            NSLog("%@", "[luluk-ai/splitter] silencedetect skipped (hard-cut every \(Int(targetSegmentDuration))s)")
            silences = []
        }

        let cutPoints = Self.computeCutPoints(
            duration: duration,
            silences: silences,
            target: targetSegmentDuration,
            tolerance: AudioSplitter.toleranceSeconds
        )
        NSLog("%@", "[luluk-ai/splitter] computed \(cutPoints.count) cut points → \(cutPoints.count + 1) segments expected")

        // 切点把 [0, duration] 分成 N 段：[0, cut[0]], [cut[0], cut[1]], ..., [cut[last], duration]
        var prev: TimeInterval = 0
        var index = 0
        let starts = [0.0] + cutPoints
        let ends = cutPoints + [duration]

        for (segStart, segEnd) in zip(starts, ends) {
            try Task.checkCancellation()
            let segDuration = segEnd - segStart
            // 段长 < 0.5s 就跳过（避免末尾残渣 + whisper 输入太短报错）
            if segDuration < 0.5 {
                prev = segEnd
                continue
            }
            let wavURL = outputDir.appendingPathComponent(String(format: "seg_%05d.wav", index))
            let tExt = Date()
            NSLog("%@", "[luluk-ai/splitter] extract seg #\(index) [\(String(format: "%.1f", segStart))s, +\(String(format: "%.1f", segDuration))s]")
            try extractSegment(
                videoURL: videoURL,
                start: segStart,
                duration: segDuration,
                outputWAV: wavURL
            )
            NSLog("%@", "[luluk-ai/splitter] extract seg #\(index) DONE in \(String(format: "%.2f", Date().timeIntervalSince(tExt)))s")
            let segment = AudioSegment(
                index: index,
                wavURL: wavURL,
                originalStartTime: segStart,
                duration: segDuration
            )
            continuation.yield(segment)
            index += 1
            prev = segEnd
        }
        _ = prev  // silence unused warning
    }

    // MARK: - ffprobe / ffmpeg 调用

    /// `ffprobe -v error -show_entries format=duration -of csv=p=0 <video>` → 秒数。
    private func probeDuration(videoURL: URL) throws -> TimeInterval {
        let result = try runProcess(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "csv=p=0",
                videoURL.path
            ]
        )
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dur = Double(trimmed), dur > 0 else {
            throw AudioSplitterError.durationProbeFailed(stderr: result.stderr)
        }
        return dur
    }

    /// `ffmpeg -i <video> -af silencedetect=noise=-30dB:d=0.5 -f null -` → 解析 stderr。
    /// stderr 里每对静音段会出现两行：`silence_start: X` + `silence_end: Y | silence_duration: Z`。
    func detectSilences(videoURL: URL) throws -> [(start: TimeInterval, end: TimeInterval)] {
        let noiseArg = String(format: "silencedetect=noise=%.0fdB:d=%.1f",
                              AudioSplitter.silenceNoiseDb,
                              AudioSplitter.silenceMinDuration)
        let result = try runProcess(
            executable: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-nostats",
                "-i", videoURL.path,
                "-af", noiseArg,
                "-f", "null",
                "-"
            ],
            // ffmpeg 的 silencedetect 输出走 stderr，且会 exit 0
            allowNonZeroExit: false
        )
        return AudioSplitter.parseSilenceLog(result.stderr)
    }

    /// `ffmpeg -ss <start> -i <video> -t <dur> -ac 1 -ar 16000 -c:a pcm_s16le -y <out.wav>`
    /// 注意 `-ss` 放 `-i` 前面是 fast seek（关键帧对齐，对纯音频提取够用）。
    private func extractSegment(
        videoURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        outputWAV: URL
    ) throws {
        _ = try runProcess(
            executable: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-nostats",
                "-loglevel", "error",
                "-ss", String(format: "%.3f", start),
                "-i", videoURL.path,
                "-t", String(format: "%.3f", duration),
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                "-y",
                outputWAV.path
            ]
        )
        let attrs = try? FileManager.default.attributesOfItem(atPath: outputWAV.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size <= 44 {  // WAV header 是 44 字节，纯 header 等于"空"
            throw AudioSplitterError.outputMissing(path: outputWAV.path)
        }
    }

    // MARK: - 解析 + 切点算法（pure，可单元测）

    /// 从 ffmpeg silencedetect 的 stderr 里解析所有静音区间。
    /// 容错：未配对的 silence_start（流末尾）丢弃。
    static func parseSilenceLog(_ stderr: String) -> [(start: TimeInterval, end: TimeInterval)] {
        var pendingStart: TimeInterval?
        var result: [(TimeInterval, TimeInterval)] = []
        for line in stderr.split(separator: "\n") {
            let s = String(line)
            if let v = extractValue(after: "silence_start: ", in: s) {
                pendingStart = v
            } else if let v = extractValue(after: "silence_end: ", in: s) {
                if let start = pendingStart {
                    result.append((start, v))
                    pendingStart = nil
                }
            }
        }
        return result
    }

    private static func extractValue(after prefix: String, in line: String) -> TimeInterval? {
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        // 取到第一个空格 / pipe 之前的数字
        let stop = CharacterSet(charactersIn: " |\t")
        var num = ""
        for ch in tail {
            if ch.unicodeScalars.contains(where: { stop.contains($0) }) { break }
            num.append(ch)
        }
        return Double(num)
    }

    /// 给定视频时长 + 静音区间 + 目标段长 + 容差，返回切点时间戳列表。
    /// 切点尽量落在静音中点；找不到就硬切在 target 上。
    static func computeCutPoints(
        duration: TimeInterval,
        silences: [(start: TimeInterval, end: TimeInterval)],
        target: TimeInterval,
        tolerance: TimeInterval
    ) -> [TimeInterval] {
        guard duration > target else { return [] }
        let mids = silences.map { ($0.start + $0.end) / 2 }
        var cuts: [TimeInterval] = []
        var cursor: TimeInterval = 0
        // 循环条件：剩余长度 > target+tolerance 才再切。
        // 这样最后一段长度 ≤ target+tolerance（默认 60s），避免无谓的尾刀。
        while duration - cursor > target + tolerance {
            let goal = cursor + target
            let lo = goal - tolerance
            let hi = goal + tolerance
            // 在 [lo, hi] 区间里找离 goal 最近的静音中点
            let candidate = mids
                .filter { $0 > cursor && $0 >= lo && $0 <= hi }
                .min(by: { abs($0 - goal) < abs($1 - goal) })
            let cut = candidate ?? goal
            // 防御：cut 必须严格 > cursor，否则死循环
            if cut <= cursor + 0.5 { break }
            cuts.append(cut)
            cursor = cut
        }
        return cuts
    }

    // MARK: - Process 工具

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// 通用 spawn + wait + 收集 stdout/stderr。
    /// allowNonZeroExit=false 时非 0 退出会 throw。
    @discardableResult
    private func runProcess(
        executable: String,
        arguments: [String],
        allowNonZeroExit: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // 注意：必须先 read 再 waitUntilExit，否则大 pipe 会塞满阻塞子进程。
        // ffmpeg 输出有限，先 readToEnd 再 wait 是安全的。
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8) ?? ""
        let code = process.terminationStatus

        if code != 0 && !allowNonZeroExit {
            throw AudioSplitterError.processFailed(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: code,
                stderr: stderrStr
            )
        }
        return ProcessResult(exitCode: code, stdout: stdoutStr, stderr: stderrStr)
    }

    // MARK: - 定位 ffmpeg/ffprobe

    /// 应用目录 → PATH → 常见 brew 路径。三层 fallback。
    static func locateBinary(_ name: String) throws -> String {
        var searched: [String] = []

        let appBin = ModelDownloader.binDirectory.appendingPathComponent(name)
        searched.append(appBin.path)
        if FileManager.default.isExecutableFile(atPath: appBin.path) {
            return appBin.path
        }

        if let p = ModelDownloader.findInPATH(name) {
            return p
        }
        searched.append("$PATH")

        // brew 常见位置（开发期 fallback，避免没设 PATH 的 GUI 启动找不到）
        let fallbacks = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for f in fallbacks {
            searched.append(f)
            if FileManager.default.isExecutableFile(atPath: f) {
                return f
            }
        }
        throw AudioSplitterError.ffmpegBinaryMissing(name: name, searched: searched)
    }
}
