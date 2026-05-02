# luluk · Fork 第一周操作清单

把 IINA fork 改成 luluk 跑起来的具体步骤。每条都标了文件路径和行号（基于 Apr 30 IINA 版本）。

---

## 阶段 1：开发环境准备（先做）

### 1.1 安装 Xcode
- 去 App Store 装**最新公开版** Xcode（IINA 不支持 beta 版）
- 第一次运行同意许可：`sudo xcodebuild -license`

### 1.2 下载 IINA 预编译依赖
luluk 不需要重新编译 mpv，IINA 提供了预编译 dylib：

```bash
cd /Users/erik/development/luluk
./other/download_libs.sh
```

下完会在 `deps/` 下出现 mpv、ffmpeg 等 dylib。

### 1.3 注册 Apple Developer Program
- 网址：https://developer.apple.com/programs/
- $99/年
- 用于代码签名 + notarization（公证）
- **没这个 macOS 11+ 用户双击 luluk.app 打不开**

---

## 阶段 2:换皮（替换 IINA 痕迹）

> ⚠️ 改完每一节都 build 一次（⌘+B），出错回滚再继续。

### 2.1 Bundle ID 替换（3 处）

**文件**：`Configs/iina.xcconfig` 行 26
```diff
- PRODUCT_BUNDLE_IDENTIFIER = com.colliderli.$(TARGET_NAME)
+ PRODUCT_BUNDLE_IDENTIFIER = xyz.luluk.$(TARGET_NAME)
```

**文件**：`Configs/OpenInIINA.xcconfig` 行 14
```diff
- PRODUCT_BUNDLE_IDENTIFIER = com.colliderli.iina.$(TARGET_NAME)
+ PRODUCT_BUNDLE_IDENTIFIER = xyz.luluk.app.$(TARGET_NAME)
```

**文件**：`iina/Pages/SettingsPageUtilities.swift` 行 292

代码里硬编码了 OpenInIINA 扩展的 Bundle ID（用于 Safari 偏好设置跳转），必须跟着 OpenInIINA.xcconfig 一起改，否则点「Safari 扩展」按钮会打不开。

```diff
  @objc func extSafariBtnAction() {
-   SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.colliderli.iina.OpenInIINA")
+   SFSafariApplication.showPreferencesForExtension(withIdentifier: "xyz.luluk.app.OpenInIINA")
  }
```

> 注：Bundle ID 改后 IINA 和 luluk 可在同一台 Mac 共存，互不冲突。
> 其他文件里的 `com.colliderli.iina.*` 字样（DispatchQueue label、Pasteboard type、Info.plist build 元信息 key、`defaults write` 注释）不是 Bundle ID 引用，**不要在本步替换**——它们改不改不影响 Bundle ID，且部分（如 `defaults write` 命令）涉及用户偏好域迁移，需要在专门的章节统一处理。

### 2.2 Sparkle 更新源

**文件**：`iina/Info.plist` 行 639-644

```diff
  <key>SUFeedURL</key>
- <string>https://www.iina.io/appcast.xml</string>
+ <string>https://luluk.xyz/appcast.xml</string>
  <key>SUPublicDSAKeyFile</key>
  <string>dsa_pub.pem</string>
  <key>SUPublicEDKey</key>
- <string>UpwCRYfYOg0OGgQHY6RUdrV29yPcdkvxGlEfq46r6a0=</string>
+ <string></string>
```

> ⚠️ **没换 SUFeedURL 会被 IINA 的更新覆盖**，用户装的 luluk 会被替换回 IINA！必改。
>
> SUPublicEDKey 必须立即清空——保留 IINA 的旧 EDDSA 公钥意味着 luluk 会信任 IINA 团队签名的更新包，是严重的安全风险（极端情况下用户的 luluk 会被远程替换为 IINA）。改成空字符串后 Sparkle 在没有 SUPublicEDKey 时会跳过 EDDSA 校验，开发期可接受；发版前必须填回我们自己生成的 key。

