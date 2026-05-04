# luluk · V1 产品规格

> **产品名**：**luluk**
> **状态**：阶段 1-3（fork 换皮）+ 阶段 4 M1-M4（AI 字幕模块端到端跑通）已完成；M5 待启动
> **更新**：2026-05-04

---

## 1. 产品概述

### 一句话定位
**luluk 是为看外语视频的普通观众做的"AI 自动字幕播放器"**——一次性配好 API Key 后，打开本地视频约 11 秒内看到目标语言字幕。

> **零配置承诺的状态**：长期目标是"完全零配置可用"（依赖 luluk Cloud 试用额度 + 本地 NLLB 兜底），但 V1 范围内**仅 DeepSeek provider 上线**，普通用户首次使用必须填一次 API Key。M5 起补齐 luluk Cloud 和 NLLB 才能兑现这个承诺。

### 与 IINA 的本质区别
- **IINA**：通用视频播放器，字幕需要用户自己找
- **luluk**：AI 字幕是核心能力，播放只是承载

---

## 2. 目标用户

**主要**：看冷门外语片（日语/英语/法语/韩语电影、纪录片、Vlog 等）的中文观众，**不愿/不会自己找字幕**。

**次要**：语言学习者（V2 再做差异化功能：术语表、双语精读）。

**明确不优先**：
- 极客 / 开发者（已有 MacWhisper / Buzz）
- 中文母语视频观众（不需要字幕）
- Windows / Linux 用户（V1 macOS only）

---

## 3. 与 IINA 的差异化（重点）

### 3.1 功能对比

| 维度 | IINA | 本产品 |
|------|------|--------|
| **字幕来源** | 在线搜索（OpenSub/Assrt/Shooter） | **AI 实时生成 + 翻译** |
| **首字幕等待** | 取决于网络/搜索结果 | **~11 秒**（流水线第一段完成即可看，turbo + GGML+Metal 实测）|
| **字幕翻译** | 不提供 | **三档翻译可选** |
| **字幕重载** | 手动菜单触发 | **磁盘 watch 自动重载**（核心 UX）|
| **双语字幕** | 通过双字幕轨切换 | **原生合成**（一条 SRT 含两种语言）|
| **字幕调教** | 通用偏移/字体 | **针对外语片的预设**（白底黑边、底部居中）|
| **翻译风格** | 不适用 | **自定义 prompt + 术语表** |
| **字幕导出** | 现有字幕的导出 | **生成 SRT / 烧录到视频**（分享给非用户）|
| **字幕错误修正** | 无 | **逐句重译 / 时间轴微调**（V2）|
| **生词标注** | 无 | **V2 学习者功能** |
| **Anki 导出** | 无 | **V2 学习者功能** |

### 3.2 用户体验差异

**IINA 用户旅程（看一部日剧）**：
1. 打开视频
2. 发现没字幕
3. 在网上搜中文字幕（10-30 分钟，可能找不到）
4. 下载 .srt 拖进 IINA
5. 时间轴可能不对，手动微调

**本产品用户旅程**：
1. 打开视频
2. **~11 秒后**第一行字幕出现（自动生成 + 翻译 + 双语显示）
3. 全程播放，字幕持续追加生成

**这是数十倍体验差距**（实测：22 分钟视频从 10 分钟 → 11.8 秒首字幕，turbo 流水线总耗时 2.3 分钟，见 §7.6）。

### 3.3 技术架构差异

```
IINA:    Swift App ──→ libmpv ──→ 视频解码渲染
                              ↑
                              手动加载 .srt 文件

本产品:  Swift App ──→ libmpv ──→ 视频解码渲染
                              ↑
                              .srt 文件
                              ↑
         AISubtitleService ────┘（M3 用 mtime 轮询触发 sub-add/sub-reload；M5 换 FSEventStream）
              │
              ├─→ ffmpeg 切片（AudioSplitter，自己 ffprobe 取时长）
              ├─→ whisper-cli (Metal + GGML) × 段级并发 1（实证回退，原计划 3）
              ├─→ TranslationProvider（V1: DeepSeek；M5+: MiniMax/NLLB/luluk Cloud/...）
              └─→ srt 拼接 + 增量写入（SRTMerger）
```

### 3.4 法律 / 商业差异

| 维度 | IINA | 本产品 |
|------|------|--------|
| License | GPL-3 | **GPL-3（前端必须）+ 闭源后端** |
| 商业化 | 完全免费 | **付费 API 套餐（V2）** |
| 分发 | 官网 / GitHub | **官网下载（不上 App Store，GPL 与 App Store 冲突）** |
| 更新 | 自己的 Sparkle | **自建 Sparkle appcast.xml** |

---

## 4. V1 功能清单

### 4.1 必需（must-have，V1 不能少）

- [ ] **AI 字幕生成**：whisper.cpp + **large-v3-turbo（默认）/ large-v3（高质量选项）**
- [ ] **多语言互译（V1 简化版）**：英/日/俄/韩/西 ↔ 中文（共 5 个语对）
  - V2 再考虑两两互转（15 语对，需要更多 prompt 工程）
  - 用户在 UI 里选源语言（包含"自动"），目标语言固定中文（V1）
