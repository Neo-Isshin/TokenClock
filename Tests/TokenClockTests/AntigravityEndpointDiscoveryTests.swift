import XCTest
@testable import TokenClock

final class AntigravityEndpointDiscoveryTests: XCTestCase {
    func testRecognizesStandaloneAndLegacyAntigravityServersOnly() {
        XCTAssertTrue(AntigravityLocalEndpointDiscovery.isAntigravityServer("/Applications/Antigravity.app/Contents/Resources/bin/language_server"))
        XCTAssertTrue(AntigravityLocalEndpointDiscovery.isAntigravityServer("/opt/Antigravity/resources/app/bin/language_server_linux_x64"))
        XCTAssertFalse(AntigravityLocalEndpointDiscovery.isAntigravityServer("/Applications/Other.app/Contents/Resources/bin/language_server"))
        XCTAssertFalse(AntigravityLocalEndpointDiscovery.isAntigravityServer("/Applications/Antigravity.app/Contents/MacOS/Antigravity"))
    }

    func testZeroRequestedPortUsesActualListenersAndKeepsProcessToken() throws {
        let endpoints = AntigravityLocalEndpointDiscovery.endpoints(
            command: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --https_server_port 0 --csrf_token fixture-token",
            ports: [55277, 55278, 55277, 0, -1, 65536])
        XCTAssertEqual(endpoints.map(\.port), [55277, 55278])
        XCTAssertEqual(endpoints.map(\.csrfToken), ["fixture-token", "fixture-token"])
    }

    func testQuotedAndEqualsFlagsAndInvalidCredentialsFailClosed() {
        for flag in ["--csrf_token=fixture", "--csrf_token \"fixture\"", "--csrf_token 'fixture'"] {
            XCTAssertEqual(AntigravityLocalEndpointDiscovery.endpoints(command: "language_server " + flag, ports: [12345]).first?.csrfToken, "fixture")
        }
        for flag in ["--csrf_token", "--csrf_token \"\"", "--csrf_token \"bad token\"", "--csrf_token \"bad\r\nheader\""] {
            XCTAssertTrue(AntigravityLocalEndpointDiscovery.endpoints(command: "language_server " + flag, ports: [12345]).isEmpty)
        }
    }

    func testParsesActualListeningPortsNotRequestedPortZero() {
        XCTAssertEqual(AntigravityLocalEndpointDiscovery.listeningPorts("p123\nn127.0.0.1:55277\nn[::1]:55278\nn*:0\nn*:65536\n"), [55277, 55278])
    }

    func testLiveAntigravityQuotaWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_ANTIGRAVITY_QUOTA_TESTS"] == "1" else {
            throw XCTSkip("Opt in to query the running Antigravity local quota service")
        }
        let snapshot = AntigravityQuotaService().fetch()
        XCTAssertEqual(snapshot.status, .available, snapshot.message ?? "")
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: snapshot.groups))
        XCTAssertTrue((0...100).contains(indicator.outerRemainingPercent))
        XCTAssertNotNil(indicator.innerRemainingPercent)
        XCTAssertEqual(indicator.details.count, 4)
        // Only public quota diagnostics: never dump process arguments, tokens or account details.
        print("Antigravity live quota: outer=\(indicator.outerRemainingPercent), inner=\(indicator.innerRemainingPercent ?? -1), details=\(indicator.details.count)")
    }
}
