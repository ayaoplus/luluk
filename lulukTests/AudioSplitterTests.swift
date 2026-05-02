//
//  AudioSplitterTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AudioSplitter 纯函数部分单元测试：
//   - parseSilenceLog: ffmpeg silencedetect stderr 解析
//   - computeCutPoints: 基于静音点 + 目标段长的切点算法
//
//  spawn ffmpeg / ffprobe 的部分留给集成测试（需要真实视频文件 + binary）。
//

import Testing
import Foundation
@testable import luluk

struct AudioSplitterTests {

    // MARK: - parseSilenceLog

    @Test func parsesPairedSilenceLines() {
        // ffmpeg 实际输出格式（hide_banner / nostats 不影响 silencedetect 行）
        let stderr = """
        [silencedetect @ 0x60000260c000] silence_start: 12.345
        [silencedetect @ 0x60000260c000] silence_end: 13.567 | silence_duration: 1.222
        [silencedetect @ 0x60000260c000] silence_start: 50.0
        [silencedetect @ 0x60000260c000] silence_end: 51.5 | silence_duration: 1.5
        """
        let result = AudioSplitter.parseSilenceLog(stderr)
        #expect(result.count == 2)
        #expect(result[0].start == 12.345)
        #expect(result[0].end == 13.567)
        #expect(result[1].start == 50.0)
        #expect(result[1].end == 51.5)
    }

    @Test func ignoresUnpairedTrailingStart() {
        // 文件结尾正好赶上静音 → 只有 silence_start 没有 silence_end
        let stderr = """
        [silencedetect @ 0x...] silence_start: 10.0
        [silencedetect @ 0x...] silence_end: 11.0 | silence_duration: 1.0
        [silencedetect @ 0x...] silence_start: 100.0
        """
        let result = AudioSplitter.parseSilenceLog(stderr)
        #expect(result.count == 1)
        #expect(result[0].start == 10.0)
    }

    @Test func returnsEmptyForNoSilenceMarkers() {
        let stderr = """
        ffmpeg version 8.0
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'video.mp4':
          Duration: 00:05:00.00
        Output #0, null, to 'pipe:':
        size=N/A time=00:05:00.00 bitrate=N/A
        """
        #expect(AudioSplitter.parseSilenceLog(stderr).isEmpty)
    }

    @Test func handlesEmptyInput() {
        #expect(AudioSplitter.parseSilenceLog("").isEmpty)
    }

    // MARK: - computeCutPoints

    @Test func shortVideoHasNoCuts() {
        // 视频比目标段还短 → 不切
        let cuts = AudioSplitter.computeCutPoints(
            duration: 30.0,
            silences: [],
            target: 45.0,
            tolerance: 15.0
        )
        #expect(cuts.isEmpty)
    }

    @Test func cutsOnSilenceMidpointWithinTolerance() {
        // 90 秒视频，target=45。第 40 秒附近有个 (38, 42) 的静音 → 切点应在 40.0
        let cuts = AudioSplitter.computeCutPoints(
            duration: 90.0,
            silences: [(start: 38.0, end: 42.0)],
            target: 45.0,
            tolerance: 15.0
        )
        #expect(cuts == [40.0])
    }

    @Test func fallsBackToHardCutWhenNoSilenceInWindow() {
        // 90 秒视频，target=45。静音在 80 秒（target+tolerance=60 之外）→ 硬切在 45.0
        let cuts = AudioSplitter.computeCutPoints(
            duration: 90.0,
            silences: [(start: 80.0, end: 81.0)],
            target: 45.0,
            tolerance: 15.0
        )
        #expect(cuts == [45.0])
    }

    @Test func multipleCutsAdvanceCursor() {
        // 200 秒视频，target=45 → 至少切 3-4 段。每段都从前一个切点开始重新算 target。
        let silences: [(TimeInterval, TimeInterval)] = [
            (44.0, 46.0),    // 第一刀附近
            (90.0, 91.0),    // 第二刀附近
            (140.0, 141.0),  // 第三刀附近
        ]
        let cuts = AudioSplitter.computeCutPoints(
            duration: 200.0,
            silences: silences,
            target: 45.0,
            tolerance: 15.0
        )
        // 期望切点：~45, ~90, ~140 (剩下的 60 秒 < target+0，一段就够)
        #expect(cuts.count >= 3)
        #expect(cuts[0] == 45.0)  // (44+46)/2 在 [30, 60] 内，最近 45
        // 后续每个切点都比前一个大
        for i in 1..<cuts.count {
            #expect(cuts[i] > cuts[i - 1])
        }
        // 最后一个切点离 duration 不远
        #expect(cuts.last! < 200.0)
    }

    @Test func picksClosestSilenceMidpoint() {
        // 同一区间多个候选，应该选离 target 最近的
        let cuts = AudioSplitter.computeCutPoints(
            duration: 90.0,
            silences: [
                (start: 35.0, end: 36.0),  // mid=35.5, |goal-mid|=9.5
                (start: 43.0, end: 44.0),  // mid=43.5, |goal-mid|=1.5  ← 应选这个
                (start: 55.0, end: 56.0),  // mid=55.5, |goal-mid|=10.5
            ],
            target: 45.0,
            tolerance: 15.0
        )
        #expect(cuts == [43.5])
    }
}