- [ ] **AI 翻译**：三档可切（见 §6） · V1 仅 DeepSeek 上线，luluk Cloud / OpenAI / NLLB 走 M5
- [ ] **源语言选择**：UI 提供下拉（自动 / 6 种），默认"自动"，用户可手动指定
- [ ] **流水线模式**：每段转写完成立即翻译，文件增量写入
- [ ] **磁盘 watch + 自动重载**：FSEventStream 监听 SRT 改动，自动调 `mpv sub-reload`。**默认开**，UI 设置项「字幕变更时自动刷新」可关（M3 用 mtime 轮询临时实现，M5 换 FSEventStream）
- [ ] **幻觉清理**：基于原型 `pipeline/sanitize.py`，扩展模式覆盖
- [ ] **whisper 模型管理**：首次启动**应用内一键下载**（默认 turbo ~1.5GB；large-v3 + CoreML 是可选增强 ~4GB）—— M5 实装真实下载，M2-M4 仅做存在性检查
- [ ] **API key 配置**：用户填自己的 DeepSeek/MiniMax key（V1 仅 DeepSeek 真正可用）
- [ ] **本地翻译兜底**：**NLLB-200-distilled-600M**（零配置，质量稍差）—— M5 上线，V1 范围 placeholder
- [ ] **双语字幕**：可选开关，原文上译文下
- [ ] **字幕样式预设**：电影标准样式默认开
- [ ] **进度面板**：UI 显示「转写 X/N、首字延迟、token 消耗」
- [ ] **whisper VAD 默认开**（`--vad`），减少静音段幻觉

### 4.2 应有（should-have，V1 尽量有）

- [ ] **自定义翻译 prompt**：高级折叠区，预设 3-4 个（电影/纪录片/动画/学术）
- [ ] **术语表**：人名/地名对照（解决 whisper 把 "畑野" 听成 "ホンベイ" 这类问题）
- [ ] **段级失败重试**：批失败时拆成单行重译，避免 8 行连坐
- [ ] **whisper VAD 默认开**：减少幻觉源头（`--vad`）
- [ ] **字幕导出 SRT**

### 4.3 V2+（必须延后）

- 付费 API 套餐 + 设备指纹配额
- 学习者功能：生词标注、Anki 导出、逐句重译
- 字幕烧录到视频
- Windows / Linux 移植
- 更多翻译 provider（Claude、Gemini、通义）

---

## 5. 技术架构

### 5.1 模块划分（Swift 实现，参照原型 Python 结构）

```
luluk/  (fork from IINA)
├── AISubtitle/                          ← 全部 AI 字幕模块统一在此目录（M1-M4 实装位置）
│   ├── AISubtitleService.swift          ← 主调度 actor，参考原型 produce.py（M3）
│   ├── AudioSplitter.swift              ← ffmpeg 静音切片，参考 audio_split.py（M2）
│   ├── AudioSegment.swift               ← 切片输出数据结构（M2）
│   ├── WhisperRunner.swift              ← spawn whisper-cli + Metal/GGML，参考 transcribe.py（M2）
│   ├── WhisperProcessPool.swift         ← 全局 5 进程上限的进程槽池（M2）
│   ├── TranscriptionResult.swift        ← whisper 输出数据结构（M2）
│   ├── TranslationProvider.swift        ← 协议 + 公共配置（参考 §15）（M3）
│   ├── Providers/
│   │   ├── DeepSeekProvider.swift       ← OpenAI 兼容，用户自填 key  ✅ V1（M3）
│   │   ├── MiniMaxProvider.swift        ← M5
│   │   ├── OpenAIProvider.swift         ← M5
│   │   ├── CustomProvider.swift         ← M5
│   │   ├── LulukCloudProvider.swift     ← M5
│   │   └── NLLBLocalProvider.swift      ← M5
│   ├── Sanitizer.swift                  ← 幻觉清理，参考 sanitize.py（M1）
│   ├── SRTMerger.swift                  ← 偏移合并 + 双语 actor（M1）
│   ├── SrtLine.swift                    ← SRT 行数据结构（M1）
│   ├── Language.swift                   ← 6 语种枚举 + LLM prompt 名（M1）
│   ├── SubtitleFileWatcher.swift        ← M3 用 mtime 轮询；M5 / V2 换 FSEventStream
│   ├── PipelineProgress.swift           ← UI 订阅的进度数据结构（M3）
│   ├── SubtitleError.swift              ← 4 级错误分类（M3）
│   ├── ModelDownloader.swift            ← M2 仅做存在性检查；M5 实装真实下载
│   └── AIKeychain.swift                 ← Security framework 封装存 API key（M4）
├── PrefAISubtitleViewController.swift   ← Provider 选择 UI · 程序化构造无 xib（M4）
├── AISubtitleProgressViewController.swift  ← OSD 风格进度面板（M4）
└── LulukCloudAuth.swift                 ← luluk 用户登录/订阅状态查询 ⏳ M5
```

