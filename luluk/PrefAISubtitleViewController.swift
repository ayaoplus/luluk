//
//  PrefAISubtitleViewController.swift
//  luluk
//
//  Created by ayao on 2026/5/3.
//  Copyright © 2026 ayao. All rights reserved.
//
//  AI 字幕设置面板（M4）。程序化构造，无 xib。
//  对应 docs/AI_SUBTITLE_DESIGN.md §3.4。
//
//  布局策略：跳过 PreferenceViewController.sectionViews 机制（嵌套 NSStackView
//  跟父类的 .fill distribution 算不齐高度，会出现子视图压成 0 高度的诡异情况）。
//  自己在 loadView 里直接拼一个顶层垂直 NSStackView，所有控件都是它的 arranged
//  subview，section 之间用 NSBox.horizontalLine 分隔。
//
//  Provider key 走 AIKeychain，其它 toggles 走 Preference。
//  保存 key 时 post .lulukAISubtitleConfigChanged 让 PlayerCore 重建 service。
//

import Cocoa

@objcMembers
class PrefAISubtitleViewController: NSViewController, PreferenceWindowEmbeddable {

    // MARK: - PreferenceWindowEmbeddable

    /// 不依赖 nib，loadView 自己建。
    override var nibName: NSNib.Name? { nil }

    var preferenceTabTitle: String {
        return NSLocalizedString("preference.ai_subtitle", comment: "AI 字幕")
    }

    var preferenceTabImage: NSImage {
        guard #available(macOS 14, *) else { return NSImage(named: "pref_sub")! }
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        return NSImage.findSFSymbol(["captions.bubble.fill", "captions.bubble"], withConfiguration: cfg)
    }

    var preferenceContentIsScrollable: Bool { true }

    // MARK: - 控件引用（要在保存/读取时回访）

    private var deepseekKeyField: NSSecureTextField!
    private var providerPopup: NSPopUpButton!
    private var whisperModelPopup: NSPopUpButton!
    private var sourceLangModePopup: NSPopUpButton!
    private var manualSourceLangPopup: NSPopUpButton!
    /// 整行（label + popup），mode=auto 时整行隐藏（NSStackView 会自动收回空间）。
    private var manualSourceLangRow: NSStackView!

    // MARK: - 静态选项表

    /// (rawValue, 显示名)，rawValue 写入 Preference.aiSubtitleWhisperModel。
    private static let whisperModels: [(String, String)] = [
        ("large-v3-turbo", "large-v3-turbo（推荐 · 实时 10×）"),
        ("large-v3",       "large-v3（高质量 · 较慢）"),
        ("medium-turbo",   "medium-turbo（弱机降级）"),
        ("tiny",           "tiny（极弱机）")
    ]

    /// (rawValue, 显示名, M4 是否可用)。M4 只 DeepSeek 可用，其它 M5 接。
    private static let providers: [(String, String, Bool)] = [
        ("deepseek",   "DeepSeek（自带 Key · 推荐）", true),
        ("lulukCloud", "luluk Cloud（M5 即将上线）", false),
        ("minimax",    "MiniMax（M5 即将上线）", false),
        ("openai",     "OpenAI（M5 即将上线）", false),
        ("custom",     "自定义 Endpoint（M5 即将上线）", false),
        ("nllbLocal",  "本地 NLLB（M5 即将上线）", false)
    ]

    private static let sourceLangModes: [(String, String)] = [
        ("auto",   "自动检测"),
        ("manual", "手动指定")
    ]

    /// SPEC §V1 锁定的 5 语对。
    private static let manualSourceLangs: [(String, String)] = [
        ("en", "英语 (English)"),
        ("ja", "日语 (日本語)"),
        ("ko", "韩语 (한국어)"),
        ("ru", "俄语 (Русский)"),
        ("es", "西班牙语 (Español)")
    ]

    // MARK: - View 构造

