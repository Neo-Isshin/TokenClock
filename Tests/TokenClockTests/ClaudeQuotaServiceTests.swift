import Foundation
import XCTest
@testable import TokenClock

final class ClaudeQuotaServiceTests: XCTestCase {
    func testDecodesSubscriptionWindowsAndModelLimits() throws {
        let payload = #"{"five_hour":{"utilization":25,"resets_at":"2026-08-21T12:00:00Z"},"seven_day":{"utilization":"70","resets_at":"2026-08-25T12:00:00Z"},"seven_day_opus":{"utilization":90,"resets_at":2000000000}}"#
        let refreshed = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = try XCTUnwrap(ClaudeQuotaService.decodeUsageResponse(
            Data(payload.utf8), planType: "max", now: refreshed
        ))

        XCTAssertEqual(snapshot.status, .available)
        XCTAssertEqual(snapshot.source, .oauthAPI)
        XCTAssertEqual(snapshot.planType, "max")
        XCTAssertEqual(snapshot.refreshedAt, refreshed)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["claude:five_hour", "claude:seven_day", "claude:seven_day_opus"])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [75, 30, 10])
        XCTAssertNotNil(snapshot.buckets[0].resetsAt)
    }

    func testDecodesClaudeCodeCredentialWithoutLeakingOtherFields() throws {
        let payload = #"{"claudeAiOauth":{"accessToken":"secret-token","refreshToken":"do-not-use","subscriptionType":"pro"}}"#
        let credential = try XCTUnwrap(ClaudeQuotaService.decodeCredentialPayload(Data(payload.utf8)))
        XCTAssertEqual(credential.accessToken, "secret-token")
        XCTAssertEqual(credential.subscriptionType, "pro")
    }

    func testBuildsAndDeduplicatesCredentialPaths() {
        let paths = ClaudeQuotaService.credentialCandidatePaths(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"],
            homeDirectory: "/home/neo",
            configuredClaudeHome: "/custom/claude"
        )
        XCTAssertEqual(paths, [
            "/custom/claude/.credentials.json",
            "/home/neo/.claude/.credentials.json",
        ])
    }

    func testRejectsResponsesWithoutQuotaWindows() {
        XCTAssertNil(ClaudeQuotaService.decodeUsageResponse(Data(#"{"five_hour":null}"#.utf8)))
    }

    #if os(macOS)
    func testBuildsCurrentClaudeCodeKeychainCandidates() {
        XCTAssertEqual(
            ClaudeQuotaService.macOSKeychainServices(environment: [:], configuredClaudeHome: "/Users/neo/.claude"),
            ["Claude Code-credentials", "Claude Code"]
        )
        let custom = ClaudeQuotaService.macOSKeychainServices(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"],
            configuredClaudeHome: "/custom/claude"
        )
        XCTAssertEqual(custom.count, 3)
        XCTAssertTrue(custom[0].hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(custom[0].count, "Claude Code-credentials-".count + 8)
        XCTAssertEqual(
            ClaudeQuotaService.macOSKeychainAccounts(environment: ["USER": "neo"]),
            ["neo", "claude-code-user"]
        )
    }
    #endif

    func testLiveClaudeCodeSubscriptionWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_CLAUDE_QUOTA_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_CLAUDE_QUOTA_INTEGRATION_TESTS=1 to query the signed-in Claude Code account")
        }
        let snapshot = ClaudeQuotaService().fetch()
        XCTAssertEqual(snapshot.status, .available, snapshot.message ?? "Claude quota unavailable")
        XCTAssertGreaterThanOrEqual(snapshot.buckets.count, 2)
        XCTAssertTrue(snapshot.buckets.contains { $0.windowMinutes == 300 })
        XCTAssertTrue(snapshot.buckets.contains { $0.windowMinutes == 10_080 })
    }
}
