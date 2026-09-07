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

    func testHistoricalCursorVendorPrefixesCollapseWithoutRewritingHistory() {
        let sessions = [
            DaySnapshot.Tool.Session(
                id: "grok", displayName: "grok", tokens: 44, messages: 1, isActive: false,
                model: "cursor-grok-4.6-high-fast", cost: .unavailable, cacheReadTokens: 6
            ),
            DaySnapshot.Tool.Session(
                id: "chatgpt", displayName: "chatgpt", tokens: 56, messages: 1, isActive: false,
                model: "cursor-chatgpt-high", cost: .unavailable, cacheReadTokens: 4
            ),
        ]
        let cursor = DaySnapshot.Tool(
            name: "Cursor Agent", tokens: 100, messages: 2, cacheRate: 10.0 / 110.0,
            isActive: false, cost: .unavailable, cacheReadTokens: 10, sessions: sessions
        )
        let snapshot = DaySnapshot(
            date: "2026-08-30", totalTokens: 100, totalMessages: 2, tools: [cursor]
        )
        let data = UsageOverviewBuilder.make(
            startDate: date("2026-08-30"), endDate: date("2026-08-30"),
            snapshots: [snapshot], grouping: .model
        )

        XCTAssertEqual(data.rows.map(\.name), ["chatgpt", "grok-4.6"])
        XCTAssertEqual(data.rows.map(\.emoji), ["💫", "🪐"])
        XCTAssertEqual(data.rows.reduce(0) { $0 + $1.metrics.tokens }, 100)
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
