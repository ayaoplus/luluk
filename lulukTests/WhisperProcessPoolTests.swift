//
//  WhisperProcessPoolTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  WhisperProcessPool 并发语义单元测试。SPEC §7.3 锁定全局上限 5。
//

import Testing
import Foundation
@testable import luluk

struct WhisperProcessPoolTests {

    @Test func acquireWithinLimitDoesNotBlock() async throws {
        let pool = WhisperProcessPool(limit: 3)
        try await pool.acquire()
        try await pool.acquire()
        try await pool.acquire()
        let inUse = await pool.currentInUse
        #expect(inUse == 3)
        let waiting = await pool.waitingCount
        #expect(waiting == 0)
    }

    @Test func releaseDecrementsWhenNoWaiters() async throws {
        let pool = WhisperProcessPool(limit: 2)
        try await pool.acquire()
        try await pool.acquire()
        await pool.release()
        let inUse = await pool.currentInUse
        #expect(inUse == 1)
    }

    @Test func waitersGetSlotWhenReleased() async throws {
        let pool = WhisperProcessPool(limit: 1)
        try await pool.acquire()  // 把唯一的槽占了

        // 起一个 task 排队，应该挂起
        let waitTask = Task { try await pool.acquire() }

        // 让出几次让 acquire 真正进入 waiters
        for _ in 0..<5 { await Task.yield() }
        let waiting = await pool.waitingCount
        #expect(waiting == 1)

        // release → 槽转交给 waitTask
        await pool.release()
        _ = try await waitTask.value

        let stillWaiting = await pool.waitingCount
        #expect(stillWaiting == 0)
        // inUse 不变（槽转交，没有真正"释放再分配"）
        let inUse = await pool.currentInUse
        #expect(inUse == 1)
    }

    /// 排队时 task 取消应该把 waiter 从队列里移除并抛 CancellationError，
    /// 同时不影响其它正常 acquire 流程。回归 codex finding #5。
    @Test func cancelledWaiterIsRemovedAndDoesNotLeak() async throws {
        let pool = WhisperProcessPool(limit: 1)
        try await pool.acquire()  // 占满

        // task A 进队列
        let cancelTask = Task { try await pool.acquire() }
        for _ in 0..<5 { await Task.yield() }
        #expect(await pool.waitingCount == 1)

        // 取消 → 队列应清空
        cancelTask.cancel()
        do {
            try await cancelTask.value
            Issue.record("cancelled task should have thrown")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(await pool.waitingCount == 0)

        // 后续正常 acquire 仍然行得通
        let nextTask = Task { try await pool.acquire() }
        for _ in 0..<5 { await Task.yield() }
        await pool.release()
        _ = try await nextTask.value
        #expect(await pool.currentInUse == 1)
    }

    @Test func withSlotReleasesOnSuccess() async throws {
        let pool = WhisperProcessPool(limit: 2)
        let result = try await pool.withSlot { 42 }
        #expect(result == 42)
        let inUse = await pool.currentInUse
        #expect(inUse == 0)
    }

    @Test func withSlotReleasesOnThrow() async {
        struct Boom: Error {}
        let pool = WhisperProcessPool(limit: 2)
        do {
            _ = try await pool.withSlot { throw Boom() }
            Issue.record("should have thrown")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let inUse = await pool.currentInUse
        #expect(inUse == 0)
    }

    @Test func limitOneSerializesAccess() async {
        // 四个并发任务竞争 limit=1 的池子，最终都能跑完且 currentInUse 归零
        let pool = WhisperProcessPool(limit: 1)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? await pool.withSlot {
                        await counter.increment()
                        // 模拟一点工作
                        try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
                    }
                }
            }
        }
        #expect(await counter.value == 4)
        #expect(await pool.currentInUse == 0)
        #expect(await pool.waitingCount == 0)
    }

    /// 简单 actor 计数器（避免在 closure 里捕获 inout）
    private actor Counter {
        var value: Int = 0
        func increment() { value += 1 }
    }
}
