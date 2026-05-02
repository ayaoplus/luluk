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

### 2.1 Bundle ID（2 处）

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

> 注：Bundle ID 改后 IINA 和 luluk 可在同一台 Mac 共存，互不冲突。

### 2.2 Sparkle 更新源

**文件**：`iina/Info.plist` 行 639-643

```diff
  <key>SUFeedURL</key>
- <string>https://www.iina.io/appcast.xml</string>
+ <string>https://luluk.xyz/appcast.xml</string>
  <key>SUPublicDSAKeyFile</key>
  <string>dsa_pub.pem</string>
  <key>SUPublicEDKey</key>
- <string>UpwCRYfYOg0OGgQHY6RUdrV29yPcdkvxGlEfq46r6a0=</string>
+ <string>暂时清空，未签名前用占位</string>
```

> ⚠️ **没换 SUFeedURL 会被 IINA 的更新覆盖**，用户装的 luluk 会被替换回 IINA！必改。

#### Sparkle 签名密钥（暂时跳过，发版前补）
- 现在：删除 `iina/dsa_pub.pem` 用空文件占位（开发期不需要签名）
- 发版前：用 Sparkle 工具生成新的 `dsa_pub.pem` 和对应的 EDDSA key
- 工具：[Sparkle generate_keys](https://sparkle-project.org/documentation/#publishing-an-update)

### 2.3 应用名 / Bundle Display Name

**文件**：`iina/Info.plist`（搜索 `CFBundleName` / `CFBundleDisplayName`）

```diff
  <key>CFBundleName</key>
- <string>IINA</string>
+ <string>luluk</string>
  <key>CFBundleDisplayName</key>
- <string>IINA</string>
+ <string>luluk</string>
```

### 2.4 应用图标

#### 2.4.1 生成 .icns
```bash
cd /Users/erik/development/luluk
./scripts/generate_icons.sh assets/logo.png
# 输出 assets/AppIcon.icns + 全套 PNG
```

#### 2.4.2 替换 IINA 图标
1. 打开 Xcode → `iina/Assets.xcassets/AppIcon.appiconset/`
2. 删除现有 IINA 图标全部尺寸
3. 拖入 `assets/AppIcon.iconset/` 里生成的所有 .png 到对应槽位
4. （或直接替换 `iina/Assets.xcassets/AppIcon.appiconset/Contents.json` 引用的文件）

### 2.5 Crowdin 翻译配置

V1 先不上多语言 UI，关掉 Crowdin：

```bash
mv /Users/erik/development/luluk/crowdin.yml /Users/erik/development/luluk/.archive_crowdin.yml
```

V1 上线后再开。

### 2.6 移除/替换 Crash Report endpoint

**文件**：搜索源码 `colliderli` 或 `iina.io`：
```bash
cd /Users/erik/development/luluk
grep -rn "colliderli\|iina\.io" iina/ --include="*.swift"
```

逐个评估：埋点上报相关的注释掉或换成自己的 endpoint，致谢/版权声明保留。

### 2.7 About 窗口致谢保留 IINA

**文件**：`iina/Credits.rtf` 和 `iina/Contribution.rtf`

GPL-3 要求保留原作者署名。**不要删 IINA 的 Credits**。在 luluk 自己的版权信息里加一句"基于 IINA 开发，遵循 GPL-3"。

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
