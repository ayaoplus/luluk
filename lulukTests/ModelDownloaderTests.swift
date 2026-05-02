//
//  ModelDownloaderTests.swift
//  lulukTests
//
//  Created by ayao on 2026/5/2.
//  Copyright © 2026 ayao. All rights reserved.
//
//  ModelDownloader 单元测试。M2 范围只测：
//   - WhisperModel.modelFileName 派生
//   - 应用支持目录路径常量
//   - findInPATH 静态工具
//   - currentModel 默认值 + switchModel 改值
//
//  ensureWhisperReady 依赖文件系统真实文件，留给手动 integration 验证（开发期 dogfood）。
//

import Testing
import Foundation
@testable import luluk

struct ModelDownloaderTests {

    @Test func modelFileNameMatchesHFConvention() {
        // SPEC 锁定：HF 上文件名格式 `ggml-<rawValue>.bin`
        #expect(WhisperModel.largeV3Turbo.modelFileName == "ggml-large-v3-turbo.bin")
        #expect(WhisperModel.largeV3.modelFileName == "ggml-large-v3.bin")
        #expect(WhisperModel.mediumTurbo.modelFileName == "ggml-medium-turbo.bin")
        #expect(WhisperModel.tiny.modelFileName == "ggml-tiny.bin")
    }

    @Test func appSupportPathsUnderLulukNamespace() {
        let root = ModelDownloader.appSupportRoot.path
        // 必须落在用户域 Application Support 下，且路径含 /luluk
        #expect(root.contains("/Library/Application Support/luluk"))
        #expect(ModelDownloader.binDirectory.path.hasSuffix("/luluk/bin"))
        #expect(ModelDownloader.modelsDirectory.path.hasSuffix("/luluk/models"))
    }

    @Test func vadModelFileNameIsLockedVersion() {
        // SPEC：VAD 模型版本写死，避免运行时切版本。M5 升级时改这个常量。
        #expect(ModelDownloader.vadModelFileName == "ggml-silero-v5.1.2.bin")
    }

    @Test func defaultCurrentModelIsLargeV3Turbo() async {
        let dl = ModelDownloader()
        let model = await dl.currentModel
        #expect(model == .largeV3Turbo)
    }

    @Test func switchModelUpdatesCurrent() async throws {
        let dl = ModelDownloader()
        try await dl.switchModel(to: .tiny)
        let model = await dl.currentModel
        #expect(model == .tiny)
    }

    @Test func findInPATHLocatesShellBuiltins() {
        // PATH 上一定有的：sh
        let result = ModelDownloader.findInPATH("sh")
        #expect(result != nil)
        if let path = result {
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
    }

    @Test func findInPATHReturnsNilForBogusName() {
        #expect(ModelDownloader.findInPATH("definitely-does-not-exist-xyz-9999") == nil)
    }
}
