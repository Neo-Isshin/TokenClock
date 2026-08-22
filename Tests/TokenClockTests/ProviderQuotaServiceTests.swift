import Foundation
import XCTest
@testable import TokenClock

final class ProviderQuotaServiceTests: XCTestCase {
    func testDecodesAntigravityQuotaGroups() throws {
        let data = Data(#"{"response":{"description":"Shared limits","groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","remainingFraction":0.75,"resetTime":"2026-08-28T06:01:58Z"},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","remainingFraction":0.5,"resetTime":"2026-08-21T20:59:36Z"}]}]}}"#.utf8)
        let snapshot = try XCTUnwrap(AntigravityQuotaService.decodeResponse(data))
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.remainingPercent), [75, 50])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.windowMinutes), [10_080, 300])
    }

    func testDecodesCursorIncludedUsage() throws {
        let data = Data(#"{"billingCycleStart":"2026-08-01T00:00:00Z","billingCycleEnd":"2026-09-01T00:00:00Z","membershipType":"pro_plus","individualUsage":{"plan":{"used":1750,"limit":7000},"totalPercentUsed":25}}"#.utf8)
        let snapshot = try XCTUnwrap(CursorQuotaService.decodeResponse(data))
        XCTAssertEqual(snapshot.planType, "pro_plus")
        XCTAssertEqual(snapshot.groups.first?.buckets.first?.remainingPercent, 75)
    }

    func testExtractsCursorUserIDFromJWT() {
        let payload = Data(#"{"sub":"auth0|user_ABC123"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CursorQuotaService.userID(from: "header.\(payload).signature"), "user_ABC123")
    }
}


