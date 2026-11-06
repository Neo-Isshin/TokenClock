import Foundation
import XCTest
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif
@testable import TokenClock

final class ZCodeRecentLedgerTests: XCTestCase {
    func testRecentKeyFilteringKeepsExactAllHistoryAttemptRanking() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE model_usage (logical_request_id TEXT, attempt_index INTEGER, status TEXT, completed_at INTEGER, first_token_at INTEGER, started_at INTEGER);", nil, nil, nil), SQLITE_OK)
        func add(_ id: String?, _ attempt: Int?, _ end: Int, status: String = "completed", timed: Bool = true) {
            let sql = "INSERT INTO model_usage VALUES (\(id.map { "'" + $0 + "'" } ?? "NULL"),\(attempt.map(String.init) ?? "NULL"),'\(status)',\(end),\(timed ? String(end - 10) : "NULL"),\(end - 20))"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        add("future", 1, 950); add("future", 2, 1100)
        add("rewind", 1, 950); add("rewind", 10, 100)
        add("missing-timing", 1, 950); add("missing-timing", 2, 960, timed: false)
        add("normal", 1, 930); add("normal", 2, 960)
        add("failed-retry", 1, 950); add("failed-retry", 2, 980, status: "failed")
        add(nil, nil, 955); add(nil, nil, 956)
        add("unranked", nil, 957); add("unranked", nil, 958)
        for index in 0..<2000 { add("history-\(index)", index % 3, 50) }
        func rows(_ prefix: String) throws -> [Int64] {
            let sql = prefix + " SELECT ledger_rowid FROM latest_completed r JOIN model_usage m ON m.rowid=r.ledger_rowid WHERE completion_rank=1 AND m.completed_at>=?1 AND m.completed_at<=?2 AND m.first_token_at IS NOT NULL AND m.completed_at>m.first_token_at ORDER BY ledger_rowid"
            var query: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &query, nil), SQLITE_OK)
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int(query, 1, 900); sqlite3_bind_int(query, 2, 1000)
            var result: [Int64] = [], step = sqlite3_step(query)
            while step == SQLITE_ROW { result.append(sqlite3_column_int64(query, 0)); step = sqlite3_step(query) }
            XCTAssertEqual(step, SQLITE_DONE)
            return result
        }
        let original = try rows(ZCodeLedger.latestCompletedRowsSQL)
        XCTAssertEqual(try rows(ZCodeLedger.recentCompletedRowsSQL), original)
        XCTAssertEqual(original.count, 6)
        XCTAssertFalse(original.contains(1)); XCTAssertFalse(original.contains(3)); XCTAssertFalse(original.contains(5))
    }
}
