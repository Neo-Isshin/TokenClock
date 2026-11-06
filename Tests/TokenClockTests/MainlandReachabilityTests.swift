#if os(macOS)
import XCTest
import Foundation
@testable import TokenClock

final class MainlandReachabilityTests: XCTestCase {
    func testOnlyPublicLiteralIPsAndValidPortsAreSubmitted() {
        XCTAssertEqual(MainlandReachabilityTarget.parse(ip: " 1.1.1.1 ", port: "443")?.display, "1.1.1.1:443")
        XCTAssertEqual(MainlandReachabilityTarget.parse(ip: "2606:4700:4700:0:0:0:0:1111", port: "8443")?.display, "[2606:4700:4700::1111]:8443")
        for ip in ["", "example.com", "https://1.1.1.1/key", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "100.64.0.1", "169.254.1.1", "0.0.0.0", "224.0.0.1", "198.51.100.1", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "2001:db8::1"] {
            XCTAssertNil(MainlandReachabilityTarget.parse(ip: ip, port: "443"), ip)
        }
        for port in ["0", "65536", "-1", "abc"] { XCTAssertNil(MainlandReachabilityTarget.parse(ip: "1.1.1.1", port: port)) }
        let v6 = MainlandReachabilityTarget(ip: "2606:4700:4700::1111", port: 443)
        XCTAssertEqual(MainlandReachabilityService.referenceTarget(for: v6).ip, "2606:4700:4700::1001")
    }

    func testRequestHasExplicitCarrierAndForeignControlsWithoutAuthentication() throws {
        let target = MainlandReachabilityTarget(ip: "1.1.1.1", port: 8443)
        let request = MainlandReachabilityService.request(target: target, mainland: true)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.url?.absoluteString, "https://api.globalping.io/v1/measurements")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body["target"] as? String, target.ip)
        let locations = try XCTUnwrap(body["locations"] as? [[String: Any]])
        XCTAssertEqual(locations.compactMap { $0["asn"] as? Int }, [4134, 4837, 9808])
        XCTAssertTrue(locations.allSatisfy { $0["country"] as? String == "CN" && $0["limit"] as? Int == 2 })
        let options = try XCTUnwrap(body["measurementOptions"] as? [String: Any])
        XCTAssertEqual(options["protocol"] as? String, "TCP")
        XCTAssertEqual(options["port"] as? Int, 8443)
        XCTAssertEqual(options["packets"] as? Int, 3)
        XCTAssertNil(options["ipVersion"], "Globalping rejects ipVersion with a literal IP target")
        let reuse = MainlandReachabilityService.request(target: target, mainland: true, reuse: "original-fixture")
        let reused = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(reuse.httpBody)) as? [String: Any])
        XCTAssertEqual(reused["locations"] as? String, "original-fixture")
    }

    func testOrdinaryTimeoutsNeverBecomeBlockingWithoutHealthyReferences() async {
        let report = await fixture(.unhealthyReference)
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertEqual(report.observations.filter { $0.country == "CN" }.count, 6)
        XCTAssertFalse(report.observations.contains { $0.referenceReachable == true })
    }

    func testMultiCarrierRestrictionRequiresMatchingSameProbeHealthAndTwoForeignControls() async {
        let report = await fixture(.suspected)
        XCTAssertEqual(report.verdict, .suspectedRestriction)
        XCTAssertEqual(report.observations.filter { $0.referenceReachable == true }.count, 6)
        XCTAssertEqual(report.measurementIDs.count, 3)
        var withoutForeign = report
        withoutForeign.observations.removeAll { $0.country == "SG" }
        XCTAssertEqual(withoutForeign.verdict, .inconclusive)
        var oneCarrier = report
        oneCarrier.observations = oneCarrier.observations.filter { $0.carrier == "China Telecom" || $0.carrier == nil }
        XCTAssertEqual(oneCarrier.verdict, .inconclusive)
    }

    func testRefusedPortsAndEverywhereFailuresAreNotLabelledRestrictions() async {
        let report = await fixture(.allFail)
        XCTAssertEqual(report.verdict, .unavailable)
        var refused = await fixture(.suspected)
        let old = refused.observations[0]
        refused.observations[0] = .init(id: old.id, index: old.index, country: old.country, city: old.city,
            asn: old.asn, network: old.network, outcome: .refused, milliseconds: nil, referenceReachable: true)
        XCTAssertEqual(refused.verdict, .inconclusive)
    }

    func testPartialReachabilityAndMissingProbesAreReportedHonestly() async {
        let partial = await fixture(.partial)
        let allPass = await fixture(.allPass)
        XCTAssertEqual(partial.verdict, .partial)
        XCTAssertEqual(allPass.verdict, .reachable)
        let missing = await fixture(.noProbes)
        XCTAssertEqual(missing.verdict, .inconclusive)
        XCTAssertTrue(missing.issues.contains(.noProbes))
    }

    func testMismatchedTargetOrReferenceAndMissingStatsCannotSupplyEvidence() async {
        let wrong = await fixture(.wrongTarget)
        let changed = await fixture(.changedReference)
        let badOptions = await fixture(.wrongOptions)
        XCTAssertTrue(wrong.issues.contains(.invalidResponse))
        XCTAssertTrue(badOptions.issues.contains(.invalidResponse))
        XCTAssertEqual(changed.verdict, .inconclusive)
        let missing = await fixture(.missingStats)
        XCTAssertEqual(missing.verdict, .inconclusive)
        XCTAssertTrue(missing.observations.allSatisfy { $0.outcome == .unavailable })
    }

    func testRateLimitDoesNotAutomaticallyRetryOrInferARestriction() async {
        let report = await fixture(.rateLimited)
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertTrue(report.issues.contains(.rateLimited))
        XCTAssertEqual(GlobalpingFixture.state.snapshot().posts, 2)
    }

    func testStoppingCancelsPollingWithoutWaitingFortySeconds() async throws {
        let fetcher = transport(.inProgress)
        let task = Task { await MainlandReachabilityService.run(target: .init(ip: "8.8.8.8", port: 443), fetcher: fetcher) }
        try await Task.sleep(for: .milliseconds(80))
        let before = Date()
        task.cancel(); fetcher.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(before), 1)
        XCTAssertLessThanOrEqual(GlobalpingFixture.state.snapshot().posts, 2)
    }

    @MainActor func testModelStartsIdleAndRejectsPrivateTargetsWithoutStarting() {
        let model = MainlandReachabilityModel()
        XCTAssertFalse(model.running)
        XCTAssertNil(model.report)
        model.targetIP = "127.0.0.1"; model.start()
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.inputError.isEmpty)
    }

    func testLivePublicTargetOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_LIVE_MAINLAND"] == "1" else { throw XCTSkip("Opt-in Globalping public measurement") }
        let target = MainlandReachabilityTarget(ip: "1.1.1.1", port: 443)
        let report = await MainlandReachabilityService.run(target: target, fetcher: NetworkDiagnosticFetcher())
        XCTAssertFalse(report.observations.isEmpty, "\(report.issues)")
        XCTAssertTrue(report.observations.contains { $0.outcome == .reachable })
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_MAINLAND_RECEIPT"] {
            let data: [String: Any] = ["target": target.display, "ids": report.measurementIDs,
                "verdict": String(describing: report.verdict), "issues": report.issues.map(\.rawValue),
                "rows": report.observations.map { ["country": $0.country, "asn": String($0.asn), "outcome": $0.outcome.rawValue] }]
            try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
        }
    }

    private func transport(_ mode: GlobalpingFixture.Mode) -> NetworkDiagnosticFetcher {
        GlobalpingFixture.state.reset(mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GlobalpingFixture.self]
        return NetworkDiagnosticFetcher(configuration: configuration)
    }
    private func fixture(_ mode: GlobalpingFixture.Mode) async -> MainlandReachabilityReport {
        await MainlandReachabilityService.run(target: .init(ip: "8.8.8.8", port: 443), fetcher: transport(mode))
    }
}

