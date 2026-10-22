#if os(macOS)
import XCTest
import AppKit
import WebKit
@testable import TokenClock

final class ModelDetectNavigationPolicyTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:32145/s/native-test-token-1234/")!
    private let job = "job-" + String(repeating: "a", count: 32)

    func testReadyCapabilityRequiresCanonicalLoopbackToken() throws {
        XCTAssertEqual(try ModelDetectNavigationPolicy(baseURL: base).homeURL().query, "native=1")
        for invalid in ["https://127.0.0.1:32145/s/native-test-token-1234/", "http://localhost:32145/s/native-test-token-1234/",
                        "http://127.0.0.1/s/native-test-token-1234/", "http://127.0.0.1:32145/s/short/",
                        "http://127.0.0.1:32145/s/native-test-token-1234/?token=secret",
                        "http://127.0.0.1:32145/s/native-test-token-1234/#secret",
                        "http://user@127.0.0.1:32145/s/native-test-token-1234/",
                        "http://127.0.0.1:32145/s/native-test-token-1234/%2e%2e/"] {
            XCTAssertThrowsError(try ModelDetectNavigationPolicy(baseURL: URL(string: invalid)!))
        }
    }

    func testOnlyWorkspaceAndFixedReportRoutesCanRender() throws {
        let policy = try ModelDetectNavigationPolicy(baseURL: base)
        XCTAssertEqual(policy.destination(for: base, userInitiated: false), .workbench)
        XCTAssertEqual(policy.destination(for: base.appendingPathComponent("reports/\(job)/report.html"), userInitiated: false), .report)
        for route in ["artifact.html", "artifact.svg", "reports/\(job)/artifact.html", "api/jobs", "app.js",
                      "reports/\(job)/report.html/extra", "reports/job-other/report.html", "../index.html", "%2e%2e/index.html"] {
            XCTAssertEqual(policy.destination(for: URL(string: base.absoluteString + route)!, userInitiated: true), .denied, route)
        }
        for url in ["file:///tmp/artifact.html", "data:text/html,<script>alert(1)</script>", "javascript:alert(1)",
                    "blob:http://127.0.0.1:32145/abc", "http://127.0.0.1:32146/s/native-test-token-1234/",
                    "http://127.0.0.1:32145/s/another-token-12345/"] {
            XCTAssertEqual(policy.destination(for: URL(string: url)!, userInitiated: false), .denied)
        }
    }

    func testDownloadsRequireFixedRouteOrTrustedBlobSource() throws {
        let policy = try ModelDetectNavigationPolicy(baseURL: base)
        for route in ["reports/\(job)/report.json", "reports/\(job)/observation.json", "reports/\(job)/evidence.zip",
                      "reports/\(job)/report.html?download=1", "partial-evidence/\(job)", "support/\(job)"] {
            XCTAssertEqual(policy.destination(for: URL(string: base.absoluteString + route)!, userInitiated: false), .download)
        }
        let blob = URL(string: "blob:http://127.0.0.1:32145/fixture")!
        XCTAssertEqual(policy.destination(for: blob, userInitiated: true, requestedDownload: true, fromTrustedPage: true), .download)
        XCTAssertEqual(policy.destination(for: blob, userInitiated: true, requestedDownload: true), .denied)
        XCTAssertEqual(policy.destination(for: URL(string: "blob:https://example.com/fixture")!, userInitiated: true,
                                          requestedDownload: true, fromTrustedPage: true), .denied)
    }

    func testExternalLinksNeedUserActionAndCannotDiscloseCapability() throws {
        let policy = try ModelDetectNavigationPolicy(baseURL: base)
        let external = URL(string: "https://example.com/documentation")!
        XCTAssertEqual(policy.destination(for: external, userInitiated: true, fromTrustedPage: true), .external)
        XCTAssertEqual(policy.destination(for: external, userInitiated: false, fromTrustedPage: true), .denied)
        XCTAssertEqual(policy.destination(for: external, userInitiated: true, fromTrustedPage: false), .denied)
        for value in ["https://example.com/?url=" + base.absoluteString,
                      "https://example.com/native%252Dtest%252Dtoken%252D1234", "https://user:pass@example.com/"] {
            XCTAssertEqual(policy.destination(for: URL(string: value)!, userInitiated: true, fromTrustedPage: true), .denied)
        }
    }

    func testDownloadFilenameCannotSelectHiddenOrParentPaths() {
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename("../../report.json"), "report.json")
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename("C:\\folder\\evidence.zip"), "evidence.zip")
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename(".ssh"), "ModelDetect-download")
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename(".."), "ModelDetect-download")
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename("bad\nname.html"), "badname.html")
        XCTAssertEqual(ModelDetectNavigationPolicy.safeFilename(String(repeating: "a", count: 500)).count, 180)
    }
}

@MainActor
final class ModelDetectWindowTests: XCTestCase {
    private final class RequestOwner: NSObject {
        @objc dynamic var request: NSURLRequest?
        init(request: NSURLRequest?) { self.request = request }
    }

