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
//  4 个 section：启用 / Whisper 模型 / 翻译服务 / 字幕样式
//  Provider key 走 AIKeychain，其它 toggles 走 Preference。
//  保存 key 时 post .luluk_aiSubtitleConfigChanged 让 PlayerCore 重建 service。
//

import Cocoa

@objcMembers
class PrefAISubtitleViewController: PreferenceViewController, PreferenceWindowEmbeddable {

    // MARK: - PreferenceWindowEmbeddable

    /// 不依赖 nib，loadView 自己建。
    override var nibName: NSNib.Name? { nil }

    var preferenceTabTitle: String {
        return NSLocalizedString("preference.ai_subtitle", comment: "AI 字幕")
    }

    var preferenceTabImage: NSImage {
        return makeSymbol("captions.bubble.fill", fallbackImage: "pref_sub")
    }

    /// 提供给 PreferenceViewController.viewDidLoad 装到 NSStackView。
    override var sectionViews: [NSView] {
        return [enableSection, whisperSection, providerSection, styleSection]
    }

    // MARK: - Section views（loadView 时填）

    private var enableSection: NSView!
    private var whisperSection: NSView!
    private var providerSection: NSView!
    private var styleSection: NSView!

    // MARK: - 控件引用（要在保存/读取时回访）

    private var deepseekKeyField: NSSecureTextField!
    private var providerPopup: NSPopUpButton!
    private var whisperModelPopup: NSPopUpButton!
    private var sourceLangModePopup: NSPopUpButton!
    private var manualSourceLangPopup: NSPopUpButton!
    private var manualSourceLangContainer: NSView!

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
        // 顶层容器：宽 600，高度由 stackView 撑开
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1))
        view = root

        enableSection = makeEnableSection()
        whisperSection = makeWhisperSection()
        providerSection = makeProviderSection()
        styleSection = makeStyleSection()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadStateFromPreferences()
        refreshSourceLangManualVisibility(animated: false)
    }

    // MARK: - 各 Section 构造

    private func makeEnableSection() -> NSView {
        let title = makeSectionTitle("AI 字幕")
        let cb = NSButton(checkboxWithTitle: "启用 AI 字幕（视频打开时自动生成）", target: self, action: #selector(toggleEnabled(_:)))
        cb.state = Preference.bool(for: .aiSubtitleEnabled) ? .on : .off
        let hint = makeHintLabel("仅本地视频文件生效；网络流和无法识别的格式会自动跳过。")
        return verticalStack([title, cb, hint])
    }

    private func makeWhisperSection() -> NSView {
        let title = makeSectionTitle("Whisper 模型")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(whisperModelChanged(_:))
        for (raw, label) in Self.whisperModels {
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = raw
        }
        whisperModelPopup = popup
        let hint = makeHintLabel("V1 内置 turbo / large-v3 / medium-turbo / tiny。模型尚未下载时首次使用会触发自动下载（M5 实装）。")
        return verticalStack([title, popup, hint])
    }

    private func makeProviderSection() -> NSView {
        let title = makeSectionTitle("翻译服务")

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(providerChanged(_:))
        for (raw, label, enabled) in Self.providers {
            popup.addItem(withTitle: label)
            let item = popup.lastItem!
            item.representedObject = raw
            item.isEnabled = enabled
        }
        providerPopup = popup

        // DeepSeek API Key 输入框（M4 唯一可用 provider）
        let keyLabel = makePlainLabel("DeepSeek API Key:")
        let keyField = NSSecureTextField()
        keyField.placeholderString = "sk-..."
        keyField.target = self
        keyField.action = #selector(deepseekKeyCommitted(_:))
        keyField.delegate = self
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        deepseekKeyField = keyField

        let keyRow = horizontalStack([keyLabel, keyField])

        let hint = makeHintLabel("Key 存储在 macOS Keychain 中（不以明文写入设置文件）。失焦或回车时自动保存。其它 provider 在 M5 上线。")

        return verticalStack([title, popup, keyRow, hint])
    }

    private func makeStyleSection() -> NSView {
        let title = makeSectionTitle("字幕样式")

        let bilingualCB = NSButton(checkboxWithTitle: "双语字幕（原文上 译文下）", target: self, action: #selector(toggleBilingual(_:)))
        bilingualCB.state = Preference.bool(for: .aiSubtitleBilingual) ? .on : .off

        let autoReloadCB = NSButton(checkboxWithTitle: "字幕文件变更时自动刷新（实验性）", target: self, action: #selector(toggleAutoReload(_:)))
        autoReloadCB.state = Preference.bool(for: .aiSubtitleAutoReload) ? .on : .off

        // 源语言模式
        let modeLabel = makePlainLabel("识别语种:")
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.target = self
        modePopup.action = #selector(sourceLangModeChanged(_:))
        for (raw, label) in Self.sourceLangModes {
            modePopup.addItem(withTitle: label)
            modePopup.lastItem?.representedObject = raw
        }
        sourceLangModePopup = modePopup
        let modeRow = horizontalStack([modeLabel, modePopup])

        let manualPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        manualPopup.target = self
        manualPopup.action = #selector(manualSourceLangChanged(_:))
        for (raw, label) in Self.manualSourceLangs {
            manualPopup.addItem(withTitle: label)
            manualPopup.lastItem?.representedObject = raw
        }
        manualSourceLangPopup = manualPopup
        let manualRow = horizontalStack([makePlainLabel("源语言:"), manualPopup])
        manualSourceLangContainer = manualRow

        return verticalStack([title, bilingualCB, autoReloadCB, modeRow, manualRow])
    }

    // MARK: - 状态加载（从 Preference / Keychain）

    private func loadStateFromPreferences() {
        // Whisper model
        let currentModel = Preference.string(for: .aiSubtitleWhisperModel) ?? "large-v3-turbo"
        selectPopup(whisperModelPopup, byRepresentedObject: currentModel)

        // Provider
        let currentProvider = Preference.string(for: .aiSubtitleProvider) ?? "deepseek"
        selectPopup(providerPopup, byRepresentedObject: currentProvider)

        // DeepSeek key
        deepseekKeyField.stringValue = AIKeychain.readKey(for: .deepseek) ?? ""

        // Source language mode + manual lang
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
        refreshSourceLangManualVisibility(animated: true)
        postConfigChanged()
    }

    @objc func manualSourceLangChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        Preference.set(raw, for: .aiSubtitleManualSourceLanguage)
        postConfigChanged()
    }

    private func refreshSourceLangManualVisibility(animated: Bool) {
        let isManual = (Preference.string(for: .aiSubtitleSourceLanguageMode) ?? "auto") == "manual"
        manualSourceLangContainer?.isHidden = !isManual
    }

    /// 通知所有 PlayerCore：provider/key/模型 变了，重建 AISubtitleService。
    private func postConfigChanged() {
        NotificationCenter.default.post(name: .lulukAISubtitleConfigChanged, object: nil)
    }

    // MARK: - 小工具：UI 构造 helpers

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }

    private func makePlainLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        return f
    }

    private func makeHintLabel(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 540
        return f
    }

    private func verticalStack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func horizontalStack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
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
