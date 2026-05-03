//
//  AISubtitleProgressViewController.swift
//  luluk
//
//  Created by ayao on 2026/5/3.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕流水线进度面板（M4）。订阅 AISubtitleService.progressStream。
//  程序化构造，无 xib：圆角 dark blur 面板，固定挂在主窗口右上角。
//
//  显示元素（对应 docs/AI_SUBTITLE_DESIGN.md §3.5）：
//    - 当前 provider
//    - 状态文本（切片中 / 转写 N/M / 已完成 / 失败原因）
//    - 首字幕延迟（首段完成后定格）
//    - 累计 tokens（DeepSeek 这类付费 provider）
//    - 失败/降级时的 hint
//
//  生命周期：MainWindowController 持有一个实例，windowDidLoad 时 attach 到 contentView。
//  attach(player:) 时启动订阅 task；detach 时取消。
//

import Cocoa

@MainActor
class AISubtitleProgressViewController: NSViewController {

    // MARK: - Subviews

    private var blurView: NSVisualEffectView!
    private var providerLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var closeButton: NSButton!

    // MARK: - 订阅状态

    private var subscriptionTask: Task<Void, Never>?
    private weak var observedPlayer: PlayerCore?

    // MARK: - 调用入口

    /// 把面板 attach 到指定父 view 的右上角；同时订阅 player.aiSubtitleService.progressStream。
    /// 多次 attach 同一个 player 是幂等的；切换 player 会先 detach 再订阅新的。
    func attach(to parent: NSView, player: PlayerCore) {
        // 父 view 没变 + player 没变 → 幂等
        if view.superview === parent && observedPlayer === player {
            return
        }
        if view.superview !== parent {
            if view.superview != nil {
                view.removeFromSuperview()
            }
            parent.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: parent.topAnchor, constant: 56),
                view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
                view.widthAnchor.constraint(equalToConstant: 280)
            ])
        }
        view.isHidden = true
        observedPlayer = player
        startSubscription(for: player)
    }

    /// 从父 view 移除并取消订阅。MainWindowController.willClose 调。
    func detach() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        observedPlayer = nil
        if view.superview != nil {
            view.removeFromSuperview()
        }
    }

    // MARK: - View 构造

    override func loadView() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        blurView = blur

        providerLabel = NSTextField(labelWithString: "")
        providerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        providerLabel.textColor = .secondaryLabelColor

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 240

        closeButton = NSButton(title: "✕", target: self, action: #selector(closeTapped(_:)))
        closeButton.bezelStyle = .recessed
        closeButton.font = .systemFont(ofSize: 9)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [providerLabel, NSView(), closeButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, statusLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blur.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
        ])

        self.view = blur
    }

    // MARK: - 订阅 progressStream

    private func startSubscription(for player: PlayerCore) {
        subscriptionTask?.cancel()
        // progressStream 是 nonisolated let，直接拿不用 await
        let stream = player.aiSubtitleService.progressStream
        subscriptionTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self = self else { return }
                if Task.isCancelled { return }
                self.applySnapshot(snapshot)
            }
        }
    }

    @MainActor
    private func applySnapshot(_ p: PipelineProgress) {
        providerLabel.stringValue = p.currentProvider.uppercased()
        let (statusText, detailText, hidden) = formatProgress(p)
        statusLabel.stringValue = statusText
        detailLabel.stringValue = detailText
        view.isHidden = hidden
    }

    private func formatProgress(_ p: PipelineProgress) -> (status: String, detail: String, hidden: Bool) {
        switch p.state {
        case .idle:
            return ("", "", true)
        case .splitting:
            return ("正在切片音频...", detailLineForRunning(p), false)
        case .running:
            return (runningTitle(p), detailLineForRunning(p), false)
        case .fallback(let reason):
            return ("已降级：\(reason)", detailLineForRunning(p), false)
        case .completed:
            return ("AI 字幕已完成", finalDetail(p), false)
        case .cancelled:
            return ("已取消", "", true)  // 取消直接隐藏
        case .failed(let err):
            return ("AI 字幕失败", err.shortDescription, false)
        }
    }

    private func runningTitle(_ p: PipelineProgress) -> String {
        let total = p.totalSegments
        let done = p.translatedSegments
        if total > 0 {
            return "翻译中  \(done)/\(total)"
        } else {
            return "翻译中  已完成 \(done) 段"
        }
    }

    private func detailLineForRunning(_ p: PipelineProgress) -> String {
        var parts: [String] = []
        if let first = p.firstSubtitleLatency {
            parts.append(String(format: "首字幕 %.1fs", first))
        }
        if p.tokensUsed > 0 {
            parts.append("\(p.tokensUsed) tokens")
        }
        if let err = p.lastError {
            parts.append("⚠ \(err.shortDescription)")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func finalDetail(_ p: PipelineProgress) -> String {
        var parts: [String] = []
        parts.append("\(p.translatedSegments) 段")
        if let first = p.firstSubtitleLatency {
            parts.append(String(format: "首字幕 %.1fs", first))
        }
        if p.tokensUsed > 0 {
            parts.append("\(p.tokensUsed) tokens")
        }
        return parts.joined(separator: "  ·  ")
    }

    @objc private func closeTapped(_ sender: Any?) {
        view.isHidden = true
    }

    deinit {
        // deinit 已经在 @MainActor 隔离的 ViewController 上，直接取消 task
        subscriptionTask?.cancel()
    }
}

// SubtitleError.shortDescription 已在 SubtitleError.swift 定义，不再重复。
