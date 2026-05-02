<p align="center">
<img height="180" src="assets/logo.png">
</p>

<h1 align="center">luluk</h1>

<p align="center">AI 字幕播放器 · 打开视频 ~11 秒看到中文字幕 · 全程零配置</p>

---

## 简介

**luluk** 是一个为「看外语视频的普通观众」做的 AI 自动字幕 macOS 播放器。打开任何视频，luluk 自动调用 whisper 转写 + LLM 翻译，**约 11 秒后第一行中文字幕出现**，全程不需要找字幕、配字幕、调字幕。

基于 [IINA](https://iina.io) fork，遵循 GPL-3。

## 核心能力

- **AI 字幕生成**：whisper.cpp + large-v3-turbo + Metal 加速，M 系列 ~10× 实时
- **AI 翻译**：DeepSeek / OpenAI / 本地 NLLB / luluk Cloud（订阅制）任选
- **流水线模式**：转写一段就翻译一段，**首字幕延迟 ~11 秒**（与视频长度无关）
- **磁盘 watch 自动重载**：字幕生成进度全程无感更新
- **支持语言**（V1）：英 / 日 / 韩 / 俄 / 西 → 中文

## 三类使用方式

| 用户类型 | 翻译档位 | 操作 |
|---------|--------|------|
| 普通观众 | luluk Cloud（推荐）| 注册账号 + 订阅 |
| 极客 | 自带 API Key | 填 DeepSeek / OpenAI / 自定义 endpoint |
| 离线 | 本地 NLLB | 零配置免费 |

详见 [docs/SPEC.md](docs/SPEC.md)。

## 系统要求

- macOS 11.0+（Apple Silicon 推荐 M 系列）
- Intel Mac 不支持（whisper large-v3-turbo 需要 Metal 加速）

## License

luluk 是 [IINA](https://github.com/iina/iina) 的 GPL-3 fork，源码公开于此仓库。
luluk Cloud 后端服务（api.luluk.xyz）是独立闭源服务，与本仓库无关。

## 致谢

- [IINA](https://iina.io) — 强大的 macOS 视频播放器，本项目基于其 fork
- [mpv](https://mpv.io) — IINA 的播放内核
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — OpenAI Whisper 的 C++ 高性能实现

详见 [README_IINA_ORIGINAL.md](README_IINA_ORIGINAL.md) 了解 IINA 原始项目。
