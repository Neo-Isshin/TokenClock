#if os(macOS)
import XCTest
import Foundation
@testable import TokenClock

private actor NativeClientMockTransport: ModelDetectNativeTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> ModelDetectNativeHTTPResponse
    private var requests: [URLRequest] = []
    private let handler: Handler
    init(_ handler: @escaping Handler = { request, _ in
        ModelDetectNativeHTTPResponse(data: Data("{}".utf8), url: request.url, statusCode: 200, contentType: "application/json")
    }) { self.handler = handler }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ModelDetectNativeHTTPResponse {
        requests.append(request)
        return try await handler(request, maximumBytes)
    }
    func captured() -> [URLRequest] { requests }
}

private final class NativeClientURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = [Data("{}".utf8)]
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply = Reply()
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static func install(_ reply: Reply) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.reply = reply; state.requests = []
    }
    static func captured() -> [URLRequest] {
        state.lock.lock(); defer { state.lock.unlock() }; return state.requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock()
        Self.state.requests.append(request)
        let reply = Self.state.reply
        Self.state.lock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ModelDetectNativeClientTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:32145/s/native-client-synthetic-token/")!
    private let job = "job-" + String(repeating: "a", count: 32)

    private func expectError(_ expected: ModelDetectNativeClientError,
                             _ operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected a safe client error", file: file, line: line) }
        catch let error as ModelDetectNativeClientError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
    }

    func testJSONIsTypedSendableRoundTripsAndHasSafeMissingValues() throws {
        let value: ModelDetectJSON = .object(["name": .string("测试"), "n": .number(3.5), "yes": .bool(true), "nil": .null, "rows": .array([.number(1)])])
        XCTAssertEqual(try JSONDecoder().decode(ModelDetectJSON.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(value["absent"], .null)
        XCTAssertEqual(value["name"].string, "测试"); XCTAssertEqual(value["n"].number, 3.5)
        XCTAssertEqual(value["yes"].bool, true); XCTAssertNil(value["yes"].number)
        XCTAssertEqual(value["rows"].array, [.number(1)])
        XCTAssertEqual(value["absent"].array, []); XCTAssertEqual(value["absent"].object, [:])
        XCTAssertThrowsError(try JSONEncoder().encode(ModelDetectJSON.number(.infinity)))
    }

    func testReadyURLRejectsOtherOriginsCredentialsQueriesAndPrefixTricks() {
        for value in ["https://127.0.0.1:32145/s/native-client-synthetic-token/", "http://localhost:32145/s/native-client-synthetic-token/",
                      "http://127.0.0.2:32145/s/native-client-synthetic-token/", "http://127.0.0.1/s/native-client-synthetic-token/",
                      "http://user:password@127.0.0.1:32145/s/native-client-synthetic-token/", "http://127.0.0.1:32145/s/short/",
                      base.absoluteString + "?key=secret", base.absoluteString + "#fragment", base.absoluteString + "extra",
                      "http://127.0.0.1:32145/s/native%2dclient-synthetic-token/", "http://127.0.0.1:32145/s/../"] {
            XCTAssertThrowsError(try ModelDetectNativeClient(baseURL: URL(string: value)!))
        }
    }

    func testRouteTraversalAndMethodConfusionAreRejectedBeforeTransport() async throws {
        let transport = NativeClientMockTransport()
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
        for route in ["https://outside.invalid/api/jobs", "/api/jobs", "../api/jobs", "api/../jobs", "api//jobs", "api/jobs?x=1",
                      "api/%2e%2e/jobs", "api\\jobs", "api/jobs#fragment", "reports/\(job)/../../secret", "reports/job-other/report.json",
                      "api/jobs/\(job)\n", "reports/\(job)\r/report.json",
                      "reports/\(job)/artifact.svg", "app.js", "index.html"] {
            await expectError(.invalidRoute) { _ = try await client.request(route) }
        }
        await expectError(.invalidRoute) { _ = try await client.request("api/info", body: .object([:])) }
        await expectError(.invalidRoute) { _ = try await client.request("api/model-catalog") }
        await expectError(.invalidRoute) { _ = try await client.request("api/jobs/\(self.job)/cancel") }
        await expectError(.invalidRoute) { _ = try await client.download("api/jobs") }
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    }

    func testAllowedJSONAPIsHaveOnlyTheLocalHostOriginAndNoCookieCache() async throws {
        let transport = NativeClientMockTransport()
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
        for route in ["api/info", "api/sessions", "api/connections", "api/jobs", "api/jobs/\(job)"] {
            _ = try await client.request(route)
        }
        let body: ModelDetectJSON = .object(["api_key": .string("synthetic-key-body-only")])
        for route in ["api/connections", "api/connections/delete", "api/model-catalog", "api/preview", "api/jobs",
                      "api/jobs/\(job)/cancel", "api/jobs/\(job)/resume"] {
            _ = try await client.request(route, body: body)
        }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 12)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "127.0.0.1:32145")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:32145")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.httpMethod, index < 5 ? "GET" : "POST")
            XCTAssertTrue(request.url!.path.hasPrefix(base.path))
            if index >= 5 { XCTAssertEqual(try JSONDecoder().decode(ModelDetectJSON.self, from: request.httpBody!), body) }
        }
    }

    func testDisplayReportAndOriginalDownloadUseDifferentBackendPathsWithoutReencoding() async throws {
        let original = Data("{\n  \"frozen\": true\n}\n".utf8)
        let transport = NativeClientMockTransport { request, _ in
            let raw = request.url?.query == "download=1" ? original : Data("{\"presentation\":{\"derived_for_display\":true}}".utf8)
            return ModelDetectNativeHTTPResponse(data: raw, url: request.url, statusCode: 200, contentType: "application/json")
        }
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
        let displayed = try await client.request("reports/\(job)/report.json")
        XCTAssertEqual(displayed["presentation"]["derived_for_display"].bool, true)
        let raw = try await client.download("reports/\(job)/report.json")
        XCTAssertEqual(raw, original)
        let requests = await transport.captured()
        XCTAssertNil(requests[0].url?.query); XCTAssertEqual(requests[1].url?.query, "download=1")
        for name in ["report.html", "observation.json", "evidence.zip"] { _ = try await client.download("reports/\(job)/\(name)") }
        await expectError(.invalidRoute) { _ = try await client.download("reports/\(self.job)/report.json?download=1") }
    }

    func testRedirectAndChangedResponseOriginAreNeverAccepted() async throws {
        let redirect = NativeClientMockTransport { request, _ in
            ModelDetectNativeHTTPResponse(data: Data(), url: request.url, statusCode: 302, contentType: nil)
        }
        let client = try ModelDetectNativeClient(baseURL: base, transport: redirect)
        await expectError(.redirectRefused) { _ = try await client.request("api/info") }
        let redirects = await redirect.captured(); XCTAssertEqual(redirects.count, 1)
        for changed in ["http://127.0.0.1:32146/s/native-client-synthetic-token/api/info", "http://127.0.0.1:32145/s/different-capability-token/api/info",
                        "https://outside.invalid/api/info"] {
            let transport = NativeClientMockTransport { _, _ in
                ModelDetectNativeHTTPResponse(data: Data("{}".utf8), url: URL(string: changed), statusCode: 200, contentType: "application/json")
            }
            let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
            await expectError(.unexpectedOrigin) { _ = try await client.request("api/info") }
        }
    }

    func testServiceAndFoundationErrorsCannotRevealCredentialsOrReadyToken() async throws {
        let secret = "opaque-request-secret-0123456789"
        let ready = base.absoluteString
        let transport = NativeClientMockTransport { request, _ in
            let error: ModelDetectJSON = .object(["error": .string("Bad input \(ready) native-client-synthetic-token /s/other-synthetic-capability/ \(secret) sk-test_SYNTHETIC0123456789012345")])
            return ModelDetectNativeHTTPResponse(data: try JSONEncoder().encode(error), url: request.url, statusCode: 400, contentType: "application/json")
        }
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
        do {
            _ = try await client.request("api/preview", body: .object(["semantic_config": .object(["provider": .object(["api_key": .string(secret)])])]))
            XCTFail("Expected safe service error")
        } catch {
            let message = error.localizedDescription
            for hidden in [secret, "native-client-synthetic-token", "other-synthetic-capability", "sk-test_SYNTHETIC", "127.0.0.1"] { XCTAssertFalse(message.contains(hidden)) }
            XCTAssertTrue(message.contains("400")); XCTAssertTrue(message.contains("Bad input"))
        }
        let broken = NativeClientMockTransport { _, _ in
            throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: ready])
        }
        let disconnected = try ModelDetectNativeClient(baseURL: base, transport: broken)
        await expectError(.transportUnavailable) { _ = try await disconnected.request("api/info") }
    }

    func testResponseBoundsAndMalformedJSONRemainSafeWithInjectedTransport() async throws {
        let huge = NativeClientMockTransport { request, maximum in
            ModelDetectNativeHTTPResponse(data: Data(repeating: 65, count: maximum + 1), url: request.url, statusCode: 200, contentType: "application/json")
        }
        let client = try ModelDetectNativeClient(baseURL: base, transport: huge, maximumJSONBytes: 8, maximumDownloadBytes: 9)
        await expectError(.responseTooLarge) { _ = try await client.request("api/info") }
        await expectError(.responseTooLarge) { _ = try await client.download("reports/\(self.job)/report.json") }
        let invalid = NativeClientMockTransport { request, _ in
            ModelDetectNativeHTTPResponse(data: Data("not json".utf8), url: request.url, statusCode: 200, contentType: "text/plain")
        }
        let invalidClient = try ModelDetectNativeClient(baseURL: base, transport: invalid)
        await expectError(.invalidJSON) { _ = try await invalidClient.request("api/info") }
    }

    func testRealSessionDelegateBoundsStreamingAndRejectsRedirectStatusUsingURLProtocol() async throws {
        let transport = ModelDetectURLSessionTransport(protocolClasses: [NativeClientURLProtocol.self])
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport, maximumJSONBytes: 8)
        NativeClientURLProtocol.install(.init(chunks: [Data("\"ok\"".utf8)]))
        let value = try await client.request("api/info"); XCTAssertEqual(value.string, "ok")
        NativeClientURLProtocol.install(.init(chunks: [Data("1234".utf8), Data("5678".utf8), Data("9".utf8)]))
        await expectError(.responseTooLarge) { _ = try await client.request("api/info") }
        NativeClientURLProtocol.install(.init(headers: ["Content-Length": "9000"], chunks: [Data("{}".utf8)]))
        await expectError(.responseTooLarge) { _ = try await client.request("api/info") }
        NativeClientURLProtocol.install(.init(status: 302, headers: ["Location": "https://never-contact.invalid/"], chunks: []))
        await expectError(.redirectRefused) { _ = try await client.request("api/info") }
        XCTAssertEqual(NativeClientURLProtocol.captured().count, 1)
    }

    func testCancellationDoesNotExposeUnderlyingURLOrRetry() async throws {
        let transport = NativeClientMockTransport { request, _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return ModelDetectNativeHTTPResponse(data: Data("{}".utf8), url: request.url, statusCode: 200, contentType: nil)
        }
        let client = try ModelDetectNativeClient(baseURL: base, transport: transport)
        let task = Task { try await client.request("api/info") }
        await Task.yield(); task.cancel()
        await expectError(.cancelled) { _ = try await task.value }
        let requests = await transport.captured(); XCTAssertLessThanOrEqual(requests.count, 1)
    }
}
#endif
