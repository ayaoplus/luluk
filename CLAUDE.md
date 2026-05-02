# CLAUDE.md · luluk 项目上下文

> 这是 luluk 项目的 Claude Code 项目级指令。每次 cc 在这个目录启动时自动加载。

---

## 项目快照

- **luluk** = AI 字幕 macOS 视频播放器
- **fork from**: [IINA](https://github.com/iina/iina)（GPL-3）
- **目标用户**：看冷门外语片的中文普通观众（不是开发者，不是字幕组）
- **核心承诺**：打开视频，**11 秒内**看到中文字幕，全程零配置
- **当前阶段**：项目目录已初始化，**等开始 fork 换皮工作**（参见 `docs/FORK_CHECKLIST.md`）

## 商业架构（一句话）

**Open Core 模式**：前端 GPL-3 开源（`github.com/ayaoplus/luluk`），后端 luluk Cloud（`api.luluk.xyz`）闭源，按订阅赚 token 差价。同一前端服务两类用户：

- **普通观众**：注册 luluk Cloud + 订阅
- **极客**：自带 DeepSeek/OpenAI/Custom API key

兜底：本地 NLLB-200-distilled-600M（无需联网，免费）

## 已锁定的关键决策

| 项 | 决策 |
|---|---|
| 域名 | luluk.xyz / api.luluk.xyz / dashboard.luluk.xyz |
| Bundle ID | `xyz.luluk.app` |
| GitHub | github.com/ayaoplus/luluk |
| Logo / 主色 | `assets/logo.png` / 绿色（深翠绿 + 浅绿）|
| ASR | whisper **large-v3-turbo**（默认）+ large-v3（可选）|
| 翻译 batch | 8 行 + 上下文 window 3 行 |
| 流水线 | 段级流水线（首字幕 11s）|
| 字幕重载 | FSEventStream 自动 watch（默认开）|
| 多语言 V1 | 5 语对：en/ja/ko/ru/es ↔ zh |
| EULA | 不需要（GPL-3 已规定）|
| App Store | 不上（GPL 与 App Store 条款冲突）|

## 关键文档（必读）

- **`docs/SPEC.md`** — V1 完整产品规格（700+ 行，单一可信源）
- **`docs/FORK_CHECKLIST.md`** — fork 第一周操作清单（具体到改哪些文件哪些行）

## 相关目录

```
~/development/
├── luluk/                       ← 当前项目（fork from IINA）
├── iina-develop/                ← IINA 原版（参考，对比改动用）
└── ai-subtitle-prototype/       ← Python 原型（已验证全流程）
                                  └─ 移植到 Swift 的参考实现
```

**不要**直接编辑 `iina-develop/`（那是参考），所有改动只在 `luluk/`。

## 原型已验证的关键事实（避免重新论证）

性能基线（M4 24GB + turbo + GGML+Metal）：
- **实时倍速 10×**（与视频长度关系不大）
- **首字幕延迟 ~11 秒**（与视频长度无关）
- **API 成本 ~¥0.003 / 分钟视频**（DeepSeek 价位）
- 翻译失败率近 0（在批 8 行 + 重试 + sanitize 的框架下）

已踩过的坑（详见 SPEC §7）：
1. whisper 幻觉（4 类：重复字符 / 短模式 / 长时长结尾词 / SDH 标注）→ `pipeline/sanitize.py` 已覆盖
2. LLM 输出语言漂移（必须传"简体中文"而非"zh"）
3. 自动语言检测可能误判（必须有手动选择）
4. 段内不能整段一次发 LLM（必须 batch_size=8 再分批）
5. prompt 不要让 LLM 保留外文音译（"人名首次出现保留原文"会触发误音译）

## 工作风格偏好

- 客观、犀利的反馈，不恭维
- 修改前先读文件理解
- 不主动重构未要求修改的代码
- 不添加多余注释
- 完成可验证修改单元后自动 git commit + push（已知"提交"= commit + push）
- 浏览器路由：anyreach（联网）/ gstack browse（QA 截图）

## 当前不要做的事

- ❌ 直接改 IINA 源码做大量改动（先按 FORK_CHECKLIST 阶段 1-3 跑通）
- ❌ 立刻动手实现 AI 字幕模块（先确认 fork 换皮成功 + 第一次 build 跑起来）
- ❌ 推 GitHub 远程（用户还没创建 ayaoplus/luluk 仓库）
- ❌ 改 LICENSE 文件（GPL-3 必须保留 IINA 致谢）

## 下次 cc 启动时建议先做

1. 读 `docs/SPEC.md`（如有不熟悉的地方）
2. 读 `docs/FORK_CHECKLIST.md`（确认下一个该做的步骤）
3. `git log --oneline -5` 看最近改动
4. 询问用户当前在哪一步、下一步要做什么
