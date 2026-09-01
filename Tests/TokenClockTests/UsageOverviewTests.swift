import XCTest
@testable import TokenClock
#if os(macOS)
import SQLite3
#endif

final class UsageOverviewTests: XCTestCase {
    func testEmptySnapshotsDoNotProduceZeroRowsOrZeroDollarClaim() {
        let emptyTool = DaySnapshot.Tool(
            name: "Codex", tokens: 0, messages: 0, cacheRate: 0, isActive: false,
            cost: .zero, cacheReadTokens: nil, sessions: []
        )
        let data = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: [day("2026-08-20", tools: [emptyTool])], grouping: .tool
        )
        XCTAssertTrue(data.rows.isEmpty)
        XCTAssertFalse(data.summary.cost.available)
        XCTAssertFalse(data.containsUnavailableCost)
        XCTAssertFalse(data.containsLegacyCacheEstimate)
    }

    func testToolOverviewUsesWeightedCacheAndPreservesCostCoverage() {
        let snapshots = [
            day("2026-08-19", tools: [
                tool("Codex", tokens: 100, messages: 2, cache: 100,
                     cost: .init(value: 1, complete: true, available: true)),
            ]),
            day("2026-08-20", tools: [
                tool("Codex", tokens: 900, messages: 8, cache: 0,
                     cost: .init(value: 3, complete: true, available: true)),
                tool("OpenCode", tokens: 50, messages: 1, cache: 50, cost: .unavailable),
            ]),
        ]
        let data = UsageOverviewBuilder.make(
            startDate: date("2026-08-19"), endDate: date("2026-08-20"),
            snapshots: snapshots, grouping: .tool
        )

        XCTAssertEqual(data.summary.tokens, 1_050)
        XCTAssertEqual(data.summary.messages, 11)
        XCTAssertEqual(data.summary.cacheReadTokens, 150)
        XCTAssertEqual(data.summary.averageCacheRate, 0.125, accuracy: 0.000_1)
        XCTAssertEqual(data.summary.cost.value, 4, accuracy: 0.000_1)
        XCTAssertFalse(data.summary.cost.complete)
        XCTAssertEqual(data.rows.map(\.name), ["Codex", "OpenCode"])
    }

    func testIncludeCacheChangesDisplayedTotalsAndBreakdownOrder() {
        let snapshots = [day("2026-08-20", tools: [
            tool("Codex", tokens: 100, messages: 1, cache: 0, cost: .unavailable),
            tool("Claude Code", tokens: 50, messages: 1, cache: 200, cost: .unavailable),
        ])]
        let normal = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: snapshots, grouping: .tool
        )
        let includingCache = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: snapshots, grouping: .tool, includingCacheRead: true
        )

        XCTAssertEqual(normal.summary.displayedTokens(includingCacheRead: false), 150)
        XCTAssertEqual(includingCache.summary.displayedTokens(includingCacheRead: true), 350)
        XCTAssertEqual(normal.rows.map(\.name), ["Codex", "Claude Code"])
        XCTAssertEqual(includingCache.rows.map(\.name), ["Claude Code", "Codex"])
    }

    func testModelOverviewKeepsUnattributedResidualInUnknown() {
        let sessions = [
            DaySnapshot.Tool.Session(
                id: "1", displayName: "1", tokens: 70, messages: 2, isActive: false,
                model: "gpt-5-2026-08-01", cost: .init(value: 0.7, complete: true, available: true),
                cacheReadTokens: 20
            ),
        ]
        let snapshots = [day("2026-08-20", tools: [
            DaySnapshot.Tool(
                name: "Codex", tokens: 100, messages: 3, cacheRate: 0.2, isActive: false,
                cost: .init(value: 1, complete: true, available: true),
                cacheReadTokens: 30, sessions: sessions
            ),
        ])]
        let data = UsageOverviewBuilder.make(
            startDate: date("2026-08-20"), endDate: date("2026-08-20"),
            snapshots: snapshots, grouping: .model
        )

        XCTAssertTrue(data.containsUnknownModel)
        XCTAssertEqual(data.rows.reduce(0) { $0 + $1.metrics.tokens }, 100)
        XCTAssertEqual(data.rows.first(where: { $0.name == "gpt-5" })?.metrics.tokens, 70)
        XCTAssertEqual(data.rows.first(where: { $0.name == "Unknown" })?.metrics.tokens, 30)
        XCTAssertEqual(data.rows.first(where: { $0.name == "Unknown" })?.metrics.cacheReadTokens, 10)
    }

    func testHistoricalCursorModelsDropRouteMarkersWithoutRewritingHistory() {
        let aliases = [
            DaySnapshot.Tool.Session(
                id: "1", displayName: "1", tokens: 60, messages: 1, isActive: false,
                model: "claude-fable-5-thinking-medium", cost: .unavailable,
                cacheReadTokens: 10
            ),
            DaySnapshot.Tool.Session(
                id: "2", displayName: "2", tokens: 40, messages: 1, isActive: false,
                model: "claude-fable-5-high-thinking-fast", cost: .unavailable,
                cacheReadTokens: 5
            ),
        ]
        let cursor = DaySnapshot.Tool(
            name: "Cursor Agent", tokens: 100, messages: 2, cacheRate: 15.0 / 115.0,
            isActive: false, cost: .unavailable, cacheReadTokens: 15, sessions: aliases
        )
        let data = UsageOverviewBuilder.make(
            startDate: date("2026-08-30"), endDate: date("2026-08-30"),
            snapshots: [day("2026-08-30", tools: [cursor])], grouping: .model
        )

        XCTAssertEqual(data.rows.map(\.name), ["claude-fable-5"])
        XCTAssertEqual(data.rows.first?.metrics.tokens, 100)
        XCTAssertEqual(data.rows.first?.metrics.messages, 2)
    }

    func testHistoryStoreRoundTripsExtendedFieldsAndReadsLegacySessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClockOverviewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(path: directory.appendingPathComponent("history.sqlite"))
        let session = SessionSnapshot(
            id: "s", displayName: "session", tokens: 45, messages: 3, isActive: true,
            model: "claude-opus-4-1", cost: .init(value: 0.5, complete: true, available: true),
            cacheReadTokens: 12
        )
        store.upsertDay(dateKey: "2026-08-20", snapshots: [
            ToolSnapshot(
                name: "Claude Code", tokens: 45, messages: 3, cacheRate: 12.0 / 57.0,
                isActive: true, cost: .init(value: 0.5, complete: true, available: true),
                cacheReadTokens: 12, sessions: [session]
            ),
        ])
        let row = try XCTUnwrap(store.query(from: "2026-08-20", through: "2026-08-20").first?.tools.first)
        XCTAssertEqual(row.cacheReadTokens, 12)
        XCTAssertEqual(row.cost.value, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(row.sessions.first?.model, "claude-opus-4-1")
        XCTAssertEqual(row.sessions.first?.cacheReadTokens, 12)

        let legacy = HistoryStore.decodeSessions(
            #"[{"id":"old","displayName":"old","tokens":9,"messages":1,"isActive":false}]"#
        )
        XCTAssertNil(legacy.first?.model)
        XCTAssertNil(legacy.first?.cacheReadTokens)
        XCTAssertFalse(legacy.first?.cost.available ?? true)
    }

