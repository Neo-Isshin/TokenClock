import Foundation
import XCTest
@testable import TokenClock

final class ProviderQuotaServiceTests: XCTestCase {
    func testLiveCursorQuotaWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_CURSOR_QUOTA_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_CURSOR_QUOTA_TESTS=1 to query the signed-in Cursor account")
        }
        let snapshot = CursorQuotaService().fetch()
        XCTAssertEqual(snapshot.status, .available, snapshot.message ?? "")
        let buckets = snapshot.groups.flatMap(\.buckets)
        XCTAssertEqual(buckets.map(\.name), ["Cursor Models", "Other Models"])
        let resetDiagnostics = buckets.map {
            $0.name + "=" + String(describing: $0.resetsAt)
        }
        XCTAssertTrue(buckets.allSatisfy { $0.resetsAt != nil }, "Missing reset in: \(resetDiagnostics)")
    }

    func testLiveZhipuQuotaWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_ZHIPU_QUOTA_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_ZHIPU_QUOTA_TESTS=1 to query the signed-in ZCode account")
        }
        let snapshot = ZhipuQuotaService().fetch()
        XCTAssertEqual(snapshot.status, .available, snapshot.message ?? "")
        XCTAssertFalse(snapshot.groups.flatMap(\.buckets).isEmpty)
        XCTAssertNotNil(snapshot.planType)
    }

    func testDecodesAntigravityQuotaGroups() throws {
        let data = Data(#"{"response":{"description":"Shared limits","groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","remainingFraction":0.75,"resetTime":"2026-08-28T06:01:58Z"},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","remainingFraction":0.5,"resetTime":"2026-08-21T20:59:36Z"}]}]}}"#.utf8)
        let snapshot = try XCTUnwrap(AntigravityQuotaService.decodeResponse(data))
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.remainingPercent), [75, 50])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.windowMinutes), [10_080, 300])
    }

    func testDecodesCursorIncludedUsage() throws {
        let data = Data(#"{"billingCycleStart":"2026-08-01T00:00:00.000Z","billingCycleEnd":"2026-09-01T00:00:00.000Z","membershipType":"pro_plus","individualUsage":{"plan":{"used":1750,"limit":7000,"totalPercentUsed":25,"apiPercentUsed":40}}}"#.utf8)
        let snapshot = try XCTUnwrap(CursorQuotaService.decodeResponse(data))
        XCTAssertEqual(snapshot.planType, "pro_plus")
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.name), ["Cursor Models", "Other Models"])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.remainingPercent), [75, 60])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.windowMinutes), [44_640, 44_640])
        XCTAssertTrue(snapshot.groups.first?.buckets.allSatisfy { $0.resetsAt != nil } == true)
    }

    func testExtractsCursorUserIDFromJWT() {
        let payload = Data(#"{"sub":"auth0|user_ABC123"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CursorQuotaService.userID(from: "header.\(payload).signature"), "user_ABC123")
    }

    func testDecodesZhipuCodingPlanQuotaWindows() throws {
        let data = Data(#"{"code":200,"msg":"ok","success":true,"data":{"level":"pro","limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":5,"remaining":995,"percentage":1,"nextResetTime":1789385500998,"usageDetails":[{"modelCode":"search-prime","usage":5}]},{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":null,"currentValue":null,"remaining":null,"percentage":100,"nextResetTime":1788334857373},{"type":"TOKENS_LIMIT","unit":6,"number":1,"usage":null,"currentValue":null,"remaining":null,"percentage":30,"nextResetTime":1788867100992}]}}"#.utf8)
        let snapshot = try XCTUnwrap(ZhipuQuotaService.decodeResponse(data))

        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.name), [
            "Monthly MCP quota", "5-hour quota", "Weekly quota",
        ])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.usedPercent), [1, 100, 30])
        XCTAssertEqual(snapshot.groups.first?.buckets.map(\.windowMinutes), [43_200, 300, 10_080])
        XCTAssertNotNil(snapshot.groups.first?.buckets.last?.resetsAt)
    }
}
