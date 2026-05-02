//
//  SrtLineTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  SrtLine 序列化 / 解析单元测试。
//  对应 docs/AI_SUBTITLE_DESIGN.md M1 测试清单 + §5.1。
//

import Testing
import Foundation
@testable import luluk

struct SrtLineTests {

    // MARK: - 时间戳格式化

    @Test func formatTimestampZero() {
        #expect(SrtLine.formatTimestamp(0) == "00:00:00,000")
    }

    @Test func formatTimestampSubSecond() {
        #expect(SrtLine.formatTimestamp(0.123) == "00:00:00,123")
    }

    @Test func formatTimestampHourMinute() {
        // 1 小时 23 分 45.678 秒
        #expect(SrtLine.formatTimestamp(5025.678) == "01:23:45,678")
    }

    @Test func formatTimestampNegativeClampsToZero() {
        #expect(SrtLine.formatTimestamp(-5) == "00:00:00,000")
    }

    @Test func formatTimestampRoundsMillis() {
        // 0.0005 秒 → 取整到 1ms（Swift 的 .rounded() 默认 schoolbook，0.5 → 1）
        let result = SrtLine.formatTimestamp(0.0005)
        // 不强制 0.0005 必须 round 上去（依赖浮点），但接受 000 或 001
        #expect(result == "00:00:00,000" || result == "00:00:00,001")
    }

    // MARK: - 时间戳解析

    @Test func parseTimestampStandard() {
        #expect(SrtLine.parseTimestamp("01:23:45,678") == 5025.678)
    }

    @Test func parseTimestampDotMilliseconds() {
        // VLC 输出有时用 `.` 不用 `,`
        #expect(SrtLine.parseTimestamp("01:23:45.678") == 5025.678)
    }

    @Test func parseTimestampZero() {
        #expect(SrtLine.parseTimestamp("00:00:00,000") == 0)
    }

    @Test func parseTimestampInvalid() {
        #expect(SrtLine.parseTimestamp("not a time") == nil)
        #expect(SrtLine.parseTimestamp("01:23") == nil)  // 缺秒段
        #expect(SrtLine.parseTimestamp("") == nil)
    }

    // MARK: - 序列化

    @Test func srtFormattedSingleLine() {
        let line = SrtLine(index: 1, startTime: 1.234, endTime: 5.678, text: "你好世界")
        let expected = "1\n00:00:01,234 --> 00:00:05,678\n你好世界\n\n"
        #expect(line.srtFormatted() == expected)
    }

    @Test func srtFormattedMultilineText() {
        // 双语字幕 / Whisper 段落带换行
        let line = SrtLine(index: 7, startTime: 0, endTime: 3, text: "Hello\n你好")
        let expected = "7\n00:00:00,000 --> 00:00:03,000\nHello\n你好\n\n"
        #expect(line.srtFormatted() == expected)
    }

    // MARK: - 解析

    @Test func parseStandardSRT() {
        let srt = """
        1
        00:00:01,234 --> 00:00:05,678
        你好世界

        2
        00:00:06,000 --> 00:00:09,500
        第二行字幕


        """
        let lines = SrtLine.parse(srt)
        #expect(lines.count == 2)
        #expect(lines[0].index == 1)
        #expect(lines[0].startTime == 1.234)
        #expect(lines[0].endTime == 5.678)
        #expect(lines[0].text == "你好世界")
        #expect(lines[1].index == 2)
        #expect(lines[1].text == "第二行字幕")
    }

    @Test func parseHandlesCRLF() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\n字幕\r\n\r\n"
        let lines = SrtLine.parse(srt)
        #expect(lines.count == 1)
        #expect(lines[0].text == "字幕")
    }

    @Test func parseHandlesBOM() {
        let srt = "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\n字幕\n\n"
        let lines = SrtLine.parse(srt)
        #expect(lines.count == 1)
        #expect(lines[0].index == 1)
    }

    @Test func parseSkipsMalformedBlocks() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        正常字幕

        not_a_number
        00:00:03,000 --> 00:00:04,000
        会被跳过

        2
        00:00:05,000 --> 00:00:06,000
        又一个正常的


        """
        let lines = SrtLine.parse(srt)
        #expect(lines.count == 2)
        #expect(lines[0].text == "正常字幕")
        #expect(lines[1].text == "又一个正常的")
    }

    @Test func parseMultilineSubtitleText() {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000
        First line
        Second line


        """
        let lines = SrtLine.parse(srt)
        #expect(lines.count == 1)
        #expect(lines[0].text == "First line\nSecond line")
    }

    @Test func parseEmptyInput() {
        #expect(SrtLine.parse("").isEmpty)
        #expect(SrtLine.parse("\n\n\n").isEmpty)
    }

    // MARK: - 往返（serialize → parse 应该恢复原状）

    @Test func roundTripPreservesData() {
        let original = [
            SrtLine(index: 1, startTime: 1.234, endTime: 5.678, text: "Hello"),
            SrtLine(index: 2, startTime: 10.0, endTime: 12.5, text: "你好\n世界"),
        ]
        let serialized = original.map { $0.srtFormatted() }.joined()
        let parsed = SrtLine.parse(serialized)
        #expect(parsed == original)
    }

    @Test func durationCalculation() {
        let line = SrtLine(index: 1, startTime: 10, endTime: 15.5, text: "x")
        #expect(line.duration == 5.5)
    }
}
