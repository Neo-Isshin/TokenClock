import Foundation
import XCTest
@testable import TokenClock

final class StatusSummaryQuotaResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)

    private func bucket(_ id: String, _ name: String, used: Double, minutes: Int, after: Double?) -> CodexQuotaBucket {
        .init(id: id, name: name, usedPercent: used, windowMinutes: minutes, resetsAt: after.map { now.addingTimeInterval($0) })
    }
    private func rows(_ provider: SubscriptionProvider, _ groups: [ProviderQuotaGroup]) throws -> [StatusSummaryQuotaReset] {
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: provider, groups: groups))
        return StatusSummaryQuotaResets.rows(for: indicator, groups: groups, now: now)
    }

    func testWeeklyAndFiveHourResetsStaySeparateEvenAtSameTimestamp() throws {
        let groups = [ProviderQuotaGroup(id: "plan", name: "Subscription", buckets: [
            bucket("week", "Weekly", used: 30, minutes: 10_080, after: 7_200),
            bucket("short", "5-hour", used: 80, minutes: 300, after: 7_200)])]
        let result = try rows(.codex, groups)
        XCTAssertEqual(result.map(\.labelKey), ["quota.dial.weekly", "quota.dial.fiveHour"])
        XCTAssertEqual(result.map(\.resetsAt), [now.addingTimeInterval(7_200), now.addingTimeInterval(7_200)])
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }

    func testResetFollowsLimitingQuotaRatherThanUnrelatedEarlierReset() throws {
        let result = try rows(.codex, [.init(id: "plan", name: "Subscription", buckets: [
            bucket("earlier", "Weekly", used: 20, minutes: 10_080, after: 60),
            bucket("limit", "Weekly", used: 90, minutes: 10_080, after: 86_400)])])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.resetsAt, now.addingTimeInterval(86_400))
    }

    func testClaudeUsesOverallWindowsInsteadOfModelSpecificCaps() throws {
        let result = try rows(.claude, [.init(id: "claude", name: "Subscription", buckets: [
            bucket("claude:seven_day", "Weekly", used: 20, minutes: 10_080, after: 86_400),
            bucket("claude:seven_day_opus", "Opus weekly", used: 20, minutes: 10_080, after: 60),
            bucket("claude:five_hour", "5-hour", used: 40, minutes: 300, after: 3_600)])])
        XCTAssertEqual(result.map(\.resetsAt), [now.addingTimeInterval(86_400), now.addingTimeInterval(3_600)])
    }

    func testAntigravitySeparatesBothFamiliesAndBothPeriods() throws {
        let result = try rows(.antigravity, [
            .init(id: "gemini", name: "Gemini Models", buckets: [
                bucket("gw", "Weekly", used: 10, minutes: 10_080, after: 10_000),
                bucket("gs", "5-hour", used: 20, minutes: 300, after: 1_000)]),
            .init(id: "other", name: "GPT/Claude Models", buckets: [
                bucket("ow", "Weekly", used: 30, minutes: 10_080, after: 20_000),
                bucket("os", "5-hour", used: 40, minutes: 300, after: 2_000)])])
        let dates = Dictionary(uniqueKeysWithValues: result.map { ($0.labelKey, $0.resetsAt) })
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(dates["quota.dial.geminiWeekly"] ?? nil, now.addingTimeInterval(10_000))
        XCTAssertEqual(dates["quota.dial.geminiFiveHour"] ?? nil, now.addingTimeInterval(1_000))
        XCTAssertEqual(dates["quota.dial.claudeGPTWeekly"] ?? nil, now.addingTimeInterval(20_000))
        XCTAssertEqual(dates["quota.dial.claudeGPTFiveHour"] ?? nil, now.addingTimeInterval(2_000))
    }

    func testLegacyCursorKeepsSeparateModelPoolsAndActualMonthlyDates() throws {
        let result = try rows(.cursor, [.init(id: "cursor", name: "Subscription", buckets: [
            bucket("cursor", "Cursor Models", used: 10, minutes: 44_640, after: 100_000),
            bucket("other", "Other Models", used: 90, minutes: 44_640, after: 200_000)])])
        XCTAssertEqual(result.map(\.labelKey), ["quota.dial.cursorModels", "quota.dial.otherModels"])
        XCTAssertEqual(result.map(\.resetsAt), [now.addingTimeInterval(100_000), now.addingTimeInterval(200_000)])
    }

    func testUnknownAndExpiredResetsAreNotInferredFromWindowLength() throws {
        let result = try rows(.codex, [.init(id: "plan", name: "Subscription", buckets: [
            bucket("week", "Weekly", used: 10, minutes: 10_080, after: nil),
            bucket("short", "5-hour", used: 30, minutes: 300, after: -1)])])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.resetsAt == nil })
        let grok = try rows(.grokBot, [.init(id: "bot", name: "Subscription", buckets: [
            bucket("period", "Grok Bot", used: 10, minutes: 878, after: 60)])])
        XCTAssertEqual(grok.first?.title, "878m")
    }

    func testSharedPoolIgnoresLegacyPoolDatesAndUsesFreshLiveGroups() throws {
        let shared = ProviderQuotaGroup(id: StatusSummaryQuotas.sharedGroupID, name: "Shared subscription", buckets: [
            bucket("shared", "Weekly", used: 30, minutes: 10_080, after: 12_000)])
        let legacy = ProviderQuotaGroup(id: "legacy", name: "Legacy", buckets: [
            bucket("legacy", "Weekly", used: 30, minutes: 10_080, after: 60)])
        let result = StatusSummaryQuotas.indicators(records: [], activeIDs: [:], freshGroups: [.cursor: [shared, legacy]], now: now)
        XCTAssertEqual(result.first?.resets.count, 1)
        XCTAssertEqual(result.first?.resets.first?.resetsAt, now.addingTimeInterval(12_000))
    }
}
