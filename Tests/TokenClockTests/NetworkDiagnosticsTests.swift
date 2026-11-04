#if os(macOS)
import Foundation
import XCTest
@testable import TokenClock

final class NetworkDiagnosticsTests: XCTestCase {
    func testTraceUsesClientCountryAndRejectsMalformedAddresses() {
        let trace = Data("ip=8.8.8.8\nloc=US\ncolo=HKG\n".utf8)
        XCTAssertEqual(NetworkDiagnosticParser.trace(trace)?.ip, "8.8.8.8")
        XCTAssertEqual(NetworkDiagnosticParser.trace(trace)?.country, "US")
        XCTAssertNil(NetworkDiagnosticParser.trace(Data("ip=not-an-ip\nloc=US\n".utf8)))
        XCTAssertNil(NetworkDiagnosticParser.address("127.0.0.1/evil"))
        XCTAssertNil(NetworkDiagnosticParser.address("fe80::1%en0"))
        XCTAssertEqual(NetworkDiagnosticParser.address("2001:4860:0:0:0:0:0:8888"), "2001:4860::8888")
    }

    func testHttpResponseDoesNotProveAnAIRouteOrIPv6Exit() {
        let ai = NetworkDiagnostics.targets.first { $0.id == "chatgpt" }!
        let html = NetworkDiagnosticReply(data: Data("<html>challenge</html>".utf8), status: 403, limited: false)
        let row = NetworkDiagnostics.parse(html, target: ai)
        XCTAssertEqual(row.state, "responded")
        XCTAssertEqual(row.httpStatus, 403)
        XCTAssertNil(row.ip)
        let v6 = NetworkDiagnostics.targets.first { $0.id == "ipv6" }!
        let wrongFamily = NetworkDiagnosticReply(data: Data("{\"ip\":\"8.8.8.8\"}".utf8), status: 200, limited: false)
        XCTAssertNil(NetworkDiagnostics.parse(wrongFamily, target: v6).ip)
        let limited = NetworkDiagnosticReply(data: Data("ip=8.8.8.8\nloc=US".utf8), status: 200, limited: true)
        XCTAssertNil(NetworkDiagnostics.parse(limited, target: ai).ip)
    }

    func testProbeTargetsAreFixedHttpsWithoutCredentialsOrAccountEndpoints() {
        XCTAssertEqual(NetworkDiagnostics.targets.filter { $0.category == "ai" }.count, 6)
        for target in NetworkDiagnostics.targets {
            let url = URL(string: target.url)!
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.user)
            XCTAssertNil(url.password)
            XCTAssertFalse(url.path.contains("login"))
            XCTAssertFalse(url.path.contains("completions"))
        }
        XCTAssertTrue(NetworkDiagnosticParser.runID("01234567-abcd-0123-abcd-0123456789ab"))
        XCTAssertFalse(NetworkDiagnosticParser.runID("';throw 1;//"))
    }

    func testTransportRefusesOversizedBodiesAndDoesNotFollowRedirects() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticFixtureProtocol.self]
        let fetcher = NetworkDiagnosticFetcher(configuration: configuration)
        defer { fetcher.cancel() }
        let large = await fetcher.fetch(URL(string: "https://fixture.invalid/large")!)
        XCTAssertTrue(large.limited)
        XCTAssertLessThanOrEqual(large.data.count, NetworkDiagnosticFetcher.bodyLimit)
        XCTAssertEqual(large.status, 200)
        let ordinary = await fetcher.fetch(URL(string: "https://fixture.invalid/small")!)
        XCTAssertEqual(ordinary.status, 200)
        XCTAssertEqual(NetworkDiagnosticParser.trace(ordinary.data)?.ip, "8.8.8.8")
        fetcher.cancel()
        let stopped = await fetcher.fetch(URL(string: "https://fixture.invalid/never")!)
        XCTAssertNil(stopped.status)
    }
}

private final class DiagnosticFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let large = request.url!.path == "/large"
        let data = large ? Data(repeating: 0, count: NetworkDiagnosticFetcher.bodyLimit + 1) : Data("ip=8.8.8.8\nloc=US\n".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