### 5.2 字幕生成流水线（核心算法）

```
[视频打开] → 检测无字幕 → 触发 AISubtitleService
                                  ↓
                        ffmpeg silencedetect 找静音点
                                  ↓
                        切成 ~45s 片段（在静音处对齐）
                                  ↓
              ┌───────────────────┼───────────────────┐
        whisper 段0           whisper 段1         whisper 段2  (并发 3)
              ↓                   ↓                   ↓
        on_done 回调          on_done 回调        on_done 回调
              ↓                   ↓                   ↓
        Sanitizer 过滤幻觉   Sanitizer            Sanitizer
              ↓                   ↓                   ↓
        TranslationProvider  TranslationProvider  TranslationProvider
              ↓                   ↓                   ↓
              └───────────────────┼───────────────────┘
                                  ↓
                            srt 增量合并
                                  ↓
                        写视频同目录 .zh.srt / .bilingual.srt
                                  ↓
                        SubtitleFileWatcher（M3: mtime 轮询；M5: FSEventStream）
                                  ↓
                        触发 mpv sub-add / sub-reload
                                  ↓
                            用户屏幕字幕更新
```

### 5.3 关键技术点

#### whisper.cpp 集成
- **不打包**到 App，首次启动引导下载到 `~/Library/Application Support/<品牌>/bin/whisper-cli`
- **默认 `large-v3-turbo`**（1.5GB，纯 GGML+Metal 即可，**不需要 CoreML**）
- 实测 M4 上 turbo + GGML 模式比 large-v3 + CoreML 还快 6.7×
- 可降级到 `medium-turbo` 或 `tiny`（用户 Mac 弱时）
- 启用 `--vad` 减少静音段幻觉
- **段级并发实测回退到 1**（原计划 3，M3 实证 3 并发与 mpv 同时抢 Metal GPU 触发音频破音；全局 5 进程上限通过 `WhisperProcessPool` 实施，多视频共享）

> **决策依据**：原型实测 large-v3-turbo 处理 22.8 分钟视频仅需 2.3 分钟（首字幕 11.8s）；
> 而 large-v3 + CoreML 需要 15 分钟（首字幕 33s）。turbo 在专有名词识别上甚至更稳定（"畑野" large-v3 听成"ホンベイ"，turbo 听对）。

#### 翻译批次设计
- batch_size = 8 行
- 上下文 window = 前 3 行（不翻译，仅参考）
- system prompt 显式指定语言名（"简体中文"，**不要传 ISO 码 "zh"**）
- 输出语言验证：CJK 字符比例 < 15% 触发重试
- 单批 JSON 解析失败 → 拆成单行重试（避免连坐）

#### 文件 watch
- M3 实装：500ms mtime 轮询（CPU 0%，规避 atomic-rename 边界 case）
- `.zh.srt` 出现 / mtime 变 → 调 `PlayerCore.loadExternalSubFile(url)`，IINA 内部按 subTracks 已含与否走 sub-add 或 sub-reload
- M5 / V2 切换为 FSEventStream（性能优化，行为保持等价）

---

## 6. 翻译 Provider 体系

luluk 把翻译能力抽象为统一的 **TranslationProvider**，三类共存（**详见 §15 商业架构**）：

| 类别 | Provider | 面向用户 | 质量 | 速度 | 用户操作 | 成本 | V1 状态 |
|------|---------|---------|------|------|---------|------|---------|
| **luluk Cloud** | LulukCloudProvider（接 api.luluk.xyz）| 普通观众首选 | 高（含我们调优 prompt + 缓存）| 快 | 注册 + 订阅 | 月/年/按量套餐 | ⏳ M5 |
| **用户自带 key** | DeepSeek / MiniMax / OpenAI / Custom | 极客 | 高 | DeepSeek ~50s/200行 | 填 API key | 自付上游 ¥0.001-0.003/分钟 | ✅ DeepSeek M3；其它 ⏳ M5 |
| **本地兜底** | NLLBLocalProvider（distilled-600M）| 全员零配置 / 离线 | 中 | M4 ~120s/200行 | 无 | 免费 | ⏳ M5 |

**长期为什么要本地 NLLB**：目标用户是普通观众，**长期目标是默认零配置可用**，否则用户在配置页就流失。NLLB-200-distilled-600M 翻译质量虽然不如 DeepSeek，但"看懂剧情"够用，且 200 种语言互译开箱即用。luluk Cloud 试用余额耗尽后也回落到 NLLB（避免硬阻塞）。

> **V1 实情**：上面三档里只有"用户自带 key → DeepSeek"端到端可用。luluk Cloud 后端、NLLB 本地 Python helper、其它在线 provider 均为 M5 工作。"零配置"承诺在 M5 之前不成立。

