#if os(Windows)
import Foundation
import XCTest
@testable import TokenClock

final class ClaudeQuotaServiceTests: XCTestCase {
    func testDecodesSubscriptionWindows() throws {
        let payload = #"{"five_hour":{"utilization":25},"seven_day":{"utilization":"70"},"seven_day_opus":{"utilization":90}}"#
        let snapshot = try XCTUnwrap(ClaudeQuotaService.decodeUsageResponse(Data(payload.utf8), planType: "max"))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["claude:five_hour", "claude:seven_day", "claude:seven_day_opus"])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [75, 30, 10])
    }

    func testDecodesCredentialAndWindowsPath() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"secret","subscriptionType":"pro"}}"#.utf8)
        XCTAssertEqual(try XCTUnwrap(ClaudeQuotaService.decodeCredentialPayload(data)).subscriptionType, "pro")
        let paths = ClaudeQuotaService.credentialCandidatePaths(
            environment: ["CLAUDE_CONFIG_DIR": "D:\\Claude"], homeDirectory: "C:\\Users\\neo",
            configuredClaudeHome: "D:\\Claude"
        )
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasSuffix(".credentials.json"))
    }
}
#endif
