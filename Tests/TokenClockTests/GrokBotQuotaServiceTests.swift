import Foundation
import XCTest
@testable import TokenClock

final class GrokBotQuotaServiceTests: XCTestCase {
    #if os(macOS)
    func testDecryptsElectronSafeStorageFixture() {
        XCTAssertEqual(
            GrokBotNativeCredentialStore.decryptSafeStoragePayload(
                "djEw5APYyxaXDmuSBIYmLjfxCivXhoFimiC4XKQV2XX7s3Q=",
                password: "test-password"
            ),
            "native-token-fixture"
        )
    }
    #endif

    func testDecodesIndependentWeeklyQuota() throws {
        let response = Data(#"""
        {
          "currentPeriodStart": "2026-09-05T08:41:29.934Z",
          "nextResetTimestampUtc": "2026-09-12T08:41:29.934Z",
          "usagePercent": 42.336651,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true,
          "grokPlanLabel": "Grok Bot Plan"
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(GrokBotQuotaService.decodeResponse(
            response,
            now: Date(timeIntervalSince1970: 1_788_855_689)
        ))
        XCTAssertEqual(snapshot.status, .available)
        XCTAssertNil(snapshot.planType)
        XCTAssertEqual(snapshot.source, "Cursor Grok Bot API")
        let bucket = try XCTUnwrap(snapshot.groups.first?.buckets.first)
        XCTAssertEqual(bucket.id, "grok-bot:weekly")
        XCTAssertEqual(bucket.usedPercent, 42.336651, accuracy: 0.000_001)
        XCTAssertEqual(bucket.windowMinutes, 10_080)
        XCTAssertEqual(
            try XCTUnwrap(bucket.resetsAt).timeIntervalSince1970,
            1_789_202_489.934,
            accuracy: 0.001
        )
    }

    func testRejectsResponsesWithoutAuthoritativeUsagePercent() {
        XCTAssertNil(GrokBotQuotaService.decodeResponse(Data(#"{"hasAvailableUsage":true}"#.utf8)))
    }

    func testAutomaticFetchNeverWaitsForNativeKeychainAuthorization() {
        let started = Date()
        let snapshot = GrokBotQuotaService(
            stateDatabasePath: "/tokenclock/no-cursor-ide-state.vscdb",
            environment: ["TOKENCLOCK_DISABLE_CURSOR_CREDENTIALS": "1"],
            homeDirectory: "/tokenclock/no-cursor-home"
        ).fetch()
        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCursorChecksumMatchesSandClientAlgorithm() {
        XCTAssertEqual(
            GrokBotQuotaService.cursorChecksum(
                machineID: "machine-123",
                now: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            "paaotEjtmachine-123"
        )
    }

    func testDecodesCursorAgentFileCredentialWithoutReturningRefreshToken() throws {
        let data = Data(#"{"accessToken":"cli-access-token","refreshToken":"do-not-return"}"#.utf8)
        XCTAssertEqual(GrokBotQuotaService.decodeCLIAuthFile(data), "cli-access-token")
        XCTAssertNil(GrokBotQuotaService.decodeCLIAuthFile(Data(#"{"refreshToken":"only"}"#.utf8)))
    }

    func testLiveCursorBackedGrokBotQuotaWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_GROK_BOT_QUOTA_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_GROK_BOT_QUOTA_TESTS=1 to query the signed-in Cursor account")
        }
        let snapshot = GrokBotQuotaService(stateDatabasePath: "/tokenclock/no-cursor-ide-state.vscdb").fetch()
        XCTAssertEqual(snapshot.status, .available, snapshot.message ?? "")
        XCTAssertFalse(snapshot.groups.flatMap(\.buckets).isEmpty)
        XCTAssertEqual(snapshot.account?.id.isEmpty, false)
        XCTAssertTrue(snapshot.source.contains("Cursor Agent CLI"), snapshot.source)
    }
}
