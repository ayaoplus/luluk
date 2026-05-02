# luluk · Fork 第一周操作清单

把 IINA fork 改成 luluk 跑起来的具体步骤。每条都标了文件路径和行号（基于 Apr 30 IINA 版本）。

---

## 阶段 1：开发环境准备（先做）

### 1.1 安装 Xcode
- 去 App Store 装**最新公开版** Xcode（IINA 不支持 beta 版）
- 第一次运行同意许可：`sudo xcodebuild -license`

### 1.2 下载 IINA 预编译依赖

luluk 不需要重新编译 mpv——IINA 在 `https://iina.io/dylibs/universal/` 上提供了预编译 dylib（mpv / FFmpeg / 其他）。脚本同时下载 yt-dlp + 三个 IINA 官方插件（plugin-online-media / plugin-userscript / plugin-opensub）。

> ⚠️ 跑之前必须先修一处：`other/download_libs.sh:3` 的 `PROJECT_NAME='iina'` 必须改成 `PROJECT_NAME='luluk'`。脚本通过往上爬目录树找名字等于 `PROJECT_NAME` 的目录来定位项目根，luluk 根目录叫 `luluk` 不叫 `iina`，原值会让脚本一路爬到 `/` 然后报错 "Unable to find the root directory 'iina'" 立即退出。

```bash
./other/download_libs.sh
```

输出到 `deps/`：
- `deps/lib/`：mpv、ffmpeg、yt-dlp 等 dylib（~150MB）
- `deps/executable/youtube-dl`：实际是 yt-dlp，IINA 兼容命名
- `deps/plugins/iina-plugin-{ytdl,userscript,opensub}-*.iinaplgz`：三个官方插件

总下载量约 150-200MB，视网速 1-3 分钟。

> 长期风险：依赖 `iina.io` 的服务器分发预编译库——如果 IINA 项目以后下线或断开，luluk 必须自己 build mpv。这是 V2+ 才需要解决的问题，V1 接受这个外部依赖。
>
> luluk 跟 `plugin-opensub`（在线字幕搜索）功能上重叠，但 V1 先装上让 build 跑通；做 AI 字幕模块时再决定是否在 UI 隐藏。

### 1.3 注册 Apple Developer Program
- 网址：https://developer.apple.com/programs/
- $99/年
- 用于代码签名 + notarization（公证）
- **没这个 macOS 11+ 用户双击 luluk.app 打不开**

---

## 阶段 2:换皮（替换 IINA 痕迹）

> ⚠️ 改完每一节都 build 一次（⌘+B），出错回滚再继续。

### 2.1 Bundle ID 替换（3 处）

> ⚠️ **关键约束**：Xcode 强制要求 embedded binary 的 Bundle ID 必须以 parent app Bundle ID 为前缀。OpenInIINA 是 iina target 的 Safari 扩展（embedded binary），所以**两者的 Bundle ID 必须共享前缀**。原 IINA 用 `com.colliderli.iina` + `com.colliderli.iina.OpenInIINA`（前者是后者的前缀）。luluk 必须保持同样的结构。
>
> 按 SPEC §11 决策清单，main app Bundle ID = `xyz.luluk.app`。所以 OpenInIINA 必须是 `xyz.luluk.app.<TARGET_NAME>` = `xyz.luluk.app.OpenInIINA`。**main app 不能用 `xyz.luluk.$(TARGET_NAME)`（展开成 `xyz.luluk.iina`）**——那样 OpenInIINA 的 `xyz.luluk.app.*` 不再是它的前缀，build 会报 "Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier."

**文件**：`Configs/iina.xcconfig` 行 26

main app 的 Bundle ID 写死，**不展开 `$(TARGET_NAME)`**——SPEC §11 的决策值就是 `xyz.luluk.app`，跟 target 名 `iina` 解耦。

