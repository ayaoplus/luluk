//
//  SubtitleFileWatcher.swift
//  luluk
//
//  Created by ayao on 2026/5/3.
//  Copyright © 2026 ayao. All rights reserved.
//
//  监听一个 .srt 文件，文件出现/修改时通知 PlayerCore 加载或刷新字幕。
//  对应 docs/AI_SUBTITLE_DESIGN.md §3.3 + SPEC §11 "字幕文件变更时自动刷新"。
//
//  实现方式：500ms 轮询 mtime。
//   - 简单可靠（不依赖 FSEventStream + atomic rename 边界）
//   - CPU 0%（FileManager.attributesOfItem 调用 < 1ms）
//   - 文件 atomic rename 期间瞬时 unavailable 也能下一轮恢复
//   - M5 / V2 真在意延迟可换 FSEventStream
//

import Foundation

actor SubtitleFileWatcher {

    /// PlayerCore 的 weak 引用。watcher 不延长 player 生命周期。
    private weak var player: PlayerCore?

    /// 被监听的 SRT 文件 URL。
    let url: URL

    /// 轮询间隔。SPEC § "debounce 250ms" 是触发频率上限；
    /// 我们用 500ms 轮询 = 实际通知延迟 250ms 平均、500ms 最差。
    let pollInterval: TimeInterval

    private var task: Task<Void, Never>?

    /// 记住上一次见到的 mtime；初次为 nil 时视作"还没出现"。
    /// 文件第一次出现时 mtime 从 nil → 某个 Date，触发首次 loadExternalSubFile（IINA 内部走 sub-add）。
    private var lastMtime: Date?

    init(player: PlayerCore?, url: URL, pollInterval: TimeInterval = 0.5) {
        self.player = player
        self.url = url
        self.pollInterval = pollInterval
    }

    /// 启动轮询。重复调用先停老的再开新的。
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.runLoop()
        }
        NSLog("%@", "[luluk-ai/watcher] started polling \(url.path) every \(pollInterval)s")
    }

    /// 停止轮询。stop 不 await loop 退出（Task.cancel 会让 sleep 抛 CancellationError）。
    func stop() {
        task?.cancel()
        task = nil
        NSLog("%@", "[luluk-ai/watcher] stopped polling \(url.path)")
    }

    // MARK: - 轮询主体

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                return  // cancelled
            }
            await checkOnce()
        }
    }

    /// 单次检查：mtime 变了 → MainActor 上调 loadExternalSubFile。
    /// loadExternalSubFile (PlayerCore.swift:1437) 内部判断：
    ///   - subTracks 已含此 URL → mpv sub-reload
    ///   - 未加载过 → mpv sub-add
    /// 所以 watcher 不需要区分首次和后续。
    private func checkOnce() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            // atomic rename 期间瞬时拿不到属性，下一轮再试
            return
        }
        if let last = lastMtime, last == mtime {
            return  // 没变化
        }
        let firstSighting = (lastMtime == nil)
        lastMtime = mtime

        let target = url
        let p = player
        await MainActor.run {
            p?.loadExternalSubFile(target)
        }
        NSLog("%@", "[luluk-ai/watcher] \(firstSighting ? "first sighting → sub-add" : "mtime changed → sub-reload"): \(target.path)")
    }
}
