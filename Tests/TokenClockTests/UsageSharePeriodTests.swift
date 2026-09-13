import Foundation
import XCTest
@testable import TokenClock

final class UsageSharePeriodTests: XCTestCase {
    func testRecentMonthAndNaturalWeekBoundaries() {
        let september = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let recent = UsageSharePeriod.recent(days: 7, ending: september).bounds
        XCTAssertEqual(DateHelper.dateKey(from: recent.start), "2026-09-05")
        XCTAssertEqual(DateHelper.dateKey(from: recent.end), "2026-09-11")

        let week = UsageSharePeriod.weekOfMonth(containing: september, index: 2).bounds
        XCTAssertEqual(DateHelper.dateKey(from: week.start), "2026-09-07")
        XCTAssertEqual(DateHelper.dateKey(from: week.end), "2026-09-13")

        let february = Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 12))!
        let month = UsageSharePeriod.month(containing: february).bounds
        XCTAssertEqual(DateHelper.dateKey(from: month.start), "2024-02-01")
        XCTAssertEqual(DateHelper.dateKey(from: month.end), "2024-02-29")

        let mondayFirst = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let firstWeek = UsageSharePeriod.weekOfMonth(containing: mondayFirst, index: 1).bounds
        XCTAssertEqual(DateHelper.dateKey(from: firstWeek.start), "2026-06-01")
        XCTAssertEqual(DateHelper.dateKey(from: firstWeek.end), "2026-06-07")
    }

    func testStaleAndAlreadyResetQuotasAreNeverLiveDialData() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let group = ProviderQuotaGroup(id: "g", name: "Subscription", buckets: [
            CodexQuotaBucket(id: "live", name: "Codex", usedPercent: 34,
                             windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600)),
            CodexQuotaBucket(id: "reset", name: "Codex", usedPercent: 37,
                             windowMinutes: 300, resetsAt: now.addingTimeInterval(-1)),
        ])
        XCTAssertTrue(DialQuotaResolver.freshGroups(
            [group], refreshedAt: now.addingTimeInterval(-16 * 60), now: now
        ).isEmpty)
        XCTAssertEqual(
            DialQuotaResolver.freshGroups(
                [group], refreshedAt: now.addingTimeInterval(-5 * 60), now: now
            ).first?.buckets.map(\.id), ["live"]
        )
    }
}
