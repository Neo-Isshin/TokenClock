#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import TokenClock

/// Normal keeps its own presentation while using the same Model Detect behavior.
@MainActor
final class ModelDetectNormalParityTests: XCTestCase {
    private final class LocalStub: ModelDetectNativeServing {
        var posts: [String] = []
        func request(_ route: String, body: ModelDetectJSON?) async throws -> ModelDetectJSON {
            if body != nil { posts.append(route) }
            return .object([:])
        }
        func download(_ route: String) async throws -> Data { Data() }
    }

    func testNormalWindowRetainsItsWiderNativeLayout() throws {
        let controller = ModelDetectNativeWindow(model: ModelDetectNativeModel(service: LocalStub()))
        controller.loadWindow()
        let panel = try XCTUnwrap(controller.window)
        defer { panel.close() }
        XCTAssertEqual(panel.frame.width, 900, accuracy: 1)
        XCTAssertEqual(panel.minSize.width, 860)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isOpaque)
        XCTAssertTrue(panel.contentView is NSHostingView<ModelDetectNativeView>)
        controller.model.phase = .result
        XCTAssertEqual(panel.frame.height, 770, accuracy: 1)
    }

    func testSessionExpectedModelPrefillsWithoutSendingRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-normal-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.jsonl")
        try Data("{}\n".utf8).write(to: source)
        let service = LocalStub(), model = ModelDetectNativeModel(service: service)
        let controller = ModelDetectNativeWindow(model: model)
        defer { controller.window?.close() }
        controller.showSession(sourcePath: source.path, expectedModel: "claude-fable-5.1", activate: false)
        await Task.yield()
        XCTAssertEqual(model.sourceURL, source)
        XCTAssertEqual(model.comparisonModel, "claude-fable-5.1")
        XCTAssertEqual(model.mode, .session)
        XCTAssertTrue(service.posts.isEmpty)
        XCTAssertEqual(model.l2Method, "numeric")
    }

    func testNormalPackagingRetainsMontereyAndNormalIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let helper = try String(contentsOf: root.appendingPathComponent("scripts/package-model-detect-macos.py"), encoding: .utf8)
        XCTAssertTrue(package.contains("platforms: [.macOS(.v12)]"))
        XCTAssertTrue(helper.contains("minimum_macos_core='12.0'"))
        XCTAssertTrue(helper.contains("'LSMinimumSystemVersion':'12.0'"))
        XCTAssertTrue(helper.contains("TokenClock-normal-"))
        XCTAssertTrue(helper.contains("'integration_version':'0.11.0'"))
        XCTAssertFalse(helper.contains("TokenClock-glass-"))
    }

    func testRealNormalWorkerWithExplicitReadOnlyRuntime() async throws {
        guard let runtime = ProcessInfo.processInfo.environment["TOKENCLOCK_TEST_NORMAL_RUNTIME"] else {
            throw XCTSkip("Opt in with a prepared runtime; no dependency download or installation occurs")
        }
        enum AcceptanceError: Error { case failed }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-normal-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = sourceRoot.appendingPathComponent("Sources/TokenClock/Resources/model-integrity-worker/worker.py")
        let originalHash = try ModelIntegrityRuntimeCache.digest(worker.deletingLastPathComponent().appendingPathComponent("runtime.zip"))
        let environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path,
            "TOKENCLOCK_MODEL_INTEGRITY_WORKER": worker.path,
            "TOKENCLOCK_MODEL_INTEGRITY_RUNTIME": runtime,
            "TOKENCLOCK_MODEL_INTEGRITY_STATE_DIR": root.appendingPathComponent("state").path]
        let launcher = ModelIntegrityLauncher(startupTimeout: 30) {
            try ModelIntegrityLauncher.defaultConfiguration(environment: environment)
        }
        defer { launcher.stop() }
        let base: URL = try await withCheckedThrowingContinuation { continuation in
            launcher.start { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure: continuation.resume(throwing: AcceptanceError.failed)
                }
            }
        }
        let info: ModelDetectJSON
        do { info = try await ModelDetectNativeClient(baseURL: base).request("api/info") }
        catch { throw AcceptanceError.failed } // Do not leak the capability URL through XCTest errors.
        XCTAssertEqual(info["mode_default"].string, "local")
        XCTAssertEqual(info["external_default"].bool, false)
        XCTAssertEqual(info["references"]["status"].string, "verified")
        XCTAssertEqual(info["references"]["external_numeric_enabled"].bool, true)
        XCTAssertEqual(info["references"]["external_numeric"]["models"].number, 59)
        XCTAssertEqual(info["references"]["identity_accuracy_validated"].bool, false)
        XCTAssertEqual(try ModelIntegrityRuntimeCache.digest(worker.deletingLastPathComponent().appendingPathComponent("runtime.zip")), originalHash)
    }

    func testNativeLightAndDarkLayoutsWithLatestResultComponents() throws {
        let model = ModelDetectNativeModel(service: LocalStub())
        let host = NSHostingView(rootView: ModelDetectNativeView(model: model, onChooseFile: {}, onExport: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 740)
        for result in [false, true] {
            if result {
                model.presentation = ModelDetectResultPresentation(report: .object([
                    "facts": .array([.object(["code": .string("source.model_claim_difference")])])
                ]))
                model.brief = .init(title: "型号记录不一致", summary: "这是一份合成测试结果。", reasons: ["请求和返回记录不同。"], caveat: "不代表已验证模型身份。", primaryActionTitle: nil)
                model.costSummary = "本地测试 · 无模型请求"
                model.phase = .result
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                host.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(host.fittingSize.width, 860)
                if let directory = ProcessInfo.processInfo.environment["TOKENCLOCK_MODEL_DETECT_PREVIEW_DIR"] {
                    XCTAssertTrue(directory.hasPrefix("/"))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let path = URL(fileURLWithPath: directory).appendingPathComponent("normal-\(result ? "result" : "input")-\(name).png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
                }
            }
        }
    }
}
#endif
