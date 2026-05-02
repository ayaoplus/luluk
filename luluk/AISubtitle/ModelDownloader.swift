//
//  ModelDownloader.swift
//  luluk
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  whisper-cli binary + GGML 模型 + Silero VAD 模型的本地路径管理。
//  对应 docs/AI_SUBTITLE_DESIGN.md §2.3 + SPEC §5.3。
//
//  M2 范围：只实现 binary/model **存在性检查**（ensureWhisperReady）。
//  M5 范围：补全真实下载 + 进度上报 + 模型切换。
//

import Foundation

/// V1 支持的 whisper 模型枚举。
///
/// `rawValue` 同时是 HuggingFace 上的模型文件中段名：
/// `ggml-<rawValue>.bin`（large-v3-turbo → `ggml-large-v3-turbo.bin`）。
enum WhisperModel: String, CaseIterable, Sendable, Codable {
    /// 默认。SPEC §5.3 锁定：M4 24GB 实测实时 10×，首字幕 11s。
    case largeV3Turbo = "large-v3-turbo"   // ~1.62 GB

    /// 高质量选项。专有名词偶尔比 turbo 更稳，但 6.7× 更慢。
    case largeV3 = "large-v3"               // ~3.10 GB

    /// 弱机降级。
    case mediumTurbo = "medium-turbo"       // ~1.0 GB

    /// 极弱机或测试。
    case tiny = "tiny"                      // ~75 MB

    /// 在 `~/Library/Application Support/luluk/models/` 下的文件名。
    var modelFileName: String { "ggml-\(rawValue).bin" }
}

/// whisper.cpp 跑起来需要的全部本地路径。
///
/// 由 ``ModelDownloader/ensureWhisperReady()`` 返回，
/// `WhisperRunner` 持有它去 spawn 进程。
struct WhisperPaths: Sendable, Equatable {
    /// `whisper-cli` 可执行文件。
    /// 优先 `~/Library/Application Support/luluk/bin/whisper-cli`，
    /// 找不到则 fallback `PATH`（开发期友好，prod 不应触发）。
    let binary: URL

    /// GGML whisper 模型，例如 `ggml-large-v3-turbo.bin`。
    let model: URL

    /// Silero VAD 模型。`whisper-cli --vad` 必需的额外依赖
    /// （whisper-cli 自身不内嵌 VAD，需 `-vm <path>`）。
    let vadModel: URL
}

/// M5 范围：下载进度事件。M2 不发射，留个壳。
struct DownloadProgress: Sendable, Equatable {
    let totalBytes: Int64
    let downloadedBytes: Int64
    let fileName: String
}

/// 模型下载错误。M2 实际只会抛 `binaryMissing` / `modelMissing` / `vadModelMissing`。
enum ModelDownloadError: Error, Equatable {
    /// whisper-cli 既不在应用支持目录，也不在 `PATH` 上。
    case binaryMissing(searchedPaths: [String])

    /// `~/Library/Application Support/luluk/models/<modelFileName>` 不存在。
    case modelMissing(expectedPath: String, model: WhisperModel)

    /// `~/Library/Application Support/luluk/models/ggml-silero-v5.1.2.bin` 不存在。
    case vadModelMissing(expectedPath: String)

    /// M5 范围。M2 不会抛。
    case downloadFailed(URL, underlying: String)

    /// M5 范围。
    case checksumMismatch(URL)
}

