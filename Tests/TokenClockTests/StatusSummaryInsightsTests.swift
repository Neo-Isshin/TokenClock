import Foundation
import XCTest
@testable import TokenClock

final class StatusSummaryInsightsTests: XCTestCase {
    private let day = "2026-10-28", previous = "2026-10-27"
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10, minute: 30))! }

    private func tool(_ tokens: Int, cache: Int? = 0, cost: Double = 0, name: String = "Codex", complete: Bool = true) -> DaySnapshot.Tool {
        .init(name: name, tokens: tokens, messages: 1, cacheRate: 0, isActive: false,
              cost: CostEstimate(value: cost, complete: complete), cacheReadTokens: cache, sessions: [])
    }
    private func snapshot(_ key: String, _ tool: DaySnapshot.Tool) -> DaySnapshot {
        .init(date: key, totalTokens: tool.tokens, totalMessages: tool.messages, tools: [tool])
    }
    private func live(_ tokens: Int = 150, cache: Int = 140, cost: Double = 3) -> ToolUsage {
        var result = ToolUsage(name: "Codex", abbreviation: "CX", emoji: "", todayTokens: tokens,
            todayMessages: 2, isActive: false, recentTokens: 0, hourlyTokens: 0)
        result.todayCacheReadTokens = cache; result.todayCost = CostEstimate(value: cost)
        return result
    }
    private func comparison(incompleteCost: Bool = false) -> StatusSummaryComparisonData {
        .build(day: day, today: [snapshot(day + "-00", tool(50, cache: 100, cost: 1, complete: !incompleteCost)),
            snapshot(day + "-10", tool(100, cache: 40, cost: 2))],
            yesterday: [snapshot(previous + "-00", tool(100, cost: 2)), snapshot(previous + "-10", tool(200, cache: 30, cost: 4))],
            daily: [snapshot(previous, tool(300, cache: 30, cost: 6))])
    }

    func testComparisonExcludesUnfinishedHourAndUsesSameCacheBasis() throws {
        let fresh = comparison().compare(to: [live()], includesCache: false, now: now, calendar: calendar)
        XCTAssertEqual(fresh.completedHours, 10)
        XCTAssertEqual(fresh.sourceCount, 1)
        XCTAssertEqual(try XCTUnwrap(fresh.tokenDelta?.percent), -50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fresh.costDelta?.percent), -50, accuracy: 0.001)
        let inclusive = comparison().compare(to: [live()], includesCache: true, now: now, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(inclusive.tokenDelta?.percent), 50, accuracy: 0.001)
        XCTAssertEqual(inclusive.costDelta, fresh.costDelta)
    }

    func testIncompleteHoursOrCacheDoNotBecomeZeroBaseline() {
        XCTAssertNil(comparison().compare(to: [live(151)], includesCache: false, now: now, calendar: calendar).tokenDelta)
        var missingCache = comparison()
        missingCache.yesterdayTotals["Codex"]?.cache = nil
        XCTAssertNil(missingCache.compare(to: [live()], includesCache: true, now: now, calendar: calendar).tokenDelta)
        XCTAssertNotNil(missingCache.compare(to: [live()], includesCache: false, now: now, calendar: calendar).tokenDelta)
    }

    func testMissingPricesSuppressOnlyCostChange() {
        let result = comparison(incompleteCost: true).compare(to: [live()], includesCache: false, now: now, calendar: calendar)
        XCTAssertNotNil(result.tokenDelta)
        XCTAssertNil(result.costDelta)
        XCTAssertNil(comparison().compare(to: [live(cost: 4)], includesCache: false, now: now, calendar: calendar).costDelta)
    }

    func testMidnightWrongDayAndNewUsageDoNotProduceMisleadingPercentages() {
        let midnight = calendar.startOfDay(for: now).addingTimeInterval(1_800)
        XCTAssertNil(comparison().compare(to: [live()], includesCache: false, now: midnight, calendar: calendar).tokenDelta)
        XCTAssertNil(comparison().compare(to: [live()], includesCache: false, now: now.addingTimeInterval(86_400), calendar: calendar).tokenDelta)
        let newUsage = StatusSummaryComparisonData.build(day: day, today: [snapshot(day + "-00", tool(50))],
            yesterday: [], daily: [snapshot(previous, tool(0))])
            .compare(to: [live(50, cache: 0, cost: 0)], includesCache: false, now: now, calendar: calendar)
        XCTAssertEqual(newUsage.tokenDelta?.current, 50)
        XCTAssertEqual(newUsage.tokenDelta?.previous, 0)
        XCTAssertNil(newUsage.tokenDelta?.percent)
        XCTAssertEqual(StatusSummaryComparisonData.previousDay("2027-01-01"), "2026-12-31")
    }

    func testPartialSourceCoverageIsExplicit() {
        var other = live(); other = ToolUsage(name: "Other", abbreviation: "O", emoji: "", todayTokens: 100,
            todayMessages: 1, isActive: false, recentTokens: 0, hourlyTokens: 0)
        let result = comparison().compare(to: [live(), other], includesCache: false, now: now, calendar: calendar)
        XCTAssertEqual(result.sourceCount, 1)
        XCTAssertTrue(result.isPartial)
    }

    func testCacheShareDoesNotDoubleCountWhenIncludeCacheIsEnabled() throws {
        let value = live(100, cache: 900)
        let excluding = StatusSummarySnapshot(tools: [value], includesCache: false)
        let including = StatusSummarySnapshot(tools: [value], includesCache: true)
        XCTAssertEqual(excluding.cacheReadTokens, 900)
        XCTAssertEqual(try XCTUnwrap(excluding.cacheShare), 0.9, accuracy: 0.00001)
        XCTAssertEqual(including.cacheShare, excluding.cacheShare)
        XCTAssertNil(StatusSummarySnapshot(tools: [], includesCache: false).cacheShare)
        var credits = value; credits.measurementUnit = .credits
        XCTAssertEqual(StatusSummarySnapshot(tools: [value, credits], includesCache: true).cacheReadTokens, 900)
    }

    private func account(_ provider: SubscriptionProvider = .codex, user: String = "user", shared: Bool = false) -> SubscriptionAccountRecord {
        .init(provider: provider, accountID: user, email: nil, note: "Main", detectedPlan: nil, manualPlan: nil,
            groups: [.init(id: shared ? StatusSummaryQuotas.sharedGroupID : "weekly", name: "Subscription", buckets: [
                .init(id: "weekly", name: "Weekly", usedPercent: 20, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(1_000))])],
            refreshedAt: now, source: "fixture", creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
    }
    private func quota(_ record: SubscriptionAccountRecord) -> StatusSummaryQuota {
        .init(indicator: .init(provider: record.provider, outerRemainingPercent: 80, innerRemainingPercent: nil, details: []), isShared: false)
    }

    func testTimelineSortsAndCombinesSameResetAndPreservesManualDatePrecision() {
        var record = account()
        let original = record.groups[0].buckets[0]
        record.groups[0] = .init(id: "weekly", name: "Subscription", buckets: [original,
            .init(id: "other", name: "Other weekly", usedPercent: 30, windowMinutes: 10_080, resetsAt: original.resetsAt)])
        record.manualBilling = .init(date: now.addingTimeInterval(86_400), cycle: .monthly, autoRenews: false, source: "manual", observedAt: now)
        let events = StatusSummaryTimeline.events(quotas: [quota(record)], records: [record], activeIDs: [.codex: record.id], now: now, calendar: calendar)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .reset)
        XCTAssertTrue(events[0].detail.contains("Other weekly"))
        XCTAssertEqual(events[1].kind, .expiry)
        XCTAssertTrue(events[1].dateOnly)
    }

    func testTimelineIgnoresStaleQuotaAndDoesNotAdvancePastDetectedRenewal() {
        var record = account(); record.refreshedAt = now.addingTimeInterval(-3_600)
        record.detectedBilling = .init(date: now.addingTimeInterval(-1), cycle: .monthly, autoRenews: true, source: "API", observedAt: now)
        XCTAssertTrue(StatusSummaryTimeline.events(quotas: [quota(record)], records: [record], activeIDs: [.codex: record.id], now: now).isEmpty)
        record.refreshedAt = now
        XCTAssertTrue(StatusSummaryTimeline.events(quotas: [quota(record)], records: [record], activeIDs: [.codex: "other"], now: now).isEmpty)
    }

    func testSharedBillingUsesOnlyManualDatesAndDeduplicatesConfirmedAliases() {
        var cursor = account(.cursor, shared: true), bot = account(.grokBot, shared: true)
        cursor.detectedBilling = .init(date: now.addingTimeInterval(86_400), cycle: .monthly, autoRenews: true, source: "legacy API", observedAt: now)
        XCTAssertTrue(StatusSummaryTimeline.events(quotas: [], records: [cursor], activeIDs: [:], now: now).isEmpty)
        let manual = SubscriptionBillingInfo(date: now.addingTimeInterval(86_400), cycle: .monthly, autoRenews: true, source: "manual", observedAt: now)
        cursor.manualBilling = manual; bot.manualBilling = manual
        let events = StatusSummaryTimeline.events(quotas: [], records: [cursor, bot], activeIDs: [:], now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .renewal)
        XCTAssertEqual(events.first?.name, "X Subscription")
    }
}