**支持语言**（V1 必须）：
- 英语（en） · 日语（ja） · 中文（zh）· 俄语（ru）· 韩语（ko）· 西班牙语（es）
- 三类 Provider 全覆盖这 6 种
- prompt 模板：`LANG_NAMES` dict 已为每种加显式名（避免 ISO 码漂移）

---

## 7. 工程注意事项（基于原型验证 finding）

### 7.1 Whisper 已知幻觉模式
原型实测发现至少**四**类幻觉，**生产必须处理**：

1. **重复字符**：`はっはっはっ...`（持续 30 秒）
2. **重复短模式**：`あっはぁっはぁっ...`（中间夹杂浊音/促音变体）
3. **长时长 + 高频结尾词**：`おやすみなさい` 持续 30 秒（训练数据偏置；turbo 也有此 bug）
4. **SDH 非言语标注**：`*sigh*`、`[music]`、`(laughs)` 等（whisper 训练数据混了 SDH 风格字幕）

**解决**：参考 `pipeline/sanitize.py`，分类处理：
- 1/2 类 → 替换为简短中文（"哈哈哈"、"啊~"），跳过翻译
- 3 类 → 替换为"（无对白）"
- 4 类 → 译文置空，最终 SRT 跳过该行（重排 idx）

### 7.2 LLM JSON 输出失败的兜底
DeepSeek/MiniMax 偶发返回不完整 JSON（`Unterminated string`）。**生产必须**：
- 正则抓首个 `{...}` 兜底解析
- 整批失败时**自动拆成单行重译**
- 单行也失败 → 标记 `[翻译失败]` 让 UI 提示用户重试

### 7.2b 段内必须再分批，不能整段一次发 LLM
原型实测：whisper 一段可能含 30-50 行字幕，整段一次发 DeepSeek 会偶发**返回 JSON 漏 key**（10+ 行变 [翻译失败]），尤其在英文长讲座类视频。

**生产必须**：
- 每段内按 `batch_size=8` 行再分批
- 用上下文 window（前 3 行作为 context，不翻译）保持连贯
- 漏行检测：返回 dict keys 缺少输入行时自动重试或单行重译

### 7.3 LLM 输出语言漂移
`target_lang` 变量传 `"zh"`（ISO 码）会偶发被 LLM 误解读为英文输出。**必须**：
- system prompt 用显式名："简体中文 (Simplified Chinese)"
- 客户端做 CJK 字符占比检查（< 15% 触发重试）

### 7.3b 翻译 prompt 必须**禁止音译保留 + 精确占位**
默认 prompt 里"人名首次出现可保留原文"会让 DeepSeek 把任何识别不出的外来词都音译保留（如 whisper 误识 `マンジェル` → DeepSeek 输出 "Manger" 或 "曼杰尔"）。

**正确做法**：
- **禁止任何音译/英文/拼音保留**，仅当前后有明确称呼（「さん」「ちゃん」等）才保留人名原文
- whisper 误识的词（**3 字符以上不存在的片假名外来词**）输出「（？）」占位
- **明确列出例外**：单字符回应（"ん"/"あ"/"えー"等）是真实对话语气词，必须正常翻译为"嗯"/"啊"等，避免被误标占位

实测：原型 V1 prompt 已包含此规则，能精准定位 whisper 幻觉到 4 行占位（vs 早期版本 20 行误占位）。

### 7.4 自动语言检测可能严重误判 ⚠️
原型实测：test.mp4 开头是 *sigh* + 一句日语听起来"像英语"，whisper-cli 默认只采样**前 30 秒**做语言识别，把整片误判为英文 → **整片转写成虚构英语**（看起来通顺，跟实际对白毫无关系）。

**生产必须**：
- UI 提供**手动选择源语言**的下拉（不能只靠自动）
- 进阶：采样视频中段（30%/50%/70% 各 10 秒）综合判断
- 进阶：第一段转写完后检查置信度，过低 → 回头重检 / 提示用户

### 7.5 MiniMax 国内站特性
- base_url：`https://api.minimaxi.com/v1`（带 i，不是国际站 .io）
- 不支持 OpenAI 的 `response_format={"type": "json_object"}`
- 当前 token plan 通常只能用 `MiniMax-M2`（推理模型）
- M2 输出含 `<think>...</think>` 块，**必须 strip 后再 parse JSON**

### 7.6 性能基线（M4 + 24GB）

| 视频 | 时长 | 模型 | 总耗时 | 倍速 | 首字幕 | 成本 |
|------|------|------|--------|------|--------|------|
| 雷曼传奇（英）| 7.8 min | large-v3 串行 | 12 min | 0.65× | 17s | - |
| 5月1日（日）| 13.5 min | large-v3 并发 | 9 min | 1.5× | 33s | - |
| 波多野（日）| 22.8 min | large-v3 + CoreML 流水线 | 15 min | 1.5× | 33s | ¥0.04 |
| 波多野（日）| 22.8 min | **turbo 流水线** | 2.3 min | 9.99× | 11.8s | ¥0.04 |
| test（日）| 14.25 min | turbo 流水线 | 1.45 min | 9.83× | 11.4s | ¥0.025 |
| **2049（英）**| **30.2 min** | **turbo 流水线** | **4.5 min** | **11.7×** | **11.5s** | **¥0.10** |