private final class GlobalpingFixture: URLProtocol, @unchecked Sendable {
    enum Mode { case suspected, unhealthyReference, allFail, partial, allPass, noProbes, wrongTarget, wrongOptions, changedReference, missingStats, rateLimited, inProgress }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var mode = Mode.suspected
        private var posts = 0
        func reset(_ value: Mode) { lock.lock(); defer { lock.unlock() }; mode = value; posts = 0 }
        func snapshot(post: Bool = false) -> (mode: Mode, posts: Int) {
            lock.lock(); defer { lock.unlock() }; if post { posts += 1 }; return (mode, posts)
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.globalping.io" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let info = Self.state.snapshot(post: request.httpMethod == "POST")
        var status = 200
        var body: [String: Any]
        if request.httpMethod == "POST" {
            let data = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = stream.read(&bytes, maxLength: bytes.count)
                return count > 0 ? Data(bytes.prefix(count)) : nil
            } ?? Data()
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let reference = value["locations"] is String
            let locations = value["locations"] as? [[String: Any]] ?? []
            let mainland = reference || locations.first?["country"] as? String == "CN"
            if info.mode == .rateLimited { status = 429; body = [:] }
            else if info.mode == .noProbes { status = 422; body = [:] }
            else { status = 201; body = ["id": reference ? "ref-fixture" : mainland ? "cn-fixture" : "foreign-fixture", "probesCount": mainland ? 6 : 2] }
        } else {
            let id = request.url!.lastPathComponent
            let reference = id == "ref-fixture"
            let mainland = id != "foreign-fixture"
            let target = reference ? "1.1.1.1" : "8.8.8.8"
            var rows: [[String: Any]] = []
            for index in 0..<(mainland ? 6 : 2) {
                let passed: Bool
                switch info.mode {
                case .allPass: passed = true
                case .allFail: passed = false
                case .unhealthyReference: passed = !mainland
                case .partial: passed = reference || !mainland || index == 0
                default: passed = reference || !mainland
                }
                var city = "Fixture-\(index)"
                if reference && info.mode == .changedReference { city = "Different-probe" }
                let probe: [String: Any] = ["country": mainland ? "CN" : index == 0 ? "US" : "SG",
                    "city": city, "network": "Fixture network", "asn": mainland ? [4134, 4837, 9808][index / 2] : 13335]
                let stats: [String: Any] = ["total": 3, "rcv": passed ? 3 : 0, "drop": passed ? 0 : 3, "loss": passed ? 0 : 100, "avg": passed ? 12.5 as Any : NSNull()]
                var result: [String: Any] = ["status": "finished", "resolvedAddress": target, "rawOutput": "Fixture output", "stats": stats]
                if info.mode == .missingStats { result.removeValue(forKey: "stats") }
                rows.append(["probe": probe, "result": result])
            }
            body = ["id": id, "type": "ping", "target": info.mode == .wrongTarget ? "9.9.9.9" : target,
                "status": info.mode == .inProgress ? "in-progress" : "finished", "probesCount": rows.count,
                "measurementOptions": ["protocol": "TCP", "port": 443], "results": rows]
            if info.mode == .wrongOptions { body["measurementOptions"] = ["protocol": "TCP", "port": 443, "packets": "3"] }
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