    func testObjectiveCNullFrameRequestDoesNotForceBridgeOrAuthorizeExternalNavigation() throws {
        XCTAssertNil(ModelDetectWebRequest.request(from: nil))
        XCTAssertNil(ModelDetectWebRequest.request(from: NSObject()))
        let emptyFrame = RequestOwner(request: nil)
        XCTAssertNil(ModelDetectWebRequest.request(from: emptyFrame))
        let base = URL(string: "http://127.0.0.1:32145/s/native-test-token-1234/")!
        let policy = try ModelDetectNavigationPolicy(baseURL: base)
        let trustedSource = policy.isTrustedPage(ModelDetectWebRequest.request(from: emptyFrame)?.url)
        XCTAssertFalse(trustedSource)
        XCTAssertEqual(policy.destination(for: policy.homeURL(), userInitiated: false, fromTrustedPage: trustedSource), .workbench)
        XCTAssertEqual(policy.destination(for: URL(string: "https://example.com/")!, userInitiated: true, fromTrustedPage: trustedSource), .denied)
        XCTAssertEqual(policy.destination(for: URL(string: "blob:http://127.0.0.1:32145/test")!, userInitiated: true,
                                          requestedDownload: true, fromTrustedPage: trustedSource), .denied)
        let loadedFrame = RequestOwner(request: NSURLRequest(url: base))
        XCTAssertEqual(ModelDetectWebRequest.request(from: loadedFrame)?.url, base)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition(), "Native window did not reach the expected state")
    }

    func testOnlyModeIsExplicitAndDoesNotMatchArgumentValues() {
        XCTAssertTrue(AppDelegate.isModelDetectOnly(arguments: ["TokenClock", "--model-detect-only"]))
        XCTAssertFalse(AppDelegate.isModelDetectOnly(arguments: ["--model-detect-only"]))
        XCTAssertFalse(AppDelegate.isModelDetectOnly(arguments: ["TokenClock", "--model-detect-only=false"]))
        XCTAssertFalse(AppDelegate.isModelDetectOnly(arguments: ["TokenClock"]))
    }

    func testStartupFailureRetryReuseAndStaleCallback() async throws {
        _ = NSApplication.shared
        var completions: [ModelIntegrityLauncher.Completion] = []
        var opened: [URL] = []
        let controller = ModelDetectWindow(starter: { completions.append($0) }, openExternal: { opened.append($0); return true })
        controller.show(activate: false)
        let firstWindow = controller.window
        XCTAssertEqual(controller.phase, .starting)
        XCTAssertFalse(controller.webView.configuration.websiteDataStore.isPersistent)
        controller.show(activate: false)
        XCTAssertEqual(completions.count, 1)
        completions[0](.failure(.timeout))
        try await waitUntil { if case .failed = controller.phase { return true }; return false }
        controller.retry()
        XCTAssertEqual(completions.count, 2)
        completions[0](.failure(.stopped))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.phase, .starting)
        completions[1](.failure(.invalidReady))
        try await waitUntil { if case .failed = controller.phase { return true }; return false }
        XCTAssertTrue(controller.window === firstWindow)
        XCTAssertTrue(opened.isEmpty)
        controller.close()
        XCTAssertEqual(controller.phase, .idle)
    }

    /// Actual WebKit + owned loopback fixture; no real session, paid API, or user browser.
    func testNativeWebKitLoadsPrefillAndBlocksRawArtifactExecution() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelDetect-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
import http.server,json,sys
prefix='/s/native-smoke-token-1234/'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        with open(sys.argv[1],'a') as log: log.write(self.path+'\n')
        body=b'''<!doctype html><title>Native smoke</title><h1 id="heading">Local workspace</h1><script>window.prefills=[]; window.addEventListener('tokenclock:model-detect-prefill',e=>window.prefills.push(e.detail));</script>'''
        if 'artifact.html' in self.path: body=b'<script>window.rawArtifactExecuted=true</script>'
        self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(json.dumps({'event':'ready','url':'http://127.0.0.1:'+str(server.server_port)+prefix}),flush=True)
server.serve_forever()
"""#
        let requests = directory.appendingPathComponent("requests.txt")
        let process = Process()
        process.executableURL = try ModelIntegrityLauncher.pythonExecutable(environment: ProcessInfo.processInfo.environment)
        process.arguments = ["-I", "-u", "-c", script, requests.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
            if line.count > 4096 { XCTFail("Invalid fixture ready record"); return }
        }
        let base = try ModelIntegrityLauncher.parseReadyLine(line)
        var starts = 0
        var external: [URL] = []
        let controller = ModelDetectWindow(starter: { completion in starts += 1; completion(.success(base)) },
                                           openExternal: { external.append($0); return true })
        defer { controller.close() }
        let source = directory.appendingPathComponent("session '; window.rawArtifactExecuted=true; 中文.jsonl").path
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: source))
        controller.showSession(sourcePath: source, activate: false)
        try await waitUntil { controller.phase == .ready }
        try await Task.sleep(nanoseconds: 150_000_000)
        let heading = try await controller.webView.evaluateJavaScript("document.getElementById('heading').textContent")
        XCTAssertEqual(heading as? String, "Local workspace")
        let prefill = try await controller.webView.evaluateJavaScript("window.prefills[0].source_path")
        XCTAssertEqual(prefill as? String, source)
        let injected = try await controller.webView.evaluateJavaScript("Boolean(window.rawArtifactExecuted)")
        XCTAssertEqual(injected as? Bool, false)
        let first = controller.window
        controller.close()
        controller.show(activate: false)
        XCTAssertTrue(first === controller.window)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(process.isRunning, "Closing the native window must preserve the owned worker")
        controller.webView.load(URLRequest(url: base.appendingPathComponent("artifact.html")))
        try await Task.sleep(nanoseconds: 300_000_000)
        let requestLog = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertFalse(requestLog.contains("artifact.html"), "Raw artifact navigation must be blocked before a request")
        let didExecute = try await controller.webView.evaluateJavaScript("Boolean(window.rawArtifactExecuted)")
        XCTAssertEqual(didExecute as? Bool, false)
        XCTAssertTrue(external.isEmpty)
    }
}
#endif
