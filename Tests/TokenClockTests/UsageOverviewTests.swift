import XCTest
@testable import TokenClock

final class UsageOverviewTests: XCTestCase {
    func testIncludeCacheChangesDisplayedTotalsAndBreakdownOrder() {
        let snapshot = DaySnapshot(
            date: "2026-08-20",
            totalTokens: 150,
            totalMessages: 2,
            tools: [
                tool("Codex", tokens: 100, cache: 0),
                tool("Claude Code", tokens: 50, cache: 200),
            ]
        )
        let normal = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: [snapshot], grouping: .tool
        )
        let includingCache = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: [snapshot], grouping: .tool, includingCacheRead: true
        )

        XCTAssertEqual(normal.summary.displayedTokens(includingCacheRead: false), 150)
        XCTAssertEqual(includingCache.summary.displayedTokens(includingCacheRead: true), 350)
        XCTAssertEqual(normal.rows.map(\.name), ["Codex", "Claude Code"])
        XCTAssertEqual(includingCache.rows.map(\.name), ["Claude Code", "Codex"])
    }

    private func tool(_ name: String, tokens: Int, cache: Int) -> DaySnapshot.Tool {
        DaySnapshot.Tool(
            name: name, tokens: tokens, messages: 1,
            cacheRate: Double(cache) / Double(max(1, tokens + cache)), isActive: false,
            cost: .unavailable, cacheReadTokens: cache, sessions: []
        )
    }

    private func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))!
    }
}
