import Foundation
import XCTest
@testable import TokenClock

final class AntigravityQuotaRingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private func bucket(_ id: String, used: Double, minutes: Int = 10_080, reset: Double) -> CodexQuotaBucket {
        .init(id: id, name: minutes == 300 ? "Five hour" : "Weekly", usedPercent: used, windowMinutes: minutes,
              resetsAt: now.addingTimeInterval(reset))
    }
    private var groups: [ProviderQuotaGroup] {
        [.init(id: "gemini", name: "Gemini Models", buckets: [bucket("gemini-weekly", used: 10, reset: 10_000), bucket("gemini-5h", used: 20, minutes: 300, reset: 1_000)]),
         .init(id: "other", name: "Claude and GPT models", buckets: [bucket("3p-weekly", used: 30, reset: 20_000), bucket("3p-5h", used: 40, minutes: 300, reset: 2_000)]),
         .init(id: "argon", name: "Gemini 4 Argon", buckets: [bucket("gemini-argon-wtu-weekly", used: 80, reset: 30_000)])]
    }

    func testThreePoolsRemainIndependentAndArgonDoesNotLowerLegacyGemini() throws {
        let result = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: groups))
        XCTAssertEqual(result.outerRemainingPercent, 90)
        XCTAssertEqual(result.innerRemainingPercent, 70)
        XCTAssertEqual(result.thirdRemainingPercent, 20)
        XCTAssertEqual(result.details.count, 5)
        XCTAssertEqual(result.details.last?.labelKey, "quota.dial.geminiArgonWeekly")
        XCTAssertFalse(result.details.contains { $0.labelKey == "quota.dial.geminiArgonFiveHour" })
    }

    func testLegacyTwoPoolAndMissingPoolResponsesDoNotInventExtraRings() throws {
        let legacy = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: Array(groups.prefix(2))))
        XCTAssertEqual(legacy.outerRemainingPercent, 90)
        XCTAssertEqual(legacy.innerRemainingPercent, 70)
        XCTAssertNil(legacy.thirdRemainingPercent)
        let onlyArgon = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: [groups[2]]))
        XCTAssertEqual(onlyArgon.outerRemainingPercent, 20)
        XCTAssertNil(onlyArgon.innerRemainingPercent)
        XCTAssertNil(onlyArgon.thirdRemainingPercent)
    }

    func testBucketMarkersSplitMixedGroupsAndZeroRemainsARealQuota() throws {
        var mixed = groups[0]
        mixed = .init(id: mixed.id, name: mixed.name, buckets: mixed.buckets + [bucket("gemini-argon-weekly", used: 100, reset: 30_000)])
        let result = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: [mixed, groups[1]]))
        XCTAssertEqual(result.outerRemainingPercent, 90)
        XCTAssertEqual(result.thirdRemainingPercent, 0)
        let invalid = ProviderQuotaGroup(id: "argon", name: "Gemini 4 Argon", buckets: [bucket("argon", used: .nan, reset: 1)])
        XCTAssertNil(DialQuotaResolver.resolve(provider: .antigravity, groups: Array(groups.prefix(2)) + [invalid])?.thirdRemainingPercent)
    }

    func testArgonResetDoesNotLeakIntoLegacyGeminiWhenPercentagesMatch() throws {
        let equalArgon = ProviderQuotaGroup(id: "argon", name: "Gemini 4 Argon", buckets: [bucket("argon-weekly", used: 10, reset: 30_000)])
        let values = Array(groups.prefix(2)) + [equalArgon]
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: values))
        let resets = StatusSummaryQuotaResets.rows(for: indicator, groups: values, now: now)
        let legacy = resets.filter { $0.labelKey == "quota.dial.geminiWeekly" }
        let argon = resets.filter { $0.labelKey == "quota.dial.geminiArgonWeekly" }
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.resetsAt, now.addingTimeInterval(10_000))
        XCTAssertEqual(argon.count, 1)
        XCTAssertEqual(argon.first?.resetsAt, now.addingTimeInterval(30_000))
    }

    func testSummaryReceivesThirdPoolAndItsRealResetOnly() throws {
        let summary = try XCTUnwrap(StatusSummaryQuotas.indicators(records: [], activeIDs: [:],
            freshGroups: [.antigravity: groups], now: now).first)
        XCTAssertEqual(summary.indicator.thirdRemainingPercent, 20)
        XCTAssertEqual(summary.resets.count, 5)
        XCTAssertEqual(summary.resets.last?.resetsAt, now.addingTimeInterval(30_000))
    }

    func testDecodesThreeGroupsFromLocalServiceResponse() throws {
        let raw = Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.9,"resetTime":"2026-10-31T09:04:53Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.7,"resetTime":"2026-11-04T15:05:34Z"}]},{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":0.2,"resetTime":"2026-10-30T07:22:00Z"}]}]}}"#.utf8)
        let snapshot = try XCTUnwrap(AntigravityQuotaService.decodeResponse(raw, now: now))
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: .antigravity, groups: snapshot.groups))
        XCTAssertEqual(indicator.outerRemainingPercent, 90, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(indicator.thirdRemainingPercent), 20, accuracy: 0.00001)
    }

    func testDialSizesAndSpacingGrowWhileRemainingCenteredAndInsideFace() {
        for size in ClockSize.allCases {
            let layout = ClockQuotaLayout(diameter: size.diameter, count: 2, scale: size.scale)
            XCTAssertGreaterThan(layout.ringSize, 29 * size.scale)
            XCTAssertGreaterThan(layout.spacing, 5 * size.scale)
            XCTAssertEqual(layout.frame(at: 1).minY - layout.frame(at: 0).maxY, layout.spacing, accuracy: 0.00001)
            XCTAssertEqual(layout.frame(at: 0).midY + layout.frame(at: 1).midY, size.diameter, accuracy: 0.00001)
            XCTAssertTrue(CGRect(x: 0, y: 0, width: size.diameter, height: size.diameter).contains(layout.frame(at: 0)))
            let single = ClockQuotaLayout(diameter: size.diameter, count: 1, scale: size.scale)
            XCTAssertGreaterThan(single.ringSize, layout.ringSize)
            XCTAssertEqual(single.frame(at: 0).midY, size.diameter / 2, accuracy: 0.00001)
        }
    }
}