**V1 baseline（M4 + 24GB + turbo + GGML+Metal · 本地视频 · 已配置 DeepSeek key）**：
- 实时倍速 **10×**（与视频长度无关）
- 首字幕延迟 **~11 秒**（与视频长度无关）
- API 成本 ~ **¥0.003 / 分钟视频**（DeepSeek 价位）

> 上述指标仅在"本地非网络流视频 + DeepSeek key 已配置"前提下成立。M5 上线 NLLB 本地兜底前，未配置 key 时流水线会立刻失败并提示用户去设置面板。

---

## 8. 商业模式与法律

> 商业架构、Provider 体系、GPL 防御、套餐设计、分阶段实施详见 **§15 商业架构与代码分离**。本节仅列法律/分发要点。

### 8.1 GPL-3 合规要点
- **luluk 前端**：fork IINA → GPL-3 源码必须公开（github.com/<owner>/luluk）
- **luluk 后端服务**（api.luluk.xyz）：完全独立的 HTTPS 服务，闭源、收费，**不构成 GPL 传染**（业界 Open Core 通用做法）
- About 页面致谢 IINA（License 要求）
- 二进制下载页提供源码链接（GPL 履行义务）

### 8.2 V1 不立刻做付费
- V1：用户自带 key（DeepSeek/MiniMax/OpenAI/Custom）+ 本地 NLLB 兜底
- V1.5：luluk Cloud MVP 上线，开始订阅
- 详见 §15.7 分阶段实施

### 8.3 分发与签名
- 注册 Apple Developer Program（$99/年，**必须**）
- 公证（notarization），否则 macOS 用户双击打不开
- 自建 Sparkle appcast.xml（GitHub Releases 即可）
- **App Store 不上**（GPL 与 App Store"使用限制"条款冲突，VLC 历史教训）

---

## 9. 品牌化（部分已决，剩余待办）

### 已决（全部）

| 项 | 决策 |
|----|------|
| **产品名** | **luluk** |
| **Bundle ID** | **`xyz.luluk.app`**（reverse DNS，对应 luluk.xyz 域名） |
| **域名（主站）** | **luluk.xyz** |
| **域名（后端）** | api.luluk.xyz |
| **域名（用户中心）** | dashboard.luluk.xyz |
| **GitHub 仓库** | **github.com/ayaoplus/luluk**（fork 即公开，GPL-3） |
| **Logo** | `assets/logo.png`（1254×1254, RGB 全画布版，commit `2bc2b01`）已就位 |
| **主色** | **绿色**（深翠绿背景 + 浅绿渐变前景，从 logo.png 取色，建议主色 ≈ `#2A6B4A`，浅色 ≈ `#A8D9B6`，最终 hex 待 fork 时设计师精确取色）|

### 启动 fork 前还要做的（纯执行项）

- [ ] 从 `assets/logo.png` 生成 .icns 全尺寸（macOS 应用图标需要 16/32/64/128/256/512/1024 + @2x 视网膜版）
- [ ] 提取主色 hex 精确值（用 Sketch/Figma 取色或 macOS DigitalColor Meter）
- [ ] 注册 Apple Developer Program（$99/年）
- [ ] 解析 luluk.xyz 到主页 + 配置 api / dashboard 子域名 DNS
- [ ] 创建 GitHub 仓库 ayaoplus/luluk（fork 时同步）

### 替换 IINA 痕迹的检查清单（fork 后）
- [ ] `Configs/*.plist` 里的 SUFeedURL（更新源 URL）
- [ ] `Configs/*.plist` 里的 CFBundleIdentifier
- [ ] `Configs/*.plist` 里的 CFBundleName / DisplayName
- [ ] `Assets.xcassets/AppIcon.appiconset/` 全套图标
- [ ] `iina/Assets.xcassets/` 其他品牌图
- [ ] About 窗口（Credits.rtf / Contribution.rtf 保留 IINA 致谢）
- [ ] 移除 IINA 的 crash report endpoint
- [ ] `dsa_pub.pem` 替换为自己的 Sparkle 签名公钥
- [ ] 关掉/替换 IINA 的统计上报（如果有）
- [ ] Crowdin 配置（先不做翻译）
- [ ] `iina-cli/`（命令行工具）的 binary name

---

## 10. 路线图

### V1（fork 后 8-12 周）
- W1-2：fork + 换皮 + 编译跑通
- W3-4：移植 pipeline 到 Swift（whisper runner + provider 适配）
- W5-6：FSEventStream watch + 自动重载
- W7-8：API key 配置 UI + 模型管理 UI
- W9-10：进度面板 + 字幕样式预设 + 双语
- W11：内测，处理实际视频中的边缘 case
- W12：公证 + 首发

