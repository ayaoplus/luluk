# luluk AI 字幕引擎 · 设计文档

> 这是 [SPEC.md §5（技术架构）](SPEC.md#5-技术架构) 的工程化展开。SPEC 锁定了**做什么**（产品需求 + 决策），本文档锁定**怎么做**（protocol 签名、并发模型、IINA 集成点、里程碑分解）。
>
> 阅读顺序：先 §1 架构总览（10 分钟读完看到全貌），再 §2 接口契约（写代码时按图索骥），§3 集成点（要改 IINA 的哪些既有文件），§4 里程碑（每个 M 都可独立验证 + commit + 回滚）。

**更新**：2026-05-02

---

## 1. 架构总览

### 1.1 数据流图（含并发标注）

```
┌─ IINA 既存代码 ─────────────────────────────────────┐
│ PlayerCore.openMainWindow(path, url, isNetwork)    │
│   │                                                │
│   ↓ [hook 点] @MainActor                           │
└───┼────────────────────────────────────────────────┘
    │
    ↓ Task.detached  (跨 main → 后台)
┌───┴──────────────────────────────────────────────────┐
│ AISubtitleService  (actor, 每 PlayerCore 一实例)     │
│                                                      │
│   start(videoURL, sourceLang) async                  │
│   │                                                  │
│   ├─→ AudioSplitter.split(videoURL) async            │
│   │     spawns ffmpeg, parses silencedetect          │
│   │     yields AsyncStream<AudioSegment>             │
│   │                                                  │
│   ├─→ for await segment in audioStream {             │
│   │     Task { transcribeAndTranslate(segment) }     │
│   │   }                                              │
│   │     ↓ 段级并发上限 3                              │
│   │                                                  │
│   ├─→ WhisperRunner.transcribe(segment) async throws │
│   │     spawns whisper-cli (CoreML/Metal)            │
│   │     → TranscriptionResult                        │
│   │                                                  │
│   ├─→ Sanitizer.clean(transcription) → [SrtLine]     │
│   │     纯函数，4 类幻觉清理                           │
│   │                                                  │
│   ├─→ TranslationProvider.translate(batch:8 lines)   │
│   │     async throws → [SrtLine]                     │
│   │                                                  │
│   └─→ SRTMerger.append(translatedLines, offset)      │
│         actor 串行写入 .zh.srt 文件                    │
│                                                      │
└──────────────────────────────────────────────────────┘
    │
    ↓ FSEventStream (kernel 通知)
┌───┴──────────────────────────────────────────────────┐
│ SubtitleFileWatcher  (per-PlayerCore)                │
│   .zh.srt 修改 → MainActor.run {                     │
│     player.reloadAllSubs()  ← IINA 既有方法           │
│   }                                                  │
└──────────────────────────────────────────────────────┘
    │
    ↓ mpv sub-reload command
[用户屏幕字幕实时更新]
```

### 1.2 关键设计决策

| 决策 | 选择 | 拒绝的方案 + 理由 |
|------|------|-----------------|
| **并发原语** | Swift Structured Concurrency（`actor` + `async/await` + `AsyncStream`）| 拒绝 Combine（IINA 现存代码无 Combine 依赖，引入会扩大测试面）；拒绝纯 DispatchQueue（actor 状态隔离更干净，IINA 已用了 5 个文件的 async/await）|
| **AISubtitleService 形态** | `actor` 类型 | 拒绝 NSObject + DispatchQueue（actor 自动串行化对内部 mutable state 的访问，省手动锁）|
| **IINA 边界** | `Task.detached` 入、`MainActor.run` 出 | PlayerCore 是 NSObject 在 main thread 跑，AISubtitleService 是 actor 跑后台；进出边界用 Task 桥接 |
| **错误分类** | 4 级：fatal / user-actionable / silent-fallback / recoverable-retry | 不用单一 Error 类型——不同错误的 UI 行为不同（弹窗 vs 静默 vs 进度面板提示）|
| **取消语义** | 视频关闭/切换时**取消整个 Service**（actor deinit 时取消所有进行中 Task）| 拒绝"上一个视频的字幕生成完再切"——用户切走时立刻杀进程释放 CPU |
| **状态共享** | 每个 PlayerCore 持有自己的 AISubtitleService（1:1）| IINA 多窗口设计，全局单例无法处理并发视频 |
| **进度上报** | `AsyncStream<PipelineProgress>` 从 actor 发往 UI | 拒绝回调（callback hell）、拒绝 NSNotification（弱类型 + 跨线程难追踪）|
| **API key 存储** | macOS Keychain | 拒绝 NSUserDefaults / Preference.swift（明文存敏感凭据）|
| **whisper-cli 分发** | 首次启动应用内引导下载到 `~/Library/Application Support/luluk/bin/`（参考 SPEC §5.3）| 拒绝打包到 .app（model 1.5GB 太大）、拒绝 .pkg 单独安装（增加用户配置步骤）|
| **NLLB 集成** | Python helper 子进程（PyInstaller 打成单 binary）| 拒绝 Swift port（torch + transformers 不能直接 Swift）；拒绝 Core ML 转换（quantize 损失质量、维护成本高）|

### 1.3 错误分类与处理策略

```swift
enum SubtitleError: Error {
    // Fatal: 整个流水线无法继续，必须停
    case whisperBinaryMissing      // 首次启动未下载
    case ffmpegBinaryMissing       // download_libs.sh 没跑
    case videoFileUnreadable       // mpv 加载视频成功但 ffmpeg 读不了（罕见）
    
    // UserActionable: UI 弹窗让用户处理
    case allProvidersExhausted     // 用户 key 失效 + 本地 NLLB 不在 + Cloud 余额光
    case modelDownloadFailed(URL)  // whisper 模型下载失败、引导用户重试
    case insufficientDiskSpace
    
    // SilentFallback: 静默切换 provider，进度面板显示一行 hint
    case providerRateLimited(Provider)  // DeepSeek 429 → fallback NLLB
    case providerInvalidKey(Provider)   // 401 → 提示 + fallback
    case providerNetworkUnreachable     // 离线 → fallback NLLB
    
    // RecoverableRetry: 内部自动重试，用户感知不到
    case transcriptionTimeout      // whisper 卡住，kill + 重试同段
    case translationBatchMalformed // JSON 解析失败 → 拆成单行重译
    case sanitizerLineDropped(reason: String)  // 一行幻觉，记 log 不报错
}
```

### 1.4 模块依赖图

```
                    AISubtitleService (顶层调度)
                            │
        ┌───────────────────┼─────────────────────┐
        │                   │                     │
        ↓                   ↓                     ↓
   AudioSplitter      WhisperRunner         TranslationProvider
   (ffmpeg)           (whisper-cli)         (协议)
        │                   │                     │
        │                   │      ┌──────────────┼─────────────┐
        │                   │      │ DeepSeek MiniMax OpenAI    │
        │                   │      │ Custom LulukCloud NLLB     │
        │                   │      └────────────────────────────┘
        │                   │                     │
        ↓                   ↓                     ↓
   AudioSegment       TranscriptionResult    [SrtLine]
                            │
                            ↓
                        Sanitizer (纯函数)
                            │
                            ↓
                       SRTMerger (actor)
                            │
                            ↓
                      .zh.srt 文件
                            │
                            ↓
                  SubtitleFileWatcher (FSEventStream)
                            │
                            ↓
                  PlayerCore.reloadAllSubs() [IINA]
```

---

## 2. 模块接口契约

> **本节是写代码时的真理**——填实现照着填，公开接口不能跑偏。  
> 所有 `async` 方法默认可 `throw`，`throws` 关键字省略以求简洁。

### 2.1 协议层（最重要 · 锁住扩展性）

#### 2.1.1 `TranslationProvider`

```swift
protocol TranslationProvider: Sendable {
    /// 显示名（用户看到的，比如 "DeepSeek (你的 Key)"）
    var displayName: String { get }
    
    /// 是否可用（已配置好 + 可达）—— UI 用来显示状态徽标
    var isReady: Bool { get async }
    
    /// 翻译一批字幕
    /// - Parameters:
    ///   - batch: 待翻译的 8 行（最大）
    ///   - context: 前 3 行作为上下文，不翻译，仅参考（避免代词指代漂移）
    ///   - source: 源语言（whisper 检测的或用户手选）
    ///   - target: 目标语言（V1 固定中文）
    /// - Returns: 跟 batch 同长的译文行（idx/start/end 跟原行对齐）
    /// - Throws: SubtitleError.providerXxx 系列
    func translate(
        batch: [SrtLine],
        context: [SrtLine],
        source: Language,
        target: Language
    ) async throws -> [SrtLine]
    
    /// 单行重译（batch 整批失败时退化用）
    /// 默认实现：调上面的 translate，batch=1
    func translateSingle(
        line: SrtLine,
        context: [SrtLine],
        source: Language,
        target: Language
    ) async throws -> SrtLine
}
```

#### 2.1.2 `TranscriptionProvider`

> V1 只有 whisper.cpp，但抽象出协议方便 V2+ 接入 mlx-whisper / WhisperKit / 云端 ASR。

```swift
protocol TranscriptionProvider: Sendable {
    var displayName: String { get }
    var isReady: Bool { get async }
    
    /// 转写一段音频
    func transcribe(
        audio: AudioSegment,
        language: Language?  // nil = 自动检测（不推荐，参考 SPEC §7.4）
    ) async throws -> TranscriptionResult
}
```

#### 2.1.3 `ProgressReporter`

```swift
protocol ProgressReporter: Sendable {
    /// 流水线进度更新（UI 订阅这个 stream 实时刷新）
    var progressStream: AsyncStream<PipelineProgress> { get }
}
```

### 2.2 顶层服务

#### `AISubtitleService`

```swift
actor AISubtitleService: ProgressReporter {
    
    // MARK: - 生命周期
    
    /// 创建一个 service，跟 PlayerCore 1:1 绑定。
    /// service 持有 player 的 weak 引用（避免循环），player.deinit 时 service 自动取消。
    init(player: PlayerCore)
    
    /// 用户在 UI 启用 AI 字幕（默认开），开始流水线
    /// - Parameters:
    ///   - videoURL: 视频文件 URL（必须是本地文件，不支持 stream）
    ///   - sourceLanguage: nil = 自动检测（whisper 内部）；推荐用户手动指定
    ///   - targetLanguage: 默认 .simplifiedChinese
    /// - 副作用：
    ///   - spawn ffmpeg 切片
    ///   - spawn whisper-cli × 并发 3
    ///   - 调 TranslationProvider 翻译
    ///   - 增量写 <video>.zh.srt 同目录
    func start(
        videoURL: URL,
        sourceLanguage: Language? = nil,
        targetLanguage: Language = .simplifiedChinese
    ) async
    
    /// 取消当前流水线（杀所有进程、删未完成 srt）
    /// PlayerCore.deinit 或视频切换时调用
    func cancel() async
    
    /// 给 UI 用的进度流。actor → MainActor.run 桥接到 UI
    nonisolated var progressStream: AsyncStream<PipelineProgress> { get }
}
```

#### `PipelineProgress`（UI 实时拉的状态）

```swift
struct PipelineProgress: Sendable {
    let totalSegments: Int           // 由 ffmpeg silencedetect 决定
    let transcribedSegments: Int     // whisper 完成的段数
    let translatedSegments: Int      // 翻译完的段数
    let elapsedSeconds: Double       // 流水线开始至今
    let firstSubtitleLatency: Double?  // 第一段翻译完成的耗时（用户最关心）
    let estimatedTotalSeconds: Double? // 基于已完成段的速率推算
    let tokensUsed: Int              // 累计 token（DeepSeek 这类按 token 计费）
    let currentProvider: String      // "DeepSeek" / "NLLB Local" / ...
    let lastError: SubtitleError?    // 最近一次错误（UI 显示提示条）
    let state: State
    
    enum State: Sendable {
        case idle
        case splitting              // ffmpeg 切片中
        case running                // 正常流水线
        case fallback(reason: String) // 切到了备用 provider
        case completed              // 视频转写翻译全部完成
        case cancelled
        case failed(SubtitleError)
    }
}
```

### 2.3 子组件

#### `AudioSplitter`

```swift
actor AudioSplitter {
    
    /// 切音频为 ~45s 段，在静音点对齐
    /// - 算法：spawn `ffmpeg -af silencedetect=...`，解析 stderr 取静音区间，
    ///   把视频按"最近静音点"切成 ~45s 段（避免在话语中间断开）
    /// - 输出格式：16kHz mono WAV（whisper 要求）
    /// - 实现参考：ai-subtitle-prototype/pipeline/audio_split.py
    func split(
        videoURL: URL,
        outputDir: URL,
        targetSegmentDuration: TimeInterval = 45.0
    ) -> AsyncThrowingStream<AudioSegment, Error>
}

struct AudioSegment: Sendable {
    let index: Int                 // 0-based 段号
    let wavURL: URL                // 临时 WAV 文件路径
    let originalStartTime: TimeInterval  // 在原视频中的起始时间
    let duration: TimeInterval
}
```

#### `WhisperRunner`

```swift
actor WhisperRunner: TranscriptionProvider {
    
    init(
        binaryURL: URL,            // whisper-cli 路径
        modelURL: URL,             // .gguf 模型路径
        useVAD: Bool = true        // SPEC §4.1 默认开
    )
    
    /// spawn whisper-cli，解析 stdout JSON 输出
    /// 关键命令：whisper-cli -m model.gguf --vad -of json -oj input.wav
    func transcribe(
        audio: AudioSegment,
        language: Language?
    ) async throws -> TranscriptionResult
}

struct TranscriptionResult: Sendable {
    let segmentIndex: Int          // 跟 AudioSegment.index 对应
    let language: Language?        // whisper 检测的（如果没手动指定）
    let lines: [SrtLine]           // raw 输出，未经 sanitize
    let confidence: Double?        // SPEC §7.4 进阶：低置信度可触发重检
}
```

#### `Sanitizer`

```swift
/// 纯函数模块（无状态），可单元测试
/// 实现参考：ai-subtitle-prototype/pipeline/sanitize.py
enum Sanitizer {
    
    /// 清理 whisper 输出的 4 类幻觉（SPEC §7.1）
    /// - 1 类（重复字符 `はっはっはっ...`）→ 替换为简短中文
    /// - 2 类（重复短模式 `あっはぁっ...`）→ 简化
    /// - 3 类（长时长 + 高频结尾词，30 秒 `おやすみなさい`）→ 替换"（无对白）"
    /// - 4 类（SDH 标注 `*sigh*` `[music]`）→ 译文置空，最终 SRT 跳过该行
    static func clean(_ lines: [SrtLine]) -> [SrtLine]
    
    /// 单独检测某行是否为幻觉（给 UI 用，比如显示"检测到 3 处幻觉"）
    static func detectHallucination(_ line: SrtLine) -> HallucinationType?
    
    enum HallucinationType: Sendable {
        case repeatedChar
        case repeatedPattern
        case longSilenceFiller
        case sdh
    }
}
```

#### `SRTMerger`

```swift
actor SRTMerger {
    
    init(outputURL: URL)
    
    /// 追加一段翻译后的字幕到 .zh.srt 文件
    /// - 自动按 segment.index 排序（即使翻译完成顺序乱了）
    /// - 重新编号（idx 连续）
    /// - 原子写（写临时文件再 rename，避免 FSEventStream 看到半成品）
    func append(
        lines: [SrtLine],
        segmentIndex: Int,
        offsetInOriginalVideo: TimeInterval
    ) async throws
    
    /// 完成时调用：清掉临时态、写最终版
    func finalize() async throws
}
```

#### `SubtitleFileWatcher`

```swift
actor SubtitleFileWatcher {
    
    init(player: PlayerCore, watchDir: URL, srtFilename: String)
    
    /// 启动 FSEventStream
    /// 检测到 srtFilename 修改时 → MainActor.run { player.reloadAllSubs() }
    /// 用 debounce 250ms（避免 SRTMerger 频繁写触发太多次 reload）
    func start() async
    
    func stop() async
}
```

#### `ModelDownloader`

```swift
actor ModelDownloader {
    
    /// SPEC §5.3 决策：whisper-cli + large-v3-turbo（默认）
    /// 路径：~/Library/Application Support/luluk/bin/whisper-cli
    ///       ~/Library/Application Support/luluk/models/ggml-large-v3-turbo.bin
    func ensureWhisperReady() async throws -> WhisperPaths
    
    /// 下载进度（UI 显示）
    var progressStream: AsyncStream<DownloadProgress> { get }
    
    /// 切换模型（用户从 UI 选择 large-v3 / medium-turbo / tiny）
    func switchModel(to: WhisperModel) async throws
}

enum WhisperModel: String, CaseIterable, Sendable {
    case largeV3Turbo = "large-v3-turbo"  // 默认，1.5GB
    case largeV3      = "large-v3"        // 高质量，3GB
    case mediumTurbo  = "medium-turbo"    // 弱机降级，1GB
    case tiny         = "tiny"            // 极弱机
}

struct WhisperPaths: Sendable {
    let binary: URL
    let model: URL
}
```

### 2.4 数据结构

#### `SrtLine`

```swift
struct SrtLine: Sendable, Codable {
    var index: Int                  // SRT 序号 1-based
    var startTime: TimeInterval     // 秒
    var endTime: TimeInterval
    var text: String                // 单语：原文 OR 译文；双语：原文\n译文
    
    /// SRT 文件序列化
    func srtFormatted() -> String
    
    static func parse(_ srtContent: String) -> [SrtLine]
}
```

#### `Language`

```swift
enum Language: String, CaseIterable, Sendable, Codable {
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case spanish = "es"
    case simplifiedChinese = "zh"
    
    /// LLM prompt 用的显式语言名（SPEC §7.3：必须传"简体中文"不能传 "zh"）
    var llmPromptName: String {
        switch self {
        case .simplifiedChinese: return "简体中文 (Simplified Chinese)"
        case .english: return "English"
        case .japanese: return "日本語 (Japanese)"
        // ...
        }
    }
    
    /// whisper 用的 ISO 码（whisper 接受 zh）
    var whisperCode: String { rawValue }
}
```

### 2.5 Provider 实现要点（不展开完整接口，只列关键决策）

| Provider | 实现类 | 关键点 |
|----------|--------|--------|
| `DeepSeekProvider` | OpenAI 兼容 client | base_url = `https://api.deepseek.com`，model = `deepseek-chat`，response_format = `json_object` |
| `MiniMaxProvider` | 国内站 client | base_url = `https://api.minimaxi.com/v1`（带 i），model 默认 `MiniMax-M2`，**必须 strip `<think>...</think>` 块**（SPEC §7.5）|
| `OpenAIProvider` | OpenAI 兼容 client | base_url 可改（默认 `https://api.openai.com/v1`），model 默认 `gpt-4o-mini` |
| `CustomProvider` | OpenAI 兼容 client + 用户自填 endpoint/model | 检查 base_url 必须 https |
| `LulukCloudProvider` | OpenAI 兼容 client + Bearer auth | endpoint 写死 `https://api.luluk.xyz`，token 来自 LulukCloudAuth.swift |
| `NLLBLocalProvider` | spawn Python helper + IPC | binary 来自 ModelDownloader，stdin/stdout JSON 协议 |

---

## 3. IINA 集成点

> 这一节列**要改 IINA 既有代码的明细**——不是新建文件，是 patch 既有的 .swift。每一处都说明改什么、为什么、是否破坏 upstream 合并。

### 3.1 视频打开 hook

**文件**：`luluk/PlayerCore.swift`  
**位置**：`openMainWindow(path:url:isNetwork:)` 方法末尾（line ~545）

```swift
// 既有代码末尾
mpv.command(.loadfile, args: [path], level: .verbose)

// ▼ 新增 hook
if !isNetwork && Preference.bool(for: .aiSubtitleEnabled) {
    Task.detached { [weak self] in
        guard let self = self else { return }
        await self.aiSubtitleService.start(videoURL: url)
    }
}
// ▲ 新增结束
```

**说明**：
- `isNetwork == true` 时跳过：流媒体 URL ffmpeg 不能切片
- `Preference.bool(for: .aiSubtitleEnabled)` 默认 `true`（SPEC §11 决策："默认开"）
- 加在 `loadfile` **之后**，让 mpv 先开始解码（首字幕延迟从 mpv 加载完才开始算）
- `aiSubtitleService` 是 PlayerCore 新增的 `lazy var`，跟 `info: PlaybackInfo` 同款 1:1 模式（line 225）

**新增成员**（在 PlayerCore class 顶部）：
```swift
lazy var aiSubtitleService: AISubtitleService = AISubtitleService(player: self)
```

### 3.2 视频切换/关闭 → 取消流水线

**文件**：`luluk/PlayerCore.swift`  
**位置**：`stop()` 方法 + 视频切换路径

```swift
func stop() {
    // ...既有代码
    
    // ▼ 新增
    Task { await aiSubtitleService.cancel() }
    // ▲ 新增结束
}
```

**说明**：用户切换视频时立刻杀进程释放 CPU。`Task` 不 await，因为 stop() 可能在 main thread 阻塞调用。

### 3.3 字幕重载（FSEventStream → mpv）

**好消息**：不需要改 IINA 既有代码。

`PlayerCore.reloadAllSubs()`（line 1425）已经实现完整：调 mpv `sub-reload` + 更新 UI。我们的 `SubtitleFileWatcher` 直接调它即可：

```swift
// SubtitleFileWatcher 内部
await MainActor.run {
    player.reloadAllSubs()
}
```

### 3.4 设置面板新增 AI 字幕 tab

**文件**：`luluk/PreferenceViewController.swift`（tab container）  
**改动**：在已有 12 个 tab 后添加 1 个

```swift
// 既有代码风格
let viewControllers = [
    PrefGeneralViewController(),
    PrefUIViewController(),
    PrefSubViewController(),
    // ...
    
    PrefAISubtitleViewController(),  // ▼ 新增
]
```

**新建文件**：`luluk/PrefAISubtitleViewController.swift`（约 200 行）  
**UI 结构**（参照 SPEC §15.2 设置面板布局）：
```
设置 → AI 字幕：
  
  [√] 启用 AI 字幕（视频打开时自动生成）
  
  Whisper 模型：
    ◉ large-v3-turbo（推荐 · 已下载 1.5GB）
    ○ large-v3（高质量 · 需下载 3GB）  [下载]
    ○ medium-turbo（弱机降级）
    ○ tiny（极弱机）
  
  ──────────────────────
  
  翻译服务：
    ○ luluk Cloud（推荐 · 开箱即用）
        [登录/注册]  套餐: ¥9.9/月起 [选择套餐]
    
    ○ 我有 API Key（DIY）
        □ DeepSeek      sk-_______________
        □ MiniMax       _________________
        □ OpenAI        sk-_______________
        □ 自定义 Endpoint  https://_______
        
    ○ 本地翻译（免费 · 无需联网）
        NLLB-200-distilled-600M（已下载 600MB）
  
  ──────────────────────
  
  字幕样式：
    [√] 双语字幕（原文上 译文下）
    [√] 字幕文件变更时自动刷新（FSEventStream watch）
    [选择字幕预设...]
```

### 3.5 进度面板（OSD 风格）

**文件**：`luluk/AISubtitleProgressViewController.swift`（新建，~150 行）  
**集成点**：嵌入到 `MainWindowController` 的 OSD 区域（mpv 自带 OSD 风格的悬浮 panel）

订阅 `AISubtitleService.progressStream`，显示：
- 进度条（基于 `transcribedSegments / totalSegments`）
- 首字幕延迟（首段完成后定格显示）
- 当前 Provider
- token 累计 + 估算成本

### 3.6 视频元信息访问

**好消息**：直接读 `info: PlaybackInfo`（PlayerCore line 225）：
- 视频路径：`info.currentURL?.path`
- 时长：`info.videoDuration`（mpv 加载完成后填充）
- 是否网络流：`info.isNetworkResource`

但注意 `videoDuration` 是 **mpv 加载完成后异步填充的**——AISubtitleService.start 时可能还是 nil。解决：用 ffprobe 先探一下时长（AudioSplitter 内部需要），或不依赖这个字段（按段流式产生，不预知总长）。

### 3.7 Preference key 注册

**文件**：`luluk/Preference.swift`  
**改动**：枚举 `Preference.Key` 末尾添加：

```swift
// ▼ luluk: AI 字幕
static let aiSubtitleEnabled = Key("aiSubtitleEnabled")
static let aiSubtitleProvider = Key("aiSubtitleProvider")  // "deepseek" / "minimax" / "lulukCloud" / "nllbLocal" / ...
static let aiSubtitleSourceLanguageMode = Key("aiSubtitleSourceLanguageMode")  // "auto" / "manual"
static let aiSubtitleManualSourceLanguage = Key("aiSubtitleManualSourceLanguage")  // "ja" / "en" / ...
static let aiSubtitleBilingual = Key("aiSubtitleBilingual")
static let aiSubtitleAutoReload = Key("aiSubtitleAutoReload")
static let aiSubtitleWhisperModel = Key("aiSubtitleWhisperModel")
static let aiSubtitleTokensUsed = Key("aiSubtitleTokensUsed")  // 累计 token 显示
// ▲ luluk 结束
```

### 3.8 不需要改 IINA 既有代码的部分

为了保持 IINA upstream 合并的可能性（虽然 SPEC §10 决定走自己的路），尽量隔离：

- ✅ 字幕加载流程（IINA 既有 `AutoFileMatcher` + `reloadAllSubs` 完整 work，无需改）
- ✅ mpv command 路径（直接复用 `MPVCommand.subReload`）
- ✅ 视频生命周期 hook 点（只改 `openMainWindow` 末尾 + `stop()` 末尾，2 个 patch 点）
- ✅ 设置面板 tab 容器（只在 array 末尾 push）

**改动总结**：IINA 既有 `.swift` 文件 patch **3 处**：
- `PlayerCore.swift`：2 处（hook + cancel）+ 1 个 lazy var
- `PreferenceViewController.swift`：1 处（push tab）
- `Preference.swift`：1 处（key 枚举）

---

## 4. 里程碑分解

每个 M 都满足：
- 可独立 commit + push
- 可独立验证（有可观察的 build 产物或可跑的脚本）
- 可独立回滚（不破坏 main 分支的 build）
- 单元测试 + 手动 demo 流程都明确

### M1：纯算法模块（Sanitizer + SRTMerger）

**目标**：写两个无副作用模块 + 完整单元测试，**不依赖 mpv / 不依赖网络**。

**新建文件**：
- `luluk/AISubtitle/SrtLine.swift`（数据结构）
- `luluk/AISubtitle/Language.swift`（枚举）
- `luluk/AISubtitle/Sanitizer.swift`（移植 sanitize.py）
- `luluk/AISubtitle/SRTMerger.swift`（移植 srt_merge.py）
- `lulukTests/SanitizerTests.swift`
- `lulukTests/SRTMergerTests.swift`

**测试用例**（必须覆盖 SPEC §7.1 的 4 类幻觉）：
- 喂入 `はっはっはっ × 100` → 输出"哈哈哈"
- 喂入 `*sigh*` → 输出空（被丢弃）
- SRT 合并：乱序段 #2 #0 #1 → 输出按时间排序的连续 idx

**验证**：`xcodebuild test -scheme luluk` 全绿。

**预计工时**：1-2 天。

### M2：进程 spawn 框架（AudioSplitter + WhisperRunner）

**目标**：跑通"视频 → 中间 SRT（未翻译）"，无 UI、无 IINA 集成。

**新建文件**：
- `luluk/AISubtitle/AudioSegment.swift`
- `luluk/AISubtitle/AudioSplitter.swift`（spawn ffmpeg + parse silencedetect）
- `luluk/AISubtitle/TranscriptionResult.swift`
- `luluk/AISubtitle/WhisperRunner.swift`（spawn whisper-cli + parse JSON output）
- `luluk/AISubtitle/ModelDownloader.swift`（先实现 binary check，下载逻辑可 stub）
- 一个手动 demo CLI target（或者 Test 里的 integration test）

**前提**：用户机器上已有 whisper-cli + ggml-large-v3-turbo.bin（先手动放在 ~/Library/Application Support/luluk/）。

**验证脚本**：
```bash
# 手动 integration test
swift run luluk-ai-cli /path/to/test.mp4 ja
# 输出：/path/to/test.raw.srt（未翻译，日文）
```

跟原型 `produce.py --skip-translate` 输出 diff，应该 ≈一致。

**预计工时**：3-5 天（spawn 进程 + stderr 解析最容易踩坑）。

### M3：单 provider 端到端（DeepSeek + 流水线）

**目标**：跑通"视频 → 中文 SRT"完整流水线，但**只支持 DeepSeek 一个 provider**，UI 还没有。

**新建文件**：
- `luluk/AISubtitle/TranslationProvider.swift`（协议 + 公共数据结构）
- `luluk/AISubtitle/Providers/DeepSeekProvider.swift`
- `luluk/AISubtitle/AISubtitleService.swift`（顶层 actor，编排所有上述模块）
- `luluk/AISubtitle/PipelineProgress.swift`
- `luluk/AISubtitle/SubtitleError.swift`
- `lulukTests/AISubtitleServiceTests.swift`（mock provider，跑流水线）

**集成 IINA**（§3.1 + §3.2 + §3.7）：
- patch `PlayerCore.swift`（hook 视频打开 + cancel）
- patch `Preference.swift`（注册 key）
- 临时硬编码 DeepSeek API key 到 Preference（M4 才上 UI）

**验证**：
- 真实视频：在 Xcode 跑 luluk，打开 ai-subtitle-prototype/test_videos/test.mp4，**屏幕字幕在 ~11s 内自动出现中文**。
- 性能基线：跟 SPEC §7.6 表对比，turbo 模式应实时 10×。

**预计工时**：5-7 天。**这是 V1 真正能 demo 的里程碑**。

### M4：UI（设置面板 + 进度面板 + Keychain）

**目标**：替换 M3 的硬编码，让用户能通过 UI 配置。

**新建文件**：
- `luluk/AISubtitle/Keychain.swift`（Apple Keychain 封装，存 API key）
- `luluk/PrefAISubtitleViewController.swift`（设置面板，~200 行）
- `luluk/Base.lproj/PrefAISubtitleViewController.xib`
- `luluk/AISubtitleProgressViewController.swift`（OSD 进度面板，~150 行）

**集成 IINA**（§3.4 + §3.5）：
- patch `PreferenceViewController.swift`（push tab）
- 在 `MainWindowController` 嵌入进度面板

**验证**：
- 用户可以从 UI 切换 provider、填 API key
- 切换后立刻生效（reactive，不需要重启 app）
- 进度面板实时刷新

**预计工时**：4-6 天（macOS 的 xib + AppKit 学习曲线）。

### M5：FSEventStream + 多 provider + NLLB 兜底

**目标**：补齐剩下的 provider + watch + 自动重载，达到 SPEC V1 完整功能。

**新建文件**：
- `luluk/AISubtitle/SubtitleFileWatcher.swift`（FSEventStream 封装）
- `luluk/AISubtitle/Providers/MiniMaxProvider.swift`
- `luluk/AISubtitle/Providers/OpenAIProvider.swift`
- `luluk/AISubtitle/Providers/CustomProvider.swift`
- `luluk/AISubtitle/Providers/LulukCloudProvider.swift`（V1 mock，V1.5 接 api.luluk.xyz）
- `luluk/AISubtitle/Providers/NLLBLocalProvider.swift`（spawn Python helper）
- `nllb-helper/`（PyInstaller 打包 NLLB binary，独立子项目）

**集成 IINA**：
- 进一步 patch `PlayerCore.openMainWindow`：FSEventStream 在 service.start() 内启动

**验证**：
- 切到不同 provider，每个都能跑通
- 离线模式（断网）→ 自动 fallback 到 NLLB
- 字幕生成中途，手动编辑 .zh.srt 文件 → 视频字幕实时刷新

**预计工时**：6-8 天（NLLB Python helper 打包 + 多 provider 边界 case）。

### 里程碑时间总览

| M | 工作内容 | 预计 | 累计 |
|---|---------|------|------|
| M1 | 纯算法 + 测试 | 1-2 天 | 2 天 |
| M2 | 进程框架 | 3-5 天 | 7 天 |
| M3 | 单 provider 端到端 | 5-7 天 | 14 天 |
| M4 | UI | 4-6 天 | 20 天 |
| M5 | watch + 全 provider | 6-8 天 | 28 天 |

**总计 4-5 周**，符合 SPEC §10 路线图 "W3-W10" 的预算（W3-4 移植 pipeline、W5-6 watch、W7-8 UI、W9-10 进度+样式）。

---

## 5. 测试策略

### 5.1 单元测试（必须）

跟着每个里程碑长，目标覆盖率 **70%**（不追求 100%——UI / 进程 spawn 部分难单元测）：

| 模块 | 单元测试 |
|------|---------|
| `Sanitizer` | 4 类幻觉每类 ≥ 3 个用例 + 边界 case（空输入、单字符、超长重复）|
| `SRTMerger` | 乱序段、跨段时间偏移、重叠时间冲突 |
| `SrtLine.parse / .srtFormatted` | 标准 SRT、含 BOM、CRLF、Windows-1252 编码 |
| `Language.llmPromptName` | 6 个语种映射验证 |
| `TranslationProvider` 各实现 | mock URLSession，验证 request body / parse response |
| `AISubtitleService` | mock 所有子组件，验证编排逻辑（段顺序、并发上限、cancel 传播）|

### 5.2 集成测试

`lulukIntegrationTests/` 单独 target，跑真实进程（CI 上可跳过）：
- `EndToEndTest.swift`：喂入 `test_videos/short_japanese.mp4`（5 分钟、含已知幻觉），断言输出 SRT 跟 golden file diff < 5%
- `PerformanceRegressionTest.swift`：跑 SPEC §7.6 的 6 部视频，断言实时倍速 ≥ 8×、首字幕 < 15s

### 5.3 真实视频回归

在 PR 流程加 `scripts/run-regression.sh`，跑 SPEC §7.6 表里的视频，对比基线指标，CI fail 时人工 review。

### 5.4 手动 dogfood checklist

每个 M 完成后，按这个清单跑一遍：
- [ ] 打开短视频（< 5min）能看到字幕
- [ ] 打开长视频（> 1h）不会 OOM
- [ ] 流水线运行中切换视频 → 旧 service 立刻 cancel，新 service 正常启动
- [ ] 关闭 luluk 时进程清理干净（`ps aux | grep whisper` 没有遗留）
- [ ] 网络断开时 → fallback NLLB
- [ ] API key 错误时 → UI 提示

---

## 6. 已废弃的设计选择（避免重复讨论）

跟 SPEC §14 的"已废弃方案"独立——这里只列**实现层级**的废弃决策。

- ❌ **同步 API**：流水线必须 async，所有 provider 接口 async（拒绝阻塞 main thread）
- ❌ **Combine publisher**：IINA 没用 Combine，引入会扩大学习成本和测试面（用 AsyncStream 替代）
- ❌ **NSNotification 上报进度**：弱类型 + 跨线程难追踪（用 typed AsyncStream）
- ❌ **API key 存 Preference / NSUserDefaults**：明文不安全（用 Keychain）
- ❌ **整 video file 一次性 split → 等所有段转写完再翻译**：违反 SPEC §3.2 的"段级流水线"决策
- ❌ **TranslationProvider 用 result type**：`Result<T, E>` 跟 async throws 同时存在导致接口不一致（统一用 `async throws`）
- ❌ **whisper-cli 打包到 .app**：1.5GB 体积膨胀，违反 SPEC §5.3 决策
- ❌ **NLLB 直接用 Swift port**：torch 依赖无法绕开，PyInstaller helper 是已验证方案
- ❌ **AISubtitleService 全局单例**：IINA 多窗口设计，每 PlayerCore 一个 service 实例
- ❌ **流水线状态用 mutex 保护的 struct**：actor 自带状态隔离，不需要手动锁
- ❌ **视频切换时让旧 service 跑完**：用户期待即时切换，旧 service 必须立刻 cancel

---

## 7. 开放问题（已锁定决策，2026-05-02 与用户对齐）

> 原本是 M1 启动前的 5 个 TBD 问题，用户在 M1 编码过程中给出答案。决策已锁定，下列条目作为后续模块实现时的依据。

### 7.1 whisper-cli + 模型下载源 → ✅ Hugging Face

- **whisper-cli binary**：从 Hugging Face 的 [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) 仓库下载（whisper.cpp 官方维护者本人的 HF）
- **模型文件**：同仓库的 `ggml-large-v3-turbo.bin` 等（Hugging Face 主托管渠道）
- **优点**：单一可信源、CDN 全球加速、有 versioning（commit hash + tag）、HF 不会随便下线（业界基础设施）
- **未决细节**（M5 实现 ModelDownloader 时再定）：
  - 是否需要校验 SHA256（HF 自己提供 `.gitattributes` 的 LFS hash，可作为校验）
  - 镜像策略：国内访问慢时是否提供备用源（如自建 CDN）

### 7.2 BD/m3u8 等非常规源 → ✅ V1 不支持

- AISubtitleService.start 在 `info.isNetworkResource == true` 或路径不是本地文件时**不启动**，UI 显示"此格式暂不支持 AI 字幕"
- M3 hook PlayerCore.openMainWindow 时已经按这个约束实现（参考 §3.1）

### 7.3 多视频同开 whisper 进程池上限 → ✅ 全局 5 个进程

- 单视频内段级并发依然按 SPEC §5.3 = 3
- 多视频共享一个**全局进程池**，上限 5（不是每视频 5）
- 实现：在 `WhisperRunner` 之上加一层 `WhisperProcessPool: actor`，所有 `WhisperRunner` 实例从池里申请进程槽
- 第 5 个进程占满后，新转写请求**排队**（不报错，UI 进度面板显示 "Queued"）

### 7.4 AudioSplitter 时长来源 → ✅ 自己探（ffprobe）

- 不依赖 `info.videoDuration`（mpv 异步填充，时序不可控）
- AudioSplitter 启动时立刻 spawn `ffprobe -i <video> -show_format`，解析 duration
- 副作用：多了一次 ffprobe 调用，但只 ~50ms，可忽略
- 简化时序：AISubtitleService 启动 → AudioSplitter 直接探 → 不等 mpv

### 7.5 NLLB Python helper IPC → 🔄 用户倾向 socket，下方是反建议

**用户表态**：倾向 Unix socket，但开放讨论。

**我的反建议：用 stdin/stdout JSON-lines**，对比表：

| 维度 | stdin/stdout JSON-lines | Unix socket |
|------|------------------------|-------------|
| 启动复杂度 | `Process()` 一行，pipe 自动 attach | 选 socket 路径 + bind + accept |
| 生命周期 | luluk 死 → helper 收到 EOF 自动退；helper 死 → pipe 断 | 需要显式 close + 删 socket file + PID 协调 |
| 多客户端 | 不支持（这里也不需要：1 主 1 helper）| 支持（over-engineering for our case）|
| 调试 | `echo '{...}' \| python helper.py` 直接试 | 需要起 helper + nc/socat 客户端 |
| PyInstaller | stdin/stdout 是 entrypoint 默认 | 需要在 entry script 写 socket server |
| 性能 | pipe 内核态零拷贝 | 同 pipe（macOS 上 Unix socket ≈ pipe）|
| 单例性 | 自然单例（luluk 直接 spawn）| 需要 PID file 防双开 |

**结论**：luluk 是 1 主 1 helper 单向调用，stdin/stdout 是 Unix 哲学最简方案；socket 解决的是"多客户端 + 跨进程发现"问题——我们没这俩需求。socket 在工程上是 over-engineering。

如果用户坚持 socket，我也能实现，但会在 M5 commit message 里记录这个决策的 trade-off，便于将来回看。

**待用户最终拍板**——M5 启动前必须定。

---

## 8. 文档同步规则

修改本文档前先：
- 跟 SPEC.md 对齐（如果产品需求变了，先改 SPEC，再改本文档）
- 更新 §6 已废弃方案（保留思考链路）
- 写完一个 M 后，把"实际工时 vs 预计"补到 §4 的表格

每次 PR 修改本文档时 commit message 加 `docs(design):` 前缀。