    override func loadView() {
        // 顶层容器：必须关掉 autoresizing → constraints 翻译，否则 frame.height=1
        // 会被翻成硬约束 height==1，跟内层 stack 的 top+16/bottom-16 冲突，
        // AutoLayout 强行打破后 subview 全压成 0 高度（之前 UI 错位的根因）。
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 顶层垂直 NSStackView：所有控件 + section 分隔线全部 flatten 进来
        let stack = NSStackView(views: buildAllSubviews())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        // bottom 用等式（不是 <=），让 self.view 的高度跟着 stack 撑起来；
        // PreferenceWindowController 会把 view 装进可滚 scrollView，
        // preferenceContentIsScrollable=true 时高度可以超出可视区。
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])

        loadStateFromPreferences()
        refreshSourceLangManualVisibility()
    }

    /// 从顶到底依次组装所有控件。每个"section"=标题 + 一组控件 + （可选）hint，
    /// section 之间用 horizontalLine + 上下 padding 隔开。
    private func buildAllSubviews() -> [NSView] {
        var rows: [NSView] = []

        // ─── Section 1: AI 字幕开关 ───
        rows.append(sectionTitle("AI 字幕"))
        let enableCB = checkbox(title: "启用 AI 字幕（视频打开时自动生成）",
                                key: .aiSubtitleEnabled,
                                action: #selector(toggleEnabled(_:)))
        rows.append(enableCB)
        rows.append(hintLabel("仅本地视频文件生效；网络流和无法识别的格式会自动跳过。"))

        rows.append(sectionDivider())

        // ─── Section 2: Whisper 模型 ───
        rows.append(sectionTitle("Whisper 模型"))
        whisperModelPopup = makePopup(items: Self.whisperModels,
                                      action: #selector(whisperModelChanged(_:)))
        rows.append(whisperModelPopup)
        rows.append(hintLabel("V1 内置 turbo / large-v3 / medium-turbo / tiny。模型尚未下载时首次使用会触发自动下载（M5 实装）。"))

        rows.append(sectionDivider())

        // ─── Section 3: 翻译服务 ───
        rows.append(sectionTitle("翻译服务"))
        let providerItems = Self.providers.map { ($0.0, $0.1) }
        providerPopup = makePopup(items: providerItems, action: #selector(providerChanged(_:)))
        // 给非 DeepSeek 的项打灰
        for (i, (_, _, enabled)) in Self.providers.enumerated() {
            providerPopup.item(at: i)?.isEnabled = enabled
        }
        rows.append(providerPopup)

        // DeepSeek API Key 输入行
        rows.append(makeKeyRow())
        rows.append(hintLabel("Key 存储在 macOS Keychain 中（不以明文写入设置文件）。失焦或回车时自动保存。其它 provider 在 M5 上线。"))

        rows.append(sectionDivider())

        // ─── Section 4: 字幕样式 ───
        rows.append(sectionTitle("字幕样式"))
        rows.append(checkbox(title: "双语字幕（原文上 译文下）",
                             key: .aiSubtitleBilingual,
                             action: #selector(toggleBilingual(_:))))
        rows.append(checkbox(title: "字幕文件变更时自动刷新（实验性）",
                             key: .aiSubtitleAutoReload,
                             action: #selector(toggleAutoReload(_:))))

        // 识别语种模式行
        sourceLangModePopup = makePopup(items: Self.sourceLangModes,
                                        action: #selector(sourceLangModeChanged(_:)))
        rows.append(labeledRow("识别语种:", control: sourceLangModePopup))

        // 手动语种行（mode=manual 时可见）
        manualSourceLangPopup = makePopup(items: Self.manualSourceLangs,
                                          action: #selector(manualSourceLangChanged(_:)))
        manualSourceLangRow = labeledRow("源语言:", control: manualSourceLangPopup)
        rows.append(manualSourceLangRow)

        return rows
    }

    // MARK: - 子视图工厂

    private func sectionTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func sectionDivider() -> NSView {
        // NSBox 风格的细分隔线 + 上下额外 padding（用 spacer 包一层避免 NSStackView 把分隔线压扁）
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            line.heightAnchor.constraint(equalToConstant: 1),
            // 整体显式高度，不让 NSStackView 算错
            container.heightAnchor.constraint(equalToConstant: 13)
        ])
        return container
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        // 这一行的最大宽度让 Auto Layout 算出来；只给一个 hugging 提示
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    private func checkbox(title: String, key: Preference.Key, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = Preference.bool(for: key) ? .on : .off
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func makePopup(items: [(String, String)], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
        for (raw, label) in items {
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = raw
        }
        return popup
    }

    /// 生成 "label: control" 一行；用 NSStackView 水平排，整行作为顶层 stack 的 arranged subview。
    private func labeledRow(_ label: String, control: NSView) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeKeyRow() -> NSStackView {
        let lbl = NSTextField(labelWithString: "DeepSeek API Key:")
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let field = NSSecureTextField()
        field.placeholderString = "sk-..."
        field.target = self
        field.action = #selector(deepseekKeyCommitted(_:))
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        deepseekKeyField = field

        let row = NSStackView(views: [lbl, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - 状态加载（从 Preference / Keychain）

    private func loadStateFromPreferences() {
        let currentModel = Preference.string(for: .aiSubtitleWhisperModel) ?? "large-v3-turbo"
        selectPopup(whisperModelPopup, byRepresentedObject: currentModel)

        let currentProvider = Preference.string(for: .aiSubtitleProvider) ?? "deepseek"
        selectPopup(providerPopup, byRepresentedObject: currentProvider)

        deepseekKeyField.stringValue = AIKeychain.readKey(for: .deepseek) ?? ""

        let mode = Preference.string(for: .aiSubtitleSourceLanguageMode) ?? "auto"
        selectPopup(sourceLangModePopup, byRepresentedObject: mode)

        let manualLang = Preference.string(for: .aiSubtitleManualSourceLanguage) ?? "ja"
        selectPopup(manualSourceLangPopup, byRepresentedObject: manualLang)
    }

    private func selectPopup(_ popup: NSPopUpButton, byRepresentedObject value: String) {
        if let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    // MARK: - Actions

    @objc func toggleEnabled(_ sender: NSButton) {
        Preference.set(sender.state == .on, for: .aiSubtitleEnabled)
    }

    @objc func toggleBilingual(_ sender: NSButton) {
        Preference.set(sender.state == .on, for: .aiSubtitleBilingual)
    }

    @objc func toggleAutoReload(_ sender: NSButton) {
        Preference.set(sender.state == .on, for: .aiSubtitleAutoReload)
    }

    @objc func whisperModelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        Preference.set(raw, for: .aiSubtitleWhisperModel)
        postConfigChanged()
    }

    @objc func providerChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let raw = item.representedObject as? String else { return }
        // M5 之前只允许选 deepseek；其它项弹提示并回滚
        if raw != "deepseek" {
            showFreeFormAlert(text: "该翻译服务将在 M5 上线，目前仅支持 DeepSeek。", style: .informational)
            selectPopup(sender, byRepresentedObject: Preference.string(for: .aiSubtitleProvider) ?? "deepseek")
            return
        }
        Preference.set(raw, for: .aiSubtitleProvider)
        postConfigChanged()
    }

    @objc func deepseekKeyCommitted(_ sender: NSSecureTextField) {
        saveDeepSeekKey(sender.stringValue)
    }

    private func saveDeepSeekKey(_ value: String) {
        do {
            try AIKeychain.writeKey(value, for: .deepseek)
            postConfigChanged()
        } catch {
            showFreeFormAlert(text: "保存 DeepSeek Key 失败：\(error.localizedDescription)", style: .warning)
        }
    }

    /// Utility.showAlert 只接受 localization key；这里需要带变量的自由文本，自己构造 NSAlert。
    private func showFreeFormAlert(text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        switch style {
        case .critical:
            alert.messageText = NSLocalizedString("alert.title_error", comment: "Error")
        case .informational:
            alert.messageText = NSLocalizedString("alert.title_info", comment: "Information")
        case .warning:
            alert.messageText = NSLocalizedString("alert.title_warning", comment: "Warning")
        @unknown default:
            alert.messageText = "luluk"
        }
        alert.informativeText = text
        if let w = view.window {
            alert.beginSheetModal(for: w)
        } else {
            alert.runModal()
        }
    }

    @objc func sourceLangModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        Preference.set(raw, for: .aiSubtitleSourceLanguageMode)
        refreshSourceLangManualVisibility()
        postConfigChanged()
    }

    @objc func manualSourceLangChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        Preference.set(raw, for: .aiSubtitleManualSourceLanguage)
        postConfigChanged()
    }

    private func refreshSourceLangManualVisibility() {
        let isManual = (Preference.string(for: .aiSubtitleSourceLanguageMode) ?? "auto") == "manual"
        manualSourceLangRow?.isHidden = !isManual
    }

    /// 通知所有 PlayerCore：provider/key/模型 变了，重建 AISubtitleService。
    private func postConfigChanged() {
        NotificationCenter.default.post(name: .lulukAISubtitleConfigChanged, object: nil)
    }
}

// MARK: - NSTextFieldDelegate（失焦也保存 key，不只回车）

extension PrefAISubtitleViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSSecureTextField, f === deepseekKeyField else { return }
        saveDeepSeekKey(f.stringValue)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// 设置面板修改了 AI 字幕配置（provider / key / 模型）。PlayerCore 监听并重建 service。
    static let lulukAISubtitleConfigChanged = Notification.Name("lulukAISubtitleConfigChanged")
}
