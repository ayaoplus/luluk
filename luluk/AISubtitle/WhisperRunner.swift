//
//  WhisperRunner.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  spawn whisper-cli + 解析 JSON 输出 → TranscriptionResult。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3 + SPEC §5.3。
//
//  whisper-cli 命令行（V1 锁定）：
//    whisper-cli -m <model> --vad -vm <silero.bin> \
//                -l <lang|auto> -oj -of <prefix> --no-prints <input.wav>
//
//  输出文件：<prefix>.json，结构由 whisper.cpp `-oj` 决定（见 transcription[] / offsets）。
//

import Foundation

enum WhisperRunnerError: Error, Equatable {
    /// whisper-cli 非 0 退出。
    case processFailed(exitCode: Int32, stderr: String)

    /// 找不到预期的 JSON 输出文件。
    case outputMissing(path: String)

    /// JSON 解析失败（whisper-cli 升级改格式时会触发）。
    case invalidJSON(String)
}

/// WhisperRunner：单段转写。无并发上限——并发由上层 ``WhisperProcessPool`` 控制。
actor WhisperRunner {

    let binaryURL: URL
    let modelURL: URL
    let vadModelURL: URL
    let useVAD: Bool
    let threads: Int

    init(
        binaryURL: URL,
        modelURL: URL,
        vadModelURL: URL,
        useVAD: Bool = true,
        threads: Int = 4
    ) {
        self.binaryURL = binaryURL
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL
        self.useVAD = useVAD
        self.threads = threads
    }

    /// 便捷构造：直接吃 ``WhisperPaths``（ModelDownloader 输出）。
    init(paths: WhisperPaths, useVAD: Bool = true, threads: Int = 4) {
        self.init(
            binaryURL: paths.binary,
            modelURL: paths.model,
            vadModelURL: paths.vadModel,
            useVAD: useVAD,
            threads: threads
        )
    }

    // MARK: - 公开 API

    /// 转写一段音频。
    /// - Parameters:
    ///   - audio: 16kHz mono WAV 段（AudioSplitter 产物）。
    ///   - language: nil → whisper 自动检测（不推荐，SPEC §7.6 已知误判）。
    /// - Returns: TranscriptionResult；时间戳已加上 audio.originalStartTime 偏移。
    func transcribe(
        audio: AudioSegment,
        language: Language?
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()

        // whisper-cli `-of <prefix>` → 输出写到 <prefix>.json
        let prefix = audio.wavURL.deletingPathExtension()
        let jsonURL = prefix.appendingPathExtension("json")
        // 上次跑剩的 json 先删，避免读到陈旧数据
        try? FileManager.default.removeItem(at: jsonURL)

        let args = buildArguments(audio: audio, language: language, outputPrefix: prefix)
        try await runWhisperCLI(arguments: args)

        // runWhisperCLI 取消路径上不抛 CancellationError（throws processFailed），
        // 这里再 check 一次把它翻译成上层期待的 CancellationError。
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw WhisperRunnerError.outputMissing(path: jsonURL.path)
        }
        let data = try Data(contentsOf: jsonURL)
        return try Self.parseTranscription(
            jsonData: data,
            audio: audio,
            requestedLanguage: language
        )
    }

    /// 把 whisper-cli `-oj` 的 JSON 解析成 ``TranscriptionResult``。
    /// internal static 是为了让单元测试能直接喂 fixture JSON 进来，不依赖真实 spawn。
    static func parseTranscription(
        jsonData: Data,
        audio: AudioSegment,
        requestedLanguage: Language?
    ) throws -> TranscriptionResult {
        let raw = try parseJSON(jsonData)
        let lines = raw.transcription.enumerated().compactMap { (i, seg) -> SrtLine? in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            let start = TimeInterval(seg.offsets.from) / 1000.0 + audio.originalStartTime
            let end = TimeInterval(seg.offsets.to) / 1000.0 + audio.originalStartTime
            // i+1 只是占位序号，最终编号由 SRTMerger 重排
            return SrtLine(index: i + 1, startTime: start, endTime: end, text: text)
        }
        // result.language 是 whisper 自检/回写的 ISO 码（"en" / "ja" / ...）
        let detectedLang = raw.result.language.flatMap { Language(rawValue: $0) } ?? requestedLanguage
        return TranscriptionResult(
            segmentIndex: audio.index,
            language: detectedLang,
            lines: lines,
            confidence: nil  // V1 不解析 token avg_logprob
        )
    }

    // MARK: - 命令行 + 进程

    /// 构造 whisper-cli 命令行参数列表（pure，方便单测断言）。
    func buildArguments(
        audio: AudioSegment,
        language: Language?,
        outputPrefix: URL
    ) -> [String] {
        var args: [String] = [
            "-m", modelURL.path,
            "-l", language?.whisperCode ?? "auto",
            "-oj",
            "-of", outputPrefix.path,
            "--no-prints",
            "-t", String(threads)
        ]
        if useVAD {
            args.append(contentsOf: ["--vad", "-vm", vadModelURL.path])
        }
        args.append(audio.wavURL.path)
        return args
    }

    /// spawn whisper-cli + 同步等结束。Task 取消时会主动 SIGTERM 子进程。
    ///
    /// **不能用 process.waitUntilExit()**——它内部依赖 RunLoop + mach port 收 termination
    /// notification，在 DispatchQueue 工作线程上 RunLoop 不可靠。已观察到 ffmpeg/whisper
    /// 进程早就退出了 wav 文件已写好，但 waitUntilExit 永远等不到通知，整个 pipeline 卡死。
    /// 改用 `terminationHandler` 直接拿到 exit 通知（不依赖 RunLoop）。
    ///
    /// 两个 pipe 必须**并发读**避免经典 Process+Pipe 死锁——任何一端 pipe buffer
    /// (默认 64KB) 满了子进程就阻塞写入，配合我们卡在 read 另一端就完全死锁。
    private func runWhisperCLI(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 起两个 dispatch block 并发 drain pipe（避免 buffer 满 deadlock）
        let drainGroup = DispatchGroup()
        let errBox = DataBox()
        let outBox = DataBox()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        try process.run()
        let handle = ProcessHandle(process: process)

        // 用 terminationHandler + continuation 拿 exit code（绕开 waitUntilExit 的 RunLoop 坑）
        let exitCode: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { p in
                    cont.resume(returning: p.terminationStatus)
                }
            }
        } onCancel: {
            handle.process.terminate()
        }

        // process 死了，pipe 写端被 kernel 关掉，readDataToEndOfFile 收 EOF 立刻返回
        drainGroup.wait()

        if exitCode != 0 {
            let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
            throw WhisperRunnerError.processFailed(exitCode: exitCode, stderr: stderr)
        }
    }

    /// Process 不是 Sendable，但跨 actor 边界传引用对 terminate() 是安全的。
    private struct ProcessHandle: @unchecked Sendable {
        let process: Process
    }

    /// 让两个并发 dispatch block 各自写入 Data，主线程读取最终结果。
    /// 写一次（自己的 block 内）/ 读一次（drainGroup.wait 之后），不需要锁。
    private final class DataBox: @unchecked Sendable {
        var data: Data = Data()
    }

    // MARK: - JSON 解析

    /// whisper.cpp `-oj` 输出的 JSON schema（最小子集，只取我们用得到的字段）。
    struct WhisperJSON: Decodable {
        let result: ResultBlock
        let transcription: [Segment]

        struct ResultBlock: Decodable {
            let language: String?
        }
        struct Segment: Decodable {
            let offsets: Offsets
            let text: String
        }
        struct Offsets: Decodable {
            /// 段起始时间，毫秒
            let from: Int
            /// 段结束时间，毫秒
            let to: Int
        }
    }

    static func parseJSON(_ data: Data) throws -> WhisperJSON {
        do {
            return try JSONDecoder().decode(WhisperJSON.self, from: data)
        } catch {
            throw WhisperRunnerError.invalidJSON(String(describing: error))
        }
    }
}
