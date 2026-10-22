#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import TokenClock

@MainActor
final class ModelDetectNativeWindowTests: XCTestCase {
    private final class LocalStub: ModelDetectNativeServing {
        var routes: [String] = []
        var posts: [String] = []
        func request(_ route: String, body: ModelDetectJSON?) async throws -> ModelDetectJSON {
            routes.append(route)
            if body != nil { posts.append(route) }
            return .object([:])
        }
        func download(_ route: String) async throws -> Data { Data() }
    }
    private func hasWebView(_ view: NSView) -> Bool { view is WKWebView || view.subviews.contains(where: hasWebView) }

    func testNativePanelReusesHostingContentAndClosesWithoutResettingResult() throws {
        let model = ModelDetectNativeModel(service: LocalStub())
        let controller = ModelDetectNativeWindow(model: model)
        controller.show(activate: false)
        let panel = try XCTUnwrap(controller.window), content = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(content is NSHostingView<ModelDetectNativeView>)
        XCTAssertFalse(hasWebView(content))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        let inputHeight = panel.frame.height
        model.phase = .result
        XCTAssertGreaterThan(panel.frame.height, inputHeight)
        model.brief = .init(title: "保留的结论", summary: "本地结果", reasons: [], caveat: "有限观察", primaryActionTitle: nil)
        panel.close()
        controller.show(activate: false)
        XCTAssertTrue(controller.window === panel)
        XCTAssertTrue(controller.window?.contentView === content)
        XCTAssertEqual(model.brief?.title, "保留的结论")
    }

    func testExactSessionPrefillsWithoutSubmittingAndRunningSessionIsNotReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.jsonl"), second = folder.appendingPathComponent("second.jsonl")
        try Data("{}".utf8).write(to: first); try Data("{}".utf8).write(to: second)
        let service = LocalStub(), model = ModelDetectNativeModel(service: service)
        let controller = ModelDetectNativeWindow(model: model)
        controller.showSession(sourcePath: first.path, activate: false)
        await Task.yield()
        XCTAssertEqual(model.sourceURL, first)
        XCTAssertFalse(service.routes.contains("api/preview"))
        XCTAssertTrue(service.posts.isEmpty)
        model.phase = .running; model.mode = .api
        controller.showSession(sourcePath: second.path, activate: false)
        XCTAssertEqual(model.sourceURL, first)
        XCTAssertEqual(model.mode, .api)
    }

    func testInvalidExplicitSourceClearsPriorSelectionRatherThanAssessingWrongFile() throws {
        let model = ModelDetectNativeModel(service: LocalStub())
        model.sourceURL = URL(fileURLWithPath: "/tmp/previously-selected-session.jsonl")
        let controller = ModelDetectNativeWindow(model: model)
        controller.show(sourcePath: "/definitely-unavailable/session.jsonl", activate: false)
        XCTAssertNil(model.sourceURL)
        XCTAssertFalse(model.canPrepare)
        XCTAssertNotNil(model.errorMessage)
    }
}
#endif
