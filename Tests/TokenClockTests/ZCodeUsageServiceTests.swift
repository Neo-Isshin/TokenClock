import XCTest
@testable import TokenClock
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

final class ZCodeUsageServiceTests: XCTestCase {
    func testRealZCodeDatabaseWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_REAL_ZCODE_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_REAL_ZCODE_TESTS=1 to scan local ZCode data")
        }
        let service = ZCodeUsageService()
        service.fullScan()
        XCTAssertGreaterThan(service.dailyData.values.reduce(0) { $0 + $1.tokens }, 0)
        XCTAssertGreaterThan(service.dailyData.values.reduce(0) { $0 + $1.messages }, 0)
        XCTAssertGreaterThan(service.dailyCache.values.reduce(0, +), 0)
    }

    func testReadsAuthoritativeBucketsAndDeduplicatesCompletedAttempts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZCodeUsageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("db.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE session (
          id TEXT PRIMARY KEY, title TEXT, directory TEXT, task_type TEXT
        );
        CREATE TABLE model_usage (
          id TEXT PRIMARY KEY, logical_request_id TEXT, attempt_index INTEGER,
          session_id TEXT, model_id TEXT, status TEXT, started_at INTEGER,
          completed_at INTEGER, input_tokens INTEGER, output_tokens INTEGER,
          reasoning_tokens INTEGER, cache_creation_input_tokens INTEGER,
          cache_read_input_tokens INTEGER
        );
        INSERT INTO session VALUES ('sess-main','Main task','/tmp/project','interactive');
        """)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        insert(db, id: "one", logical: "request-one", attempt: 0, session: "sess-main",
               model: "GLM-5.3", status: "completed", time: now,
               input: 1_000, output: 100, reasoning: 50, cacheWrite: 30, cacheRead: 800)
        insert(db, id: "retry-old", logical: "request-retry", attempt: 0, session: "sess-main",
               model: "GLM-5.3-Flash", status: "completed", time: now + 1,
               input: 100, output: 10, reasoning: 0, cacheWrite: 0, cacheRead: 40)
        insert(db, id: "retry-new", logical: "request-retry", attempt: 1, session: "sess-main",
               model: "GLM-5.3-Flash", status: "completed", time: now + 2,
               input: 200, output: 20, reasoning: 5, cacheWrite: 10, cacheRead: 150)
        insert(db, id: "error", logical: "request-error", attempt: 0, session: "sess-main",
               model: "GLM-5.3", status: "error", time: now + 3,
               input: 9_999, output: 9_999, reasoning: 0, cacheWrite: 0, cacheRead: 0)

        let service = ZCodeUsageService(zcodeHome: dbURL.path)
        service.fullScan()

        let usage = service.todayUsage()
        // request-one: (1000-800)+100+50+30 = 380
        // latest retry: (200-150)+20+5+10 = 85
        XCTAssertEqual(usage.tokens, 465)
        XCTAssertEqual(usage.messages, 2)
        XCTAssertEqual(service.todayCacheReadTokens(), 950)
        XCTAssertEqual(usage.cacheRate, 950.0 / 1_415.0, accuracy: 0.000_001)
        XCTAssertEqual(service.todayModelBuckets()["glm-5.3"]?.input, 200)
        XCTAssertEqual(service.todayModelBuckets()["glm-5.3"]?.output, 150)
        XCTAssertEqual(service.todayModelBuckets()["glm-5.3"]?.cacheRead, 800)
        XCTAssertEqual(service.todayModelBuckets()["glm-5.3-flash"]?.input, 50)
        XCTAssertEqual(service.todaySessions().first?.todayTokens, 465)
        XCTAssertEqual(service.todaySessions().first?.todayMessages, 2)
        XCTAssertEqual(service.todaySessions().first?.displayName, "Main task")
        let historical = service.historicalSnapshots(retentionDays: 30)[DateHelper.todayKey()]
        XCTAssertEqual(historical?.tokens, 465)
        XCTAssertEqual(historical?.cacheReadTokens, 950)
        XCTAssertEqual(historical?.sessions.first?.messages, 2)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func insert(
        _ db: OpaquePointer?, id: String, logical: String, attempt: Int, session: String,
        model: String, status: String, time: Int64, input: Int, output: Int,
        reasoning: Int, cacheWrite: Int, cacheRead: Int
    ) {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO model_usage VALUES
        (?1,?2,?3,?4,?5,?6,?7,?7,?8,?9,?10,?11,?12)
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id); bind(statement, 2, logical)
        sqlite3_bind_int(statement, 3, Int32(attempt)); bind(statement, 4, session)
        bind(statement, 5, model); bind(statement, 6, status)
        sqlite3_bind_int64(statement, 7, time)
        sqlite3_bind_int64(statement, 8, Int64(input))
        sqlite3_bind_int64(statement, 9, Int64(output))
        sqlite3_bind_int64(statement, 10, Int64(reasoning))
        sqlite3_bind_int64(statement, 11, Int64(cacheWrite))
        sqlite3_bind_int64(statement, 12, Int64(cacheRead))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