### V2（V1 后 4-6 周）
- 自家 API 后端（账号 / 配额 / 计费）
- 设备指纹（IOPlatformUUID 兜底）
- 学习者功能：术语表、生词标注

### V3+（不锁时间）
- 字幕烧录到视频导出
- Windows / Linux
- iOS / iPadOS
- 与 PlayCover 等运行时的兼容

---

## 11. 决策清单

### ✅ 已决（2026-05-02）

| 项 | 决策 |
|---|---|
| 产品名 | **luluk** |
| 目标语言 | **简化版 5 语对**：英/日/俄/韩/西 ↔ 中文（V2 再考虑两两互转）|
| 首字幕 UX | **自动 watch 默认开**（M3 实装：500ms mtime 轮询调 `loadExternalSubFile`；M5 换 FSEventStream），UI 设置项可关 |
| whisper 默认模型 | **large-v3-turbo**（V1 默认），UI 提供 large-v3 高质量选项 |
| NLLB 模型大小 | **distilled-600M**（速度优先） |
| helper 分发 | **首次启动应用内一键下载**（不单独 .pkg） |
| whisper VAD | **默认开**（`--vad`） |
| 翻译批次大小 | **8 行**（原型实测稳定） |
| GitHub 公开时机 | **fork 即公开**（GPL-3 必然要求，越早越透明）|
| Beta EULA | **不需要**（fork 即 GPL-3 开源，License 已经规定权利义务）|
| 域名 | **luluk.xyz**（已注册）+ api.luluk.xyz（后端）+ dashboard.luluk.xyz（用户中心）|
| Bundle ID | **`xyz.luluk.app`**（reverse DNS 规范，对应 luluk.xyz 域名）|
| GitHub 仓库 | **github.com/ayaoplus/luluk** |
| Logo | `assets/logo.png` 已就位（1254×1254, RGB 全画布版，commit `2bc2b01`）|
| 主色 | 绿色（深翠绿主 ~RGB(7,88,68) + 浅绿辅，从 logo 提取）|

### 🚀 启动状态：fork 已开始，阶段 2-3 完成，进入阶段 4（AI 字幕模块）

执行项进度（见 §9）：
- [x] ~~从 logo.png 生成 macOS .icns 全尺寸~~——`scripts/generate_icons.sh` + 4 套 AppIcon variant（commit `04a5f0d`/`5805eea`/`2bc2b01`）
- [ ] 取主色精确 hex（暂用 `#075844` 深翠绿，发版前由设计师精校）
- [ ] 注册 Apple Developer Program（用户私事，发版前必须）
- [ ] 配置 luluk.xyz DNS（主站 + 子域名）
- [x] ~~创建 ayaoplus/luluk GitHub 仓库~~——已创建 + push（首个 commit `d6aebab`，当前 HEAD 见 `git log`）

V2+ 才需要的执行项：
- [ ] Sparkle EDDSA 签名密钥生成 + 填回 `Info.plist:SUPublicEDKey`（V1 上线前）
- [ ] 公证（Notarization）流程 + 自动化脚本

---

## 12. 原型代码资产（可参考迁移）

```
ai-subtitle-prototype/
├── pipeline/audio_split.py     ← Swift 移植：AudioSplitter
├── pipeline/transcribe.py      ← Swift 移植：WhisperRunner
├── pipeline/translate_api.py   ← Swift 移植：DeepSeek/MiniMaxProvider
├── pipeline/translate_local.py ← 保留为 helper 子进程（NLLB 走 Python）
├── pipeline/sanitize.py        ← Swift 移植：Sanitizer（核心算法直接翻）
├── pipeline/srt_merge.py       ← Swift 移植：SRTMerger
├── produce.py                  ← Swift 主调度参考实现
└── docs/SPEC.md                ← （本文档）
```

**Swift 移植难度排序**：
- 易：sanitize.py（纯字符串/正则）→ Sanitizer.swift
- 易：srt_merge.py（pysrt 替换为 Swift SRT 库）→ SRTMerger.swift
- 中：audio_split.py（spawn ffmpeg 解析 stderr）→ AudioSplitter.swift
- 中：transcribe.py（spawn whisper-cli + 并发回调）→ WhisperRunner.swift
- 中：translate_api.py（URLSession + JSON）→ Provider 适配
- **难（保留 Python helper）**：translate_local.py（torch + transformers 不能直接 Swift，建议 PyInstaller 打成独立 binary 调用）

---

## 13. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| App Store 不可上架 | 100% | 高 | 接受，官网分发 |
| GPL 用户 fork 自建后端白嫖 | 中 | 中 | 后端独立闭源 + 鉴权 |
| 苹果未来限制本地 LLM | 低 | 中 | 保留远程 API 路径 |
| whisper 大模型尺寸增长 | 中 | 中 | 模型管理 UI 支持多版本切换 |
| 本地 helper 升级困难 | 高 | 中 | 把 helper 也作为 Sparkle 更新单元 |
| DeepSeek/MiniMax 涨价 | 中 | 低 | 用户用自己的 key 与我们无关 |
| 用户视频含敏感内容被 API 拒译 | 中 | 中 | 失败自动 fallback 到本地 NLLB |

