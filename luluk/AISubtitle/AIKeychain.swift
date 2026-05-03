//
//  AIKeychain.swift
//  luluk
//
//  Created by ayao on 2026/5/3.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕 provider 的 API key Keychain 封装。M4 起替代 Preference 明文存储。
//
//  设计要点：
//   - 复用 IINA 既有 KeychainAccess（generic password / service name）
//   - 每个 provider 一个 ServiceName，username 固定 "default"（V1 不支持多账号）
//   - read 永远不抛——key 不存在等价于 nil（UI 只关心"有没有"）
//   - write 收到空串等价于 delete（UI 文本框清空就意味着删 key）
//   - 一次性 migration：把旧 Preference.aiSubtitleDeepSeekKey 搬过来后清空 Preference
//

import Foundation

enum AIKeychain {

    /// 翻译 provider 枚举。V1 锁 5 个；扩展时同步加 ServiceName。
    enum Provider: String, CaseIterable {
        case deepseek
        case minimax
        case openai
        case custom
        case lulukCloud
    }

    /// 每个 provider 对应一个 Keychain ServiceName，key 卸载/重装 app 不丢。
    private static func service(for provider: Provider) -> KeychainAccess.ServiceName {
        switch provider {
        case .deepseek:   return KeychainAccess.ServiceName("luluk AI Subtitle DeepSeek")
        case .minimax:    return KeychainAccess.ServiceName("luluk AI Subtitle MiniMax")
        case .openai:     return KeychainAccess.ServiceName("luluk AI Subtitle OpenAI")
        case .custom:     return KeychainAccess.ServiceName("luluk AI Subtitle Custom Provider")
        case .lulukCloud: return KeychainAccess.ServiceName("luluk AI Subtitle Cloud Account")
        }
    }

    /// V1 单账号——username 固定。M5 接 LulukCloud 时再考虑多账号。
    private static let defaultAccount = "default"

    /// 读 key。不存在或读失败统一返回 nil（UI 只看有/无）。
    static func readKey(for provider: Provider) -> String? {
        do {
            let result = try KeychainAccess.read(username: defaultAccount, forService: service(for: provider))
            let trimmed = result.password.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch KeychainAccess.KeychainError.noResult {
            return nil
        } catch {
            NSLog("%@", "[luluk-ai] Keychain read failed for \(provider.rawValue): \(error)")
            return nil
        }
    }

    /// 写 key。空串等价于 delete（防止 UI 清空后还残留旧 key）。
    /// 失败时上抛，让 UI 显示 alert。
    static func writeKey(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteKey(for: provider)
            return
        }
        try KeychainAccess.write(
            username: defaultAccount,
            password: trimmed,
            forService: service(for: provider)
        )
    }

    /// 删 key。errSecItemNotFound 视为成功（已经空了）。
    static func deleteKey(for provider: Provider) throws {
        try KeychainAccess.delete(forService: service(for: provider), account: defaultAccount)
    }

    /// 一次性把旧 Preference.aiSubtitleDeepSeekKey 搬到 Keychain，再清空 Preference。
    /// AppDelegate.applicationDidFinishLaunching 调一次；migration 后续启动 no-op。
    /// 已迁过的标记：Keychain 已有非空 DeepSeek key 时不再覆盖。
    static func migrateLegacyPreferenceKeysIfNeeded() {
        let legacy = (Preference.string(for: .aiSubtitleDeepSeekKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return }

        if readKey(for: .deepseek) != nil {
            // Keychain 已有，旧 Preference 残留直接清掉
            Preference.set("", for: .aiSubtitleDeepSeekKey)
            return
        }

        do {
            try writeKey(legacy, for: .deepseek)
            Preference.set("", for: .aiSubtitleDeepSeekKey)
            NSLog("%@", "[luluk-ai] migrated DeepSeek key from Preference -> Keychain")
        } catch {
            NSLog("%@", "[luluk-ai] DeepSeek key migration failed: \(error) — leaving Preference value intact")
        }
    }
}
