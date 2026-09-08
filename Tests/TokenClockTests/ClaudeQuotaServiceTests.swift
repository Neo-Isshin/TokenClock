import Foundation
import XCTest
@testable import TokenClock

final class ClaudeQuotaServiceTests: XCTestCase {
    func testDecodesAccountProfileAndDetailedMaxTier() throws {
        let data = Data(#"{"oauthAccount":{"accountUuid":"account-1","emailAddress":"person@example.com","userRateLimitTier":"default_claude_max_20x"}}"#.utf8)
        let profile = try XCTUnwrap(ClaudeQuotaService.decodeAccountProfile(data))
        XCTAssertEqual(profile.id, "account-1")
        XCTAssertEqual(profile.email, "person@example.com")
        XCTAssertEqual(
            ClaudeQuotaService.detailedPlan(subscriptionType: "max", rateLimitTier: profile.rateLimitTier),
            "max_20x"
        )
    }
}