#### Sparkle 签名密钥（开发期保持现状，发版前补）

**`iina/dsa_pub.pem` 开发期不动**：
- SUFeedURL 已经改成 luluk.xyz/appcast.xml（目前 404），Sparkle 永远拉不到 update，签名校验路径不会触发
- 删空 pem 文件反而可能让 Sparkle 启动时尝试加载报错
- DSA 算法 Sparkle 已弃用，发版时会改用 EDDSA，pem 文件最终会整体替换

**发版前**：
- 用 Sparkle 工具生成新的 EDDSA key 对，把公钥 base64 填回 `SUPublicEDKey`
- DSA 已弃用，建议同时从 Info.plist 删掉 `SUPublicDSAKeyFile` key 并删掉 `iina/dsa_pub.pem` 文件
- 工具：[Sparkle generate_keys](https://sparkle-project.org/documentation/#publishing-an-update)

### 2.3 应用名 / Bundle Display Name

**文件**：`iina/Info.plist`

⚠️ **IINA 的 Info.plist 里没有 `CFBundleName` / `CFBundleDisplayName` key**——应用名实际由 `Configs/iina.xcconfig:27` 的 `PRODUCT_NAME = IINA` 决定。这里采取最小侵入方案：在 Info.plist 里**新增**两个 key 显式覆盖，`PRODUCT_NAME` 保持 `IINA` 不动（`PRODUCT_NAME` 还被 `CODE_SIGN_ENTITLEMENTS = $(TARGET_NAME)/$(PRODUCT_NAME).entitlements` 引用为 `iina/IINA.entitlements` 路径，改了会导致 build 找不到 entitlements 文件）。

按 plist 字母序插入：

- 在 `<dict>` 后、`<key>CFBundleDocumentTypes</key>` 前插入：
  ```xml
  <key>CFBundleDisplayName</key>
  <string>luluk</string>
  ```
- 在 `<key>CFBundleIconFile</key>` 之后、`<key>CFBundleSignature</key>` 之前插入：
  ```xml
  <key>CFBundleName</key>
  <string>luluk</string>
  ```

验证：`plutil -lint iina/Info.plist` 应输出 `OK`。

> 发版前如果想让 binary 名字也改成 `luluk`（影响 .app 内 MacOS/luluk 二进制名 + 默认 prefs domain），需要同步：
> - `Configs/iina.xcconfig:27`：`PRODUCT_NAME = IINA` → `PRODUCT_NAME = luluk`
> - 重命名 `iina/IINA.entitlements` → `iina/luluk.entitlements`
> - 在 .xcodeproj 里更新 IINA.entitlements 的引用
>
> 这是更深的改动，与 §2.3 解耦，留到上线前统一处理。

### 2.4 应用图标

> 前置条件：`assets/logo.png` 应至少 1024×1024（更高更好）。低于此尺寸 `generate_icons.sh` 会要求确认放大，1024 → 256/512 等下采样比放大画质好。当前 luluk 用的是 1254×1254 RGBA。

#### 2.4.1 生成 .icns 和全套 PNG

```bash
./scripts/generate_icons.sh assets/logo.png
```

输出：
- `assets/AppIcon.iconset/` 下 10 个 PNG（16/32/128/256/512 + 各 @2x，对应 16/32/32/64/128/256/256/512/512/1024 像素）
- `assets/AppIcon.icns`（用 `iconutil` 打包的 macOS icon bundle，~1.5MB）

#### 2.4.2 覆盖 Xcode AppIcon 资源

`iina/Assets.xcassets/AppIcon.appiconset/Contents.json` 已经引用了和 generate_icons.sh 输出同名的文件（`icon_16x16.png` ... `icon_512x512@2x.png`），直接 cp 覆盖即可，不需要 Xcode UI 拖拽：

```bash
cp assets/AppIcon.iconset/*.png iina/Assets.xcassets/AppIcon.appiconset/
```

> 如果以后 logo.png 改了，只需要重跑 `generate_icons.sh` + 这条 cp 即可同步。`AppIcon.appiconset` 下的 PNG 都是 generated artifact，可以理解成 build 输入而不是源文件。

### 2.5 Crowdin 翻译配置

V1 先不上多语言 UI，关掉 Crowdin（用 `git mv` 而不是 `mv`，保留 rename history，将来想 revive 时一目了然）：

```bash
git mv crowdin.yml .archive_crowdin.yml
```

V1 上线后再开。代码里 `iina/AppData.swift:56` 的 `crowdinMembersLink` 暂时不动，等 luluk 自己接上 Crowdin 后再统一更新。

### 2.6 替换 IINA 站点引用 + 清理 Safari 扩展迁移列表

> 标题原是「移除/替换 Crash Report endpoint」，IINA 实际上没有 crash report endpoint。本步真正要处理的是：用户可见的 IINA 站点链接，以及 OpenInIINA 扩展的迁移列表。

先扫一遍：

```bash
grep -rn "colliderli\|iina\.io" iina/ OpenInIINA/ --include="*.swift" --include="*.plist"
```

**改这些**（用户可见的 IINA 站点链接）：

| 文件 | 旧值 | 新值 |
|------|------|------|
| `iina/AppData.swift:58` | `websiteLink = "https://iina.io"` | `"https://luluk.xyz"` |
| `iina/AppData.swift:60` | `appcastLink = "https://www.iina.io/appcast.xml"` | `"https://luluk.xyz/appcast.xml"` |
| `iina/AppData.swift:61` | `appcastBetaLink = "https://www.iina.io/appcast-beta.xml"` | `"https://luluk.xyz/appcast-beta.xml"` |
| `iina/GuideWindowController.swift:12` | `highlightsLink = "https://iina.io/highlights"` | `"https://luluk.xyz/highlights"` |
| `iina/GuideWindowController.swift:66` | `starts(with: "https://iina.io/highlights/")` | `"https://luluk.xyz/highlights/"` |

**删除整个 key**：

| 文件 | 删什么 | 为什么 |
|------|--------|--------|
| `OpenInIINA/Info.plist:5-8` | `SFSafariExtensionBundleIdentifiersToUninstall` 整个 key + array | 数组里只有 `com.colliderli.openiniina`（IINA 内部从小写 Bundle ID 迁移到大小写混合时用的迁移钩子）。luluk 是新产品，没有这个迁移路径；保留它会让用户装 luluk 后 Safari 自动卸载 IINA 的旧 OpenInIINA 扩展，干扰 IINA/luluk 共存。 |

**故意保留 IINA 引用**（GPL 致谢或暂未替换的资源）：

- `iina/AppData.swift:55` `contributorsLink = "https://github.com/iina/iina/graphs/contributors"` — IINA 贡献者列表，GPL 致谢的一部分
- `iina/AppData.swift:56` `crowdinMembersLink = "https://crowdin.com/project/iina"` — luluk 自己的 Crowdin 还没建（§2.5），将来一起改
- `iina/AppData.swift:57` `wikiLink = "https://github.com/iina/iina/wiki"` — IINA wiki 对 luluk 用户可能误导，但等 luluk 自己的 wiki 站起来再统一改
- `iina/AppData.swift:63-64` Chrome / Firefox extension link — IINA 自家浏览器扩展，luluk 暂未发布对应扩展

**故意不动的非链接引用**（前几节 commit message 已说明）：

- `*.swift` 里 `DispatchQueue(label: "com.colliderli.iina.*")` — GCD queue 命名约定，不影响 Bundle ID
- `iina/PrefPluginViewController.swift` / `iina/Pages/SettingsPagePlugin.swift` 里 `iinaPluginID = "com.colliderli.iina.pluginID"` — Pasteboard type ID，技术上需要全局唯一但只在 luluk 内部使用
- `iina/Info.plist:1384-1394` `com.colliderli.iina.build.*` keys — 构建元信息 namespace，改了要同步改读取这些 key 的代码（专门一步处理）
- `iina/AppDelegate.swift` / `iina/Preference.swift` 里 `defaults write com.colliderli.iina ...` 注释 — 文档注释，不影响 build；luluk prefs domain 已经跟随新 Bundle ID 自动变成 `xyz.luluk.iina`，这些注释将来更新文档时一起改

**OpenInIINA Safari 扩展自身的 IINA 字面**（CFBundleDisplayName / SFSafariContextMenu Text / `open-in-iina.js` 文件名 / Command 标识符等）也没在本步处理——它们涉及文件重命名 + Swift 代码同步，单独作为一个章节处理。

### 2.7 About 窗口致谢保留 IINA

**两个 rtf 文件各自承担不同的 license 义务，都不能删。**

| 文件 | 实际内容 | 为什么不能删 |
|------|---------|-------------|
| `iina/Credits.rtf` | 依赖项 license 致谢（libmpv / FFmpeg / Just / PromiseKit / GRMustache 等），逐个粘贴了原始 license 文本 | 这些第三方库的 BSD / MIT / LGPL license 都要求保留版权声明和 license 文本，**和 IINA / luluk 无关、是依赖本身的法律要求** |
| `iina/Contribution.rtf` | IINA 项目说明 + GPL-3 声明 + `Copyright © 2017-2026 Collider LI, et al.` | **GPL-3 §5(a) 要求衍生作品保留原作者版权声明**。luluk 是 IINA 的衍生作品，这个文件就是法律上必须保留的"原作者署名" |

**验证**（不改文件，只确认）：

```bash
# Credits.rtf 应包含 mpv / FFmpeg 等依赖 license
textutil -convert txt -stdout iina/Credits.rtf | grep -E "(libmpv|FFmpeg)"

# Contribution.rtf 应包含 IINA 团队署名 + GPL 声明
textutil -convert txt -stdout iina/Contribution.rtf | grep -E "(Collider LI|GNU General Public License)"
```

**luluk 自己的版权信息**：建议将来在 luluk 自己写的 About 页（不是改 IINA 这两个 rtf）或 README 里加一句「luluk 基于 IINA 二次开发，遵循 GPL-3.0 协议；原 IINA 项目版权属于 Collider LI 等贡献者」。这是补充性的，不是 GPL 强制；强制部分（保留 Contribution.rtf）已通过"不动这两个 rtf"满足。

**不改 rtf 的原因**：RTF 是富文本格式，用编辑器（含 Edit/Write 工具）按字符改会破坏格式标记。如果将来需要修改这些文件，请用 macOS TextEdit 打开。

---

## 阶段 3：第一次 Build & Run

```bash
cd /Users/erik/development/luluk
open iina.xcodeproj
```

在 Xcode 里：
1. Scheme 选 `iina`（fork 后这个 target 名暂时不动，避免改 build settings）
2. ⌘+R run
3. 应该能看到一个**绿色图标 + luluk 名字**的 macOS 应用打开（如果还看到 IINA 的痕迹，回去 §2.x 再核对）

### 验证清单
- [ ] Dock 图标是绿色 luluk logo
- [ ] 应用名「luluk」（不是 IINA）
- [ ] About 窗口标题「luluk」
- [ ] About 窗口致谢仍然保留 IINA 团队（GPL 要求）
- [ ] 不会触发"软件更新"对话框（避免被 IINA appcast 拉走）

---

## 阶段 4：AI 字幕模块代码骨架（占位）

> 等 §1-3 跑通后做。具体每个文件要写什么，看 [SPEC.md §5](SPEC.md#5-技术架构)。

### 4.1 创建目录结构

```bash
cd /Users/erik/development/luluk/iina
mkdir -p AISubtitle/Providers
```

### 4.2 创建空 Swift 文件（先不实现，让 Xcode 加进 target）

```
iina/
├── AISubtitleService.swift                  ← 主调度
├── AISubtitle/
│   ├── AudioSplitter.swift
│   ├── WhisperRunner.swift
│   ├── Sanitizer.swift
│   ├── SRTMerger.swift
│   ├── TranslationProvider.swift            ← protocol
│   └── Providers/
│       ├── DeepSeekProvider.swift
│       ├── MiniMaxProvider.swift
│       ├── OpenAIProvider.swift
│       ├── CustomProvider.swift
│       ├── LulukCloudProvider.swift
│       └── NLLBLocalProvider.swift
├── SubtitleFileWatcher.swift
├── AISubtitlePrefViewController.swift       ← Provider 选择 UI
├── LulukCloudAuth.swift
└── ModelDownloader.swift
```

每个文件先填一个空类即可：

```swift
//
//  AISubtitleService.swift
//  luluk
//
//  Created by <you> on 2026/05/02.
//

import Foundation

class AISubtitleService {
    // TODO: 移植 ai-subtitle-prototype/produce.py 的流水线逻辑
}
```

### 4.3 在 Xcode 把这些文件加入 `iina` target

Xcode 左侧 Project Navigator 右键 `iina` 文件夹 → Add Files → 选刚创建的 .swift 文件 → 确认 target = iina。

### 4.4 第一个能跑的"端到端骨架"
按 SPEC §12 的难度排序，建议依次实现：
1. **Sanitizer.swift**（纯字符串处理，最容易，原型 sanitize.py 直接翻 Swift）
2. **SRTMerger.swift**（SRT 解析 + 偏移合并）
3. **AudioSplitter.swift**（spawn ffmpeg 解析 stderr）
4. **WhisperRunner.swift**（spawn whisper-cli + 并发 + on_done）
5. **TranslationProvider + DeepSeekProvider**（URLSession + JSON）
6. **AISubtitleService.swift**（用前 5 个组件实现流水线）
7. **NLLBLocalProvider**（Python helper 子进程）
8. **SubtitleFileWatcher**（FSEventStream + mpv sub-reload）
9. **AISubtitlePrefViewController**（设置 UI）

---

## 阶段 5：发布准备（V1 上线前）

### 5.1 代码签名
- Xcode → Signing & Capabilities → Team 选你的 Apple Developer
- Provisioning 自动管理

### 5.2 公证（Notarization）
```bash
xcrun notarytool submit luluk.app.zip \
    --apple-id "你的 AppleID" \
    --team-id "Team ID" \
    --password "App-specific Password" \
    --wait
```

成功后 `xcrun stapler staple luluk.app` 把公证 ticket 装订到 .app。

### 5.3 Sparkle 签名密钥
按 §2.2 末尾的指引生成正式密钥并填回 `Info.plist`。

### 5.4 GitHub Release
- 创建 ayaoplus/luluk 仓库（GPL-3）
- Push 全部源码（**第一次 push 即开源**）
- Release 上传 `luluk.app.zip` + `appcast.xml`

### 5.5 部署 luluk.xyz
- 主站：静态页 + 下载链接
- appcast.xml：Sparkle 更新清单
- DNS：luluk.xyz / api.luluk.xyz / dashboard.luluk.xyz

---

## 已知坑

| 坑 | 解决 |
|----|------|
| 第一次 build 慢（5-10 分钟）| 正常，Xcode 索引完整个 IINA 后续 build 快 |
| `code signature could not be verified` | Team 没选对，去 Signing & Capabilities 重选 |
| 双击 luluk.app 提示"已损坏" | 还没公证。开发期：右键→打开 → 信任 |
| Sparkle 弹"无法验证开发者" | Info.plist 里 SUPublicEDKey 是空的，开发期可禁 Sparkle 检查 |
| GPL fork 是否要 Apple 注册公司 | 不需要，个人 Apple Developer 账户就行 |

---

## 当前进度

- [x] 项目目录已创建（`/Users/erik/development/luluk/`）
- [x] IINA 源码已 copy
- [x] luluk README + SPEC + Logo 就位
- [x] 此清单已生成
- [ ] **下一步**：跟着此清单从 §1.1 开始