```diff
- PRODUCT_BUNDLE_IDENTIFIER = com.colliderli.$(TARGET_NAME)
+ PRODUCT_BUNDLE_IDENTIFIER = xyz.luluk.app
```

**文件**：`Configs/OpenInIINA.xcconfig` 行 14
```diff
- PRODUCT_BUNDLE_IDENTIFIER = com.colliderli.iina.$(TARGET_NAME)
+ PRODUCT_BUNDLE_IDENTIFIER = xyz.luluk.app.$(TARGET_NAME)
```

**文件**：`luluk/Pages/SettingsPageUtilities.swift` 行 292

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

**文件**：`luluk/Info.plist` 行 639-644

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

**`luluk/dsa_pub.pem` 开发期不动**：
- SUFeedURL 已经改成 luluk.xyz/appcast.xml（目前 404），Sparkle 永远拉不到 update，签名校验路径不会触发
- 删空 pem 文件反而可能让 Sparkle 启动时尝试加载报错
- DSA 算法 Sparkle 已弃用，发版时会改用 EDDSA，pem 文件最终会整体替换

**发版前**：
- 用 Sparkle 工具生成新的 EDDSA key 对，把公钥 base64 填回 `SUPublicEDKey`
- DSA 已弃用，建议同时从 Info.plist 删掉 `SUPublicDSAKeyFile` key 并删掉 `luluk/dsa_pub.pem` 文件
- 工具：[Sparkle generate_keys](https://sparkle-project.org/documentation/#publishing-an-update)

### 2.3 应用名 / Bundle Display Name

**文件**：`luluk/Info.plist`

⚠️ **IINA 的 Info.plist 里没有 `CFBundleName` / `CFBundleDisplayName` key**——应用名实际由 `Configs/iina.xcconfig:27` 的 `PRODUCT_NAME` 决定（IINA 原值是 `IINA`，已改为 `luluk`）。本步采取最小侵入方案：在 Info.plist 里**新增**两个 key 显式覆盖，跟 `PRODUCT_NAME` 解耦。

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

验证：`plutil -lint luluk/Info.plist` 应输出 `OK`。

> **后续追加（已完成）**：批 1（commit `ede6304`）已经把 `PRODUCT_NAME` 从 `IINA` 改成了 `luluk`，并把 `iina/IINA.entitlements` → `iina/luluk.entitlements`、同步更新了 .xcodeproj 引用。批 2（commit `d208ebd`）进一步把 `iina/` 目录整体 rename 成 `luluk/`，所以现在 entitlements 路径是 `luluk/luluk.entitlements`。本节加的 `CFBundleDisplayName` / `CFBundleName` 跟 `PRODUCT_NAME` 现在都是 `luluk`，结果一致。

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

`luluk/Assets.xcassets/AppIcon.appiconset/Contents.json` 已经引用了和 generate_icons.sh 输出同名的文件（`icon_16x16.png` ... `icon_512x512@2x.png`），直接 cp 覆盖即可，不需要 Xcode UI 拖拽：

```bash
cp assets/AppIcon.iconset/*.png luluk/Assets.xcassets/AppIcon.appiconset/
```

> 如果以后 logo.png 改了，只需要重跑 `generate_icons.sh` + 这条 cp 即可同步。`AppIcon.appiconset` 下的 PNG 都是 generated artifact，可以理解成 build 输入而不是源文件。

### 2.5 Crowdin 翻译配置

V1 先不上多语言 UI，关掉 Crowdin（用 `git mv` 而不是 `mv`，保留 rename history，将来想 revive 时一目了然）：

```bash
git mv crowdin.yml .archive_crowdin.yml
```

V1 上线后再开。代码里 `luluk/AppData.swift:56` 的 `crowdinMembersLink` 暂时不动，等 luluk 自己接上 Crowdin 后再统一更新。

### 2.6 替换 IINA 站点引用 + 清理 Safari 扩展迁移列表

> 标题原是「移除/替换 Crash Report endpoint」，IINA 实际上没有 crash report endpoint。本步真正要处理的是：用户可见的 IINA 站点链接，以及 OpenInIINA 扩展的迁移列表。

先扫一遍：

```bash
grep -rn "colliderli\|iina\.io" luluk/ OpenInIINA/ --include="*.swift" --include="*.plist"
```

**改这些**（用户可见的 IINA 站点链接）：

| 文件 | 旧值 | 新值 |
|------|------|------|
| `luluk/AppData.swift:58` | `websiteLink = "https://iina.io"` | `"https://luluk.xyz"` |
| `luluk/AppData.swift:60` | `appcastLink = "https://www.iina.io/appcast.xml"` | `"https://luluk.xyz/appcast.xml"` |
| `luluk/AppData.swift:61` | `appcastBetaLink = "https://www.iina.io/appcast-beta.xml"` | `"https://luluk.xyz/appcast-beta.xml"` |
| `luluk/GuideWindowController.swift:12` | `highlightsLink = "https://iina.io/highlights"` | `"https://luluk.xyz/highlights"` |
| `luluk/GuideWindowController.swift:66` | `starts(with: "https://iina.io/highlights/")` | `"https://luluk.xyz/highlights/"` |

**删除整个 key**：

| 文件 | 删什么 | 为什么 |
|------|--------|--------|
| `OpenInIINA/Info.plist:5-8` | `SFSafariExtensionBundleIdentifiersToUninstall` 整个 key + array | 数组里只有 `com.colliderli.openiniina`（IINA 内部从小写 Bundle ID 迁移到大小写混合时用的迁移钩子）。luluk 是新产品，没有这个迁移路径；保留它会让用户装 luluk 后 Safari 自动卸载 IINA 的旧 OpenInIINA 扩展，干扰 IINA/luluk 共存。 |

**故意保留 IINA 引用**（GPL 致谢或暂未替换的资源）：

- `luluk/AppData.swift:55` `contributorsLink = "https://github.com/iina/iina/graphs/contributors"` — IINA 贡献者列表，GPL 致谢的一部分
- `luluk/AppData.swift:56` `crowdinMembersLink = "https://crowdin.com/project/iina"` — luluk 自己的 Crowdin 还没建（§2.5），将来一起改
- `luluk/AppData.swift:57` `wikiLink = "https://github.com/iina/iina/wiki"` — IINA wiki 对 luluk 用户可能误导，但等 luluk 自己的 wiki 站起来再统一改
- `luluk/AppData.swift:63-64` Chrome / Firefox extension link — IINA 自家浏览器扩展，luluk 暂未发布对应扩展

**故意不动的非链接引用**（前几节 commit message 已说明）：

- `*.swift` 里 `DispatchQueue(label: "com.colliderli.iina.*")` — GCD queue 命名约定，不影响 Bundle ID
- `luluk/PrefPluginViewController.swift` / `luluk/Pages/SettingsPagePlugin.swift` 里 `iinaPluginID = "com.colliderli.iina.pluginID"` — Pasteboard type ID，技术上需要全局唯一但只在 luluk 内部使用
- `luluk/Info.plist:1384-1394` `com.colliderli.iina.build.*` keys — 构建元信息 namespace，改了要同步改读取这些 key 的代码（专门一步处理）
- `luluk/AppDelegate.swift` / `luluk/Preference.swift` 里 `defaults write com.colliderli.iina ...` 注释 — 文档注释，不影响 build；luluk prefs domain 已经跟随新 Bundle ID 自动变成 `xyz.luluk.iina`，这些注释将来更新文档时一起改

**OpenInIINA Safari 扩展自身的 IINA 字面**（CFBundleDisplayName / SFSafariContextMenu Text / `open-in-iina.js` 文件名 / Command 标识符等）也没在本步处理——它们涉及文件重命名 + Swift 代码同步，单独作为一个章节处理。

### 2.7 About 窗口致谢保留 IINA

**两个 rtf 文件各自承担不同的 license 义务，都不能删。**

| 文件 | 实际内容 | 为什么不能删 |
|------|---------|-------------|
| `luluk/Credits.rtf` | 依赖项 license 致谢（libmpv / FFmpeg / Just / PromiseKit / GRMustache 等），逐个粘贴了原始 license 文本 | 这些第三方库的 BSD / MIT / LGPL license 都要求保留版权声明和 license 文本，**和 IINA / luluk 无关、是依赖本身的法律要求** |
| `luluk/Contribution.rtf` | IINA 项目说明 + GPL-3 声明 + `Copyright © 2017-2026 Collider LI, et al.` | **GPL-3 §5(a) 要求衍生作品保留原作者版权声明**。luluk 是 IINA 的衍生作品，这个文件就是法律上必须保留的"原作者署名" |

**验证**（不改文件，只确认）：

```bash
# Credits.rtf 应包含 mpv / FFmpeg 等依赖 license
textutil -convert txt -stdout luluk/Credits.rtf | grep -E "(libmpv|FFmpeg)"

# Contribution.rtf 应包含 IINA 团队署名 + GPL 声明
textutil -convert txt -stdout luluk/Contribution.rtf | grep -E "(Collider LI|GNU General Public License)"
```

**luluk 自己的版权信息**：建议将来在 luluk 自己写的 About 页（不是改 IINA 这两个 rtf）或 README 里加一句「luluk 基于 IINA 二次开发，遵循 GPL-3.0 协议；原 IINA 项目版权属于 Collider LI 等贡献者」。这是补充性的，不是 GPL 强制；强制部分（保留 Contribution.rtf）已通过"不动这两个 rtf"满足。

**不改 rtf 的原因**：RTF 是富文本格式，用编辑器（含 Edit/Write 工具）按字符改会破坏格式标记。如果将来需要修改这些文件，请用 macOS TextEdit 打开。

---

## 阶段 3：第一次 Build & Run

```bash
cd /Users/erik/development/luluk
open luluk.xcodeproj
```

在 Xcode 里：
1. Scheme 选 `luluk`（批 2 commit `d208ebd` 已把所有 target 重命名 `iina` → `luluk`）
2. Signing & Capabilities → Team 选自己的 Apple Developer Team（批 1 已清空 IINA 团队 ID）
3. ⌘+R run
4. 应该能看到一个**绿色图标 + luluk 名字**的 macOS 应用打开

### 验证清单（已完成 ✓）
- [x] Dock 图标是绿色 luluk logo
- [x] 应用名「luluk」（不是 IINA）
- [x] About 窗口标题「luluk」+ 版本 `0.1.0 Build 1`
- [x] About 窗口致谢仍然保留 IINA 团队（GPL 要求，见 `Contribution.rtf`）
- [x] 不会触发"软件更新"对话框（SUFeedURL 已指向 luluk.xyz）

---

## 阶段 4：AI 字幕模块开发

> 详细工程计划见 **[`docs/AI_SUBTITLE_DESIGN.md`](AI_SUBTITLE_DESIGN.md)**——本文件这一节只列里程碑总览，避免跟设计文档冲突。

### 里程碑总览

| 里程碑 | 内容 | 工时 | 状态 |
|--------|------|------|------|
| **M1** | 纯算法：Sanitizer + SRTMerger + SrtLine + Language + ~50 单元测试 | 1-2 天 | ✅ 已完成（commit `6dbdacd`+ `303ec61`+ `2fd5245`+ `7765693`）|
| **M2** | 进程框架：AudioSplitter + WhisperRunner + WhisperProcessPool + ModelDownloader | 3-5 天 | ⏳ 待启动 |
| **M3** | 单 provider 端到端：DeepSeekProvider + AISubtitleService 流水线 + IINA hook | 5-7 天 | ⏳ |
| **M4** | UI：PrefAISubtitleViewController + 进度面板 + Keychain | 4-6 天 | ⏳ |
| **M5** | watch + 全 provider：SubtitleFileWatcher + MiniMax/OpenAI/Custom/LulukCloud/NLLBLocal | 6-8 天 | ⏳ |

每个 M 的具体新建文件、测试用例、IINA 集成 patch 点见 `AI_SUBTITLE_DESIGN.md §4`。

### M1 已锁定的开放问题（同步自 AI_SUBTITLE_DESIGN.md §7）

- whisper-cli + 模型下载源：**Hugging Face** (`ggerganov/whisper.cpp`)
- BD/m3u8 等非常规源：**V1 不支持**（gated by `info.isNetworkResource`）
- whisper 进程池上限：**5 个全局**（多视频共享）
- AudioSplitter 时长来源：**自己 `ffprobe`**，不依赖 mpv
- NLLB Python helper IPC：**stdin/stdout JSON-lines**

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

### 阶段 1：开发环境（✅ 已完成）
- [x] Xcode 安装 + xcodebuild license
- [x] `./other/download_libs.sh` 拉预编译依赖（commit `0453365` 修了硬编码 PROJECT_NAME）
- [ ] 注册 Apple Developer Program（用户私事）

### 阶段 2：换皮（✅ 已完成）
- [x] §2.1 Bundle ID 替换（3 处，含原文档漏写的 SettingsPageUtilities Safari 扩展引用）—— `fb30805` + `0b9a210`（修 prefix 冲突）
- [x] §2.2 Sparkle 更新源 + 清空 IINA EDDSA 公钥 —— `ebff934`
- [x] §2.3 应用名（CFBundleName / CFBundleDisplayName）—— `ecfb801`
- [x] §2.4 应用图标（1254×1254 高分辨率 + 4 套 AppIcon variant）—— `04a5f0d` + `5805eea` + `2bc2b01`
- [x] §2.5 关闭 Crowdin —— `d06b292`
- [x] §2.6 替换 IINA 站点链接 + 清理 Safari 迁移列表 —— `ed569ed`
- [x] §2.7 验证 GPL 致谢保留 —— `0c646f3`
- [x] 追加：批 1 PRODUCT_NAME=luluk + version 0.1.0 + entitlements rename —— `ede6304`
- [x] 追加：批 2 target/folder/xcodeproj 全 rename —— `d208ebd` + `92cfa6e`
- [x] 追加：Xcode `iina-Bridging-Header.h` import 修复 —— `5805eea`（含 in M1 wiring）
- [x] 追加：About 窗口 xib + Contribution.rtf 改写 —— `c15e4d6`

### 阶段 3：第一次 Build & Run（✅ 已完成）
- [x] `open luluk.xcodeproj` + ⌘+B + ⌘+R 跑通
- [x] 验证清单全绿（图标 / 应用名 / About / Sparkle 不弹）

### 阶段 4：AI 字幕模块开发（🔄 M1+M2 完成，M3-M5 待启动）
- [x] **M1**：Sanitizer + SRTMerger + SrtLine + Language + ~50 单元测试
- [x] **M2**：AudioSplitter + WhisperRunner + WhisperProcessPool + ModelDownloader（83 单元测试通过；ensureWhisperReady 走应用支持目录 + PATH fallback；下载逻辑 stub 留 M5）
- [ ] **M3**：DeepSeekProvider + AISubtitleService + IINA hook
- [ ] **M4**：设置面板 UI + 进度面板 + Keychain
- [ ] **M5**：FSEventStream + 全 provider + NLLB Python helper + ModelDownloader 真实下载逻辑

### 阶段 5：发布（⏳ V1 上线前）
- [ ] §5.1-§5.5 代码签名 / 公证 / Sparkle 密钥 / GitHub Release / 部署 luluk.xyz
