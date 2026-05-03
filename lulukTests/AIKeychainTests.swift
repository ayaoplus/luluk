//
//  AIKeychainTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/3.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AIKeychain 读/写/删 round-trip 单元测试。验证 KeychainAccess.write 在
//  ADD 路径上把 value 写成 Data 后跟 read/delete 兼容（codex finding #3 回归）。
//
//  注意：会真的动 macOS Keychain，service name 用专属"AI Subtitle DeepSeek"
//  → 测试结束时必须清理。每个 case 自己 setup + teardown，避免互相污染。
//

import Testing
import Foundation
@testable import luluk

/// 这一组 case 共享一个 Keychain service name，必须串行跑，否则会互相覆盖
/// 导致间歇性 fail（Swift Testing 默认并发）。
@Suite(.serialized)
struct AIKeychainTests {

    /// 每个 case 跑前清掉 DeepSeek 槽位（防止上次失败留垃圾）。
    private func wipeDeepseek() {
        try? AIKeychain.deleteKey(for: .deepseek)
    }

    @Test func writeThenReadReturnsSameKey() throws {
        wipeDeepseek()
        defer { wipeDeepseek() }

        let key = "sk-test-\(UUID().uuidString)"
        try AIKeychain.writeKey(key, for: .deepseek)
        #expect(AIKeychain.readKey(for: .deepseek) == key)
    }

    /// 二次 write（update path）也应正确覆盖。这一步走的是 SecItemUpdate 分支，
    /// codex 标的是 ADD 分支的 String→Data 隐式桥接，update 分支本来就用 Data，
    /// 这里只是顺便回归覆盖路径不退化。
    @Test func writeOverridesPreviousKey() throws {
        wipeDeepseek()
        defer { wipeDeepseek() }

        try AIKeychain.writeKey("sk-old", for: .deepseek)
        try AIKeychain.writeKey("sk-new", for: .deepseek)
        #expect(AIKeychain.readKey(for: .deepseek) == "sk-new")
    }

    @Test func writeEmptyDeletes() throws {
        wipeDeepseek()
        defer { wipeDeepseek() }

        try AIKeychain.writeKey("sk-soon-gone", for: .deepseek)
        try AIKeychain.writeKey("", for: .deepseek)
        #expect(AIKeychain.readKey(for: .deepseek) == nil)
    }

    @Test func readMissingReturnsNil() {
        wipeDeepseek()
        #expect(AIKeychain.readKey(for: .deepseek) == nil)
    }

    @Test func deleteIsIdempotent() throws {
        wipeDeepseek()
        // 删一个不存在的 key 不应抛
        try AIKeychain.deleteKey(for: .deepseek)
        try AIKeychain.deleteKey(for: .deepseek)
    }

    @Test func writeTrimsWhitespace() throws {
        wipeDeepseek()
        defer { wipeDeepseek() }

        try AIKeychain.writeKey("  sk-trimmed  \n", for: .deepseek)
        #expect(AIKeychain.readKey(for: .deepseek) == "sk-trimmed")
    }
}