---

## 14. 已废弃的方案（避免重复讨论）

- ❌ ~~Plan A：纯 IINA 插件路线~~ — 用户决定走商业产品，B 路线更直接
- ❌ ~~实时字幕（边播边转写）~~ — V1 砍掉，技术复杂度 ×10，用户不刚需
- ❌ ~~支持 Intel Mac~~ — large-v3 / turbo 在 Intel 不可用
- ❌ ~~MVP 就做付费配额~~ — 用户自带 key 路线先跑通
- ❌ ~~传 ISO 码 "zh" 给 LLM~~ — 偶发输出英文，必须传 "简体中文"
- ❌ ~~num_beams=4 跑 NLLB~~ — 4 倍开销质量提升微弱，greedy 即可
- ❌ ~~默认 whisper large-v3 + CoreML~~ — turbo 比 large-v3+CoreML 还快 6.7×，CoreML 不必要
- ❌ ~~段内整段一次性翻译~~ — 段内 30+ 行容易丢 JSON key，必须 batch_size=8 再分批
- ❌ ~~校正 prompt（让 LLM 重写"听错"原文）~~ — 实测同义改写多于真校正，+40% 成本不划算
- ❌ ~~用 whisper translate 模式中转英文~~ — 双重翻译损失大，直接 X→目标语言更好
- ❌ ~~Beta EULA~~ — fork 即 GPL-3 开源，License 已规定权利义务，不需要 EULA
- ❌ ~~人名首次出现保留原文（旧 prompt 第 4 条）~~ — 触发 DeepSeek 把所有不识别外来词音译保留为英文，必须收紧到"仅当前后有さん/ちゃん等称呼"

---

## 15. 商业架构与代码分离（核心策略）

luluk 采用业界成熟的 **Open Core 模式**——前端 GPL-3 开源（任何人可拿、可改、可商用），后端服务闭源（按订阅/用量收费）。**两类用户在同一前端用同一份代码，完全无割裂**。

参考案例：VLC、OBS Studio、Signal、Sentry、Mattermost、GitLab CE/EE。

### 15.1 两类用户、一个前端

```
┌─ 普通观众（傻瓜化路径）───────────────┐
│ 下载 luluk → 引导注册 luluk Cloud    │
│ → 选订阅（¥9.9/月含 X 万 token）     │
│ → 立即可用                           │
└──────────────────────────────────────┘
            ↑ 同一份 luluk App
            ↓ 用户在设置里切换 Provider
┌─ 极客（DIY 路径）─────────────────────┐
│ 下载 luluk → 设置 → "我有 API Key"   │
│ → 填 DeepSeek / OpenAI / 自定义      │
│ → 立即可用                           │
└──────────────────────────────────────┘

兜底（任何用户）：本地 NLLB，无需联网，免费
```

### 15.2 设置面板布局

```
设置 → 翻译 → 翻译服务：

  ○ luluk Cloud（推荐 · 开箱即用）             ← 普通用户首选 · ⏳ M5
    状态：未登录    [登录/注册]
    套餐：¥9.9/月 · ¥99/年 · 按量 ¥10/100 万 token
    [选择套餐]
    本月剩余：— / —

  ○ 我有 API Key（DIY）                        ← 极客首选 · ✅ V1 唯一可用档位
    □ DeepSeek      sk-_______________            ← V1 已上
    □ MiniMax       _________________            ← M5
    □ OpenAI        sk-_______________            ← M5
    □ 自定义 Endpoint  https://_______           ← M5
    □ 自定义 Model     gpt-4o-mini                ← M5

  ○ 本地翻译（免费 · 无需联网）                ← 全员兜底 · ⏳ M5
    NLLB-200-distilled-600M（M5 起一键下载 600MB）
```

### 15.3 代码分离边界

#### 前端开源部分（GPL-3，github.com/<owner>/luluk）

```
luluk/  (前端 macOS 应用，fork from IINA)
├── TranslationProvider 协议                   ✓ 开源
├── 内置 Providers:
│   ├── DeepSeekProvider                       ✓ 开源
│   ├── MiniMaxProvider                        ✓ 开源
│   ├── OpenAIProvider                         ✓ 开源
│   ├── CustomProvider（任意 OpenAI 兼容）     ✓ 开源
│   ├── LulukCloudProvider                     ✓ 开源（仅是 OpenAI 兼容客户端，endpoint 写死）
│   └── NLLBLocalProvider                      ✓ 开源
├── luluk Cloud 登录/订阅 UI                   ✓ 开源
├── 用户级 API key 存储（Keychain）            ✓ 开源
└── 字幕生成流水线（含本地 sanitize）          ✓ 开源
```

#### 后端闭源部分（私有仓库，独立部署）