/// whisper 二进制 + 模型的本地路径管理器。
///
/// M2 阶段：只做存在性检查 + 路径构造。下载、进度、SHA 校验、模型切换是 M5 的事。
actor ModelDownloader {

    /// V1 锁定的 VAD 模型文件名。SPEC §4.1 默认开 VAD。
    /// 来源：HuggingFace `ggml-org/whisper-vad`。
    static let vadModelFileName = "ggml-silero-v5.1.2.bin"

    /// 用户当前选用的模型。M5 才支持运行时切换，M2 固定走 SPEC 默认。
    private(set) var currentModel: WhisperModel

    init(model: WhisperModel = .largeV3Turbo) {
        self.currentModel = model
    }

    // MARK: - 公开接口

    /// 检查 whisper 跑起来需要的所有文件是否就绪，返回它们的绝对路径。
    ///
    /// M2 行为：
    /// - binary 优先 `~/Library/Application Support/luluk/bin/whisper-cli`，
    ///   找不到则 fallback `PATH`（`/opt/homebrew/bin/whisper-cli` 等开发常见位置）。
    /// - model & VAD 必须在 `~/Library/Application Support/luluk/models/` 下，
    ///   不存在直接 throw（M2 不下载）。
    ///
    /// M5 行为（待实现）：缺文件时自动从 HuggingFace 下载，进度通过 ``progressStream`` 上报。
    func ensureWhisperReady() async throws -> WhisperPaths {
        let binary = try locateBinary()
        let model = try locateModel(currentModel)
        let vad = try locateVADModel()
        return WhisperPaths(binary: binary, model: model, vadModel: vad)
    }

    /// M5 范围：切换模型 + 必要时触发下载。M2 stub。
    func switchModel(to newModel: WhisperModel) async throws {
        // M2：仅记录用户选择，不做下载。下次 ensureWhisperReady 会检查新模型文件。
        self.currentModel = newModel
    }

    /// M5 范围：下载进度流。M2 永远 finish 一个空流。
    nonisolated var progressStream: AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    // MARK: - 路径常量（暴露给测试）

    /// `~/Library/Application Support/luluk/`
    static var appSupportRoot: URL {
        let fm = FileManager.default
        // 取用户域的 Application Support；这个目录系统保证存在。
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("luluk", isDirectory: true)
    }

    /// `~/Library/Application Support/luluk/bin/`
    static var binDirectory: URL {
        appSupportRoot.appendingPathComponent("bin", isDirectory: true)
    }

    /// `~/Library/Application Support/luluk/models/`
    static var modelsDirectory: URL {
        appSupportRoot.appendingPathComponent("models", isDirectory: true)
    }

    // MARK: - 内部：定位 binary / model

    /// 应用目录优先；找不到去 PATH 上找；最后兜底常见 brew 路径。
    /// 三层 fallback 是因为 macOS GUI 应用启动时的 PATH 不含 /opt/homebrew/bin。
    private func locateBinary() throws -> URL {
        var searched: [String] = []

        let appBinary = ModelDownloader.binDirectory.appendingPathComponent("whisper-cli")
        searched.append(appBinary.path)
        if FileManager.default.isExecutableFile(atPath: appBinary.path) {
            return appBinary
        }

        if let pathBinary = Self.findInPATH("whisper-cli") {
            return URL(fileURLWithPath: pathBinary)
        }
        searched.append("$PATH")

        // brew 常见路径兜底（GUI 启动 PATH 不含 /opt/homebrew/bin）
        let fallbacks = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        for f in fallbacks {
            searched.append(f)
            if FileManager.default.isExecutableFile(atPath: f) {
                return URL(fileURLWithPath: f)
            }
        }

        throw ModelDownloadError.binaryMissing(searchedPaths: searched)
    }

    /// 模型必须在应用目录下。M2 不 fallback 到任意路径（避免用户混乱）。
    private func locateModel(_ model: WhisperModel) throws -> URL {
        let url = ModelDownloader.modelsDirectory.appendingPathComponent(model.modelFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelDownloadError.modelMissing(expectedPath: url.path, model: model)
        }
        return url
    }

    private func locateVADModel() throws -> URL {
        let url = ModelDownloader.modelsDirectory.appendingPathComponent(Self.vadModelFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelDownloadError.vadModelMissing(expectedPath: url.path)
        }
        return url
    }

    /// 在 `PATH` 环境变量列出的目录里找可执行文件。
    /// 不依赖 spawn `which`（避免 sandbox 下 NSTask 带来的额外问题）。
    static func findInPATH(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
