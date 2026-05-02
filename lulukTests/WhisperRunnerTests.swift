//
//  WhisperRunnerTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  WhisperRunner 单元测试：
//   - buildArguments: 命令行参数组装
//   - parseTranscription: whisper-cli `-oj` JSON → TranscriptionResult
//
//  spawn whisper-cli 的部分留给手动 integration test（依赖模型 + 真实音频）。
//

import Testing
import Foundation
@testable import luluk

struct WhisperRunnerTests {

    // 公用 fixture
    private static func makeRunner(useVAD: Bool = true) -> WhisperRunner {
        WhisperRunner(
            binaryURL: URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
            modelURL: URL(fileURLWithPath: "/tmp/ggml-large-v3-turbo.bin"),
            vadModelURL: URL(fileURLWithPath: "/tmp/ggml-silero-v5.1.2.bin"),
            useVAD: useVAD
        )
    }

    private static func makeAudio() -> AudioSegment {
        AudioSegment(
            index: 7,
            wavURL: URL(fileURLWithPath: "/tmp/seg_00007.wav"),
            originalStartTime: 100.0,
            duration: 45.0
        )
    }

    // MARK: - buildArguments

    @Test func argumentsContainModelAndOutput() async {
        let runner = Self.makeRunner()
        let audio = Self.makeAudio()
        let prefix = audio.wavURL.deletingPathExtension()
        let args = await runner.buildArguments(
            audio: audio,
            language: .japanese,
            outputPrefix: prefix
        )
        // 必须显式 -m + 模型
        #expect(args.contains("-m"))
        #expect(args.contains("/tmp/ggml-large-v3-turbo.bin"))
        // 必须显式 -l + 语言（SPEC §7.6 决策）
        #expect(args.contains("-l"))
        #expect(args.contains("ja"))
        // -oj + -of 输出 JSON
        #expect(args.contains("-oj"))
        #expect(args.contains("-of"))
        #expect(args.contains(prefix.path))
        // 输入文件作为 positional 在最后
        #expect(args.last == "/tmp/seg_00007.wav")
    }

    @Test func nilLanguageBecomesAuto() async {
        let runner = Self.makeRunner()
        let audio = Self.makeAudio()
        let args = await runner.buildArguments(
            audio: audio,
            language: nil,
            outputPrefix: audio.wavURL.deletingPathExtension()
        )
        // -l 后面紧跟 "auto"
        let lIdx = args.firstIndex(of: "-l")!
        #expect(args[lIdx + 1] == "auto")
    }

    @Test func vadOnIncludesVadModel() async {
        let runner = Self.makeRunner(useVAD: true)
        let audio = Self.makeAudio()
        let args = await runner.buildArguments(
            audio: audio,
            language: .japanese,
            outputPrefix: audio.wavURL.deletingPathExtension()
        )
        #expect(args.contains("--vad"))
        #expect(args.contains("-vm"))
        #expect(args.contains("/tmp/ggml-silero-v5.1.2.bin"))
    }

    @Test func vadOffOmitsVadFlags() async {
        let runner = Self.makeRunner(useVAD: false)
        let audio = Self.makeAudio()
        let args = await runner.buildArguments(
            audio: audio,
            language: .japanese,
            outputPrefix: audio.wavURL.deletingPathExtension()
        )
        #expect(!args.contains("--vad"))
        #expect(!args.contains("-vm"))
    }

    // MARK: - parseTranscription

    private static let sampleJSON = """
    {
      "systeminfo": "AVX = 1",
      "model": {"type": "large-v3-turbo"},
      "params": {"language": "ja"},
      "result": {"language": "ja"},
      "transcription": [
        {
          "timestamps": {"from": "00:00:00,000", "to": "00:00:02,140"},
          "offsets": {"from": 0, "to": 2140},
          "text": " こんにちは。"
        },
        {
          "timestamps": {"from": "00:00:02,200", "to": "00:00:05,000"},
          "offsets": {"from": 2200, "to": 5000},
          "text": " 元気ですか?"
        }
      ]
    }
    """

    @Test func parsesLinesWithOffsetApplied() throws {
        let audio = Self.makeAudio()  // originalStartTime = 100
        let data = Self.sampleJSON.data(using: .utf8)!
        let result = try WhisperRunner.parseTranscription(
            jsonData: data,
            audio: audio,
            requestedLanguage: nil
        )
        #expect(result.segmentIndex == 7)
        #expect(result.language == .japanese)
        #expect(result.lines.count == 2)
        // 第一行：offsets 0..2140 ms → 100..102.14 (秒，加 originalStartTime)
        #expect(result.lines[0].startTime == 100.0)
        #expect(result.lines[0].endTime == 102.14)
        #expect(result.lines[0].text == "こんにちは。")  // 前导空格已 trim
        // 第二行：offsets 2200..5000 ms → 102.2..105.0
        #expect(result.lines[1].startTime == 102.2)
        #expect(result.lines[1].endTime == 105.0)
        #expect(result.lines[1].text == "元気ですか?")
    }

    @Test func dropsEmptyTextLines() throws {
        let json = """
        {
          "result": {"language": "en"},
          "transcription": [
            {"offsets": {"from": 0, "to": 1000}, "text": " "},
            {"offsets": {"from": 1000, "to": 2000}, "text": "hello"},
            {"offsets": {"from": 2000, "to": 3000}, "text": ""}
          ]
        }
        """.data(using: .utf8)!
        let result = try WhisperRunner.parseTranscription(
            jsonData: json,
            audio: Self.makeAudio(),
            requestedLanguage: nil
        )
        #expect(result.lines.count == 1)
        #expect(result.lines[0].text == "hello")
    }

    @Test func usesRequestedLanguageWhenJSONHasNone() throws {
        let json = """
        {
          "result": {},
          "transcription": []
        }
        """.data(using: .utf8)!
        let result = try WhisperRunner.parseTranscription(
            jsonData: json,
            audio: Self.makeAudio(),
            requestedLanguage: .korean
        )
        #expect(result.language == .korean)
    }

    @Test func throwsOnInvalidJSON() {
        let bad = Data("{not json}".utf8)
        #expect(throws: WhisperRunnerError.self) {
            _ = try WhisperRunner.parseTranscription(
                jsonData: bad,
                audio: Self.makeAudio(),
                requestedLanguage: nil
            )
        }
    }
}
