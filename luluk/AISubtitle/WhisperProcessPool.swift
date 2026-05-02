//
//  WhisperProcessPool.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  全局 whisper 进程槽池子。SPEC §7.3 锁定：上限 5 个进程，多视频共享。
//
//  设计要点：
//   - 单视频内段级并发上限 3（在 AISubtitleService 里控）。
//   - 多视频同时开时所有 WhisperRunner 申请同一个 ``shared`` 池。
//   - 池子满 → 新请求**排队等**（不报错；UI 进度面板显示 "Queued"）。
//
//  对应 docs/AI_SUBTITLE_DESIGN.md §7.3。
//

import Foundation

/// 简单的 async 信号量风格池子。每个槽对应一个允许同时运行的 whisper-cli 进程。
actor WhisperProcessPool {

    /// 全局共享池。SPEC §7.3 锁定上限 5。
    static let shared = WhisperProcessPool(limit: 5)

    let limit: Int

    /// 当前占用的槽数（0...limit）。
    /// 释放时如果有等待者，槽直接转交，inUse 不递减。
    private var inUse: Int = 0

    /// FIFO 等待队列。第 limit+1 个 acquire 起塞这里。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0, "WhisperProcessPool limit must be > 0")
        self.limit = limit
    }

    // MARK: - 暴露给测试 / 监控

    /// 当前正在运行的 whisper 进程数。
    var currentInUse: Int { inUse }

    /// 当前在排队等槽的请求数。
    var waitingCount: Int { waiters.count }

    // MARK: - 公开 API

    /// 申请一个槽。槽满则挂起，直到有人 release。
    /// - Important: 必须有对应的 ``release()`` 调用，否则槽永久占用。
    ///              推荐用 ``withSlot(_:)`` 自动配对。
    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // resume 的时候 release 已经把槽"转交"给我们，inUse 保持不变
    }

    /// 释放一个槽。如果有等待者，直接交给队首；否则 inUse 减 1。
    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inUse = max(0, inUse - 1)
        }
    }

    /// 自动配对 acquire/release 的高阶方法。推荐调用方用这个。
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