#if os(macOS)
    func testHistoryStoreMigratesLegacySchemaBeforeWritingExtendedRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClockLegacyHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE daily_snapshots (
              date_key TEXT NOT NULL, tool_name TEXT NOT NULL, tokens INTEGER NOT NULL,
              messages INTEGER NOT NULL, cache_rate REAL NOT NULL DEFAULT 0,
              is_active INTEGER NOT NULL DEFAULT 0, settled_at TEXT NOT NULL,
              sessions_json TEXT NOT NULL DEFAULT '[]', PRIMARY KEY(date_key, tool_name)
            );
            INSERT INTO daily_snapshots VALUES
              ('2026-08-19','Codex',90,2,0.25,0,'2026-08-19T23:59:00Z','[]');
            """, nil, nil, nil)
        sqlite3_close(db)

        let store = HistoryStore(path: path)
        XCTAssertTrue(
            store.query(from: "2026-08-19", through: "2026-08-19").isEmpty,
            "Codex rows written before replay-safe accounting must stay stored but be hidden"
        )
        store.upsertDay(dateKey: "2026-08-20", snapshots: [
            ToolSnapshot(name: "Codex", tokens: 100, messages: 3, cacheRate: 0.2,
                         isActive: false, cost: .init(value: 1, complete: true, available: true),
                         cacheReadTokens: 25)
        ])
        let fresh = try XCTUnwrap(store.query(from: "2026-08-20", through: "2026-08-20").first?.tools.first)
        XCTAssertEqual(fresh.cacheReadTokens, 25)
        XCTAssertEqual(fresh.cost.value, 1, accuracy: 0.0001)
    }
#endif

    func testReportNotificationRouteUsesExactCustomRange() {
        XCTAssertEqual(
            UsageOverviewRoute.reportRange(startDateKey: "2026-08-24", endDateKey: "2026-08-30"),
            .custom(startDateKey: "2026-08-24", endDateKey: "2026-08-30")
        )
        XCTAssertEqual(
            UsageOverviewRoute.reportRange(startDateKey: "2026-08-30", endDateKey: "2026-08-30"),
            .custom(startDateKey: "2026-08-30", endDateKey: "2026-08-30")
        )
    }

    private func tool(
        _ name: String, tokens: Int, messages: Int, cache: Int,
        cost: CostEstimate
    ) -> DaySnapshot.Tool {
        DaySnapshot.Tool(
            name: name, tokens: tokens, messages: messages,
            cacheRate: Double(cache) / Double(max(1, tokens + cache)), isActive: false,
            cost: cost, cacheReadTokens: cache, sessions: []
        )
    }

    private func day(_ key: String, tools: [DaySnapshot.Tool]) -> DaySnapshot {
        DaySnapshot(
            date: key,
            totalTokens: tools.reduce(0) { $0 + $1.tokens },
            totalMessages: tools.reduce(0) { $0 + $1.messages },
            tools: tools
        )
    }

    private func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))!
    }
}