```
api.luluk.xyz
├── 用户系统（注册 / 登录 / 订阅）             ✗ 闭源
├── 鉴权（验证 luluk 用户 key）                ✗ 闭源
├── 计费引擎（按 token / 订阅）                ✗ 闭源
├── ⭐ Prompt 调优层（system prompt 模板）     ✗ 闭源（最值钱的资产）
├── ⭐ 缓存层（同片源命中复用）                ✗ 闭源
├── ⭐ Token 路由（动态选最便宜上游 provider）  ✗ 闭源
└── 转发到 DeepSeek / Anthropic / OpenAI 等    ✗ 闭源

dashboard.luluk.xyz
├── 用户中心（订阅状态 / 用量统计 / 发票）     ✗ 闭源
└── Stripe / 支付宝 / 微信支付集成             ✗ 闭源
```

### 15.4 GPL-3 防御层

**潜在担忧**：前端开源 → 别人 fork → 改 endpoint 自建后端薅 token 差价？

| 防御层 | 作用 |
|--------|------|
| **后端独立闭源** | 真正的护城河（prompt 调优、缓存、混合 routing）在后端，前端代码"看着完整"但不含商业核心 |
| **luluk 商标保留** | GPL 允许保留商标。fork 必须改名（不能叫 luluk）|
| **托管成本** | 别人要自建后端 + 谈上游商务 + 客服 + Apple 公证 + 持续运维 → 99% 没人愿意干 |
| **用户网络效应** | luluk 用户基数 + 口碑 + SEO，fork 没用户 |
| **持续迭代** | luluk 持续迭代 prompt 和缓存策略，fork 跟不上 |

**结论**：GPL 前端 + 闭源后端 + 商标 = **结构上无法被白嫖**。已被业界十年验证。

### 15.5 商业模型（赚什么钱）

luluk Cloud 的实际经济：

```
用户付 ¥9.9/月（含 100 万 token）
            ↓
后端实际成本：
  ├ 智能 routing（按语种/长度选最便宜上游）
  ├ 缓存（热门片源命中率高）
  └ 批量优惠（DeepSeek/Anthropic 大客户折扣）
            ↓
  实际上游成本 ¥3-5
            ↓
  毛利 50-70%
```

**对比直接转发**：如果只做"傻瓜的 DeepSeek 转发"，毛利接近 0。商业模型成立的关键在于 **prompt 调优 + 缓存 + 多 provider 混合 routing**，这三块都在后端闭源。

### 15.6 套餐设计（V2 启动时确定）

| 档位 | 价格 | 适用 |
|------|------|------|
| 免费试用 | 注册即送 X 万 token（约 30 分钟视频）| 体验 |
| 标准月度 | ¥9.9/月 含 100 万 token | 偶尔看剧 |
| 标准年度 | ¥99/年 含 1500 万 token | 重度用户（17% 优惠）|
| 按用量 | ¥10 / 100 万 token | 不规律使用 |
| 团队版（V3） | TBD | 字幕组、家庭账户 |

### 15.7 分阶段实施

| 阶段 | 前端工作 | 后端工作 |
|------|---------|---------|
| **V1（fork IINA 后 8-12 周）** | TranslationProvider 抽象 + 4 个内置（DeepSeek/MiniMax/OpenAI/Custom）+ NLLBLocalProvider + LulukCloudProvider 接口（先指向 mock 或临时指向 DeepSeek 试用） | **暂无**（V1 先验证产品 PMF） |
| **V1.5（V1 上线 + 用户验证后 4-6 周）** | LulukCloud 登录/注册 UI + 订阅状态查询 + 套餐选择 | MVP 后端：邮箱注册 + Stripe 订阅 + 鉴权 + 单一上游转发（DeepSeek）|
| **V2 (V1.5 + 4-6 周)** | 用量面板、套餐切换、剩余额度提示 | 缓存层 + 多 provider routing + token 计费精算 + 发票 |
| **V3** | 团队账号 / 学生折扣 / 家庭账户 | 企业 SSO / 发票 / API 开放 |

### 15.8 关键决策矩阵

| 决策 | V1 | V2+ |
|------|----|----|
| 前端是否包含 LulukCloudProvider 代码 | ✅ 包含（OpenAI 兼容客户端，开源无所谓）| 同 |
| 前端是否包含 luluk Cloud 注册/登录 UI | ⏳ V1 占位（mock auth），V1.5 真接入 | ✅ |
| 后端 prompt 模板是否开源 | ❌ 不开源（system prompt 在后端）| 同 |
| 缓存逻辑是否开源 | ❌ 不开源 | 同 |
| 计费/订阅逻辑是否开源 | ❌ 不开源 | 同 |
| 后端代码仓库 | 私有（GitHub Private 或 GitLab）| 同 |
| 域名分配 | **luluk.xyz**（主站）+ api.luluk.xyz（后端）+ dashboard.luluk.xyz（用户中心）| 同 |

---

**文档维护**：每次重大决策后更新 §11 决策清单 + §14 废弃方案。
