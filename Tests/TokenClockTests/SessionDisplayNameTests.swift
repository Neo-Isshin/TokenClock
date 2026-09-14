import XCTest
@testable import TokenClock
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

final class SessionDisplayNameTests: XCTestCase {
    func testNativeTitleTakesPriorityOverSessionID() {
        XCTAssertEqual(
            SessionIdDisplay.preferred(title: "  Investigate parser  ", id: "019fa671-a3fc-7902-8b91-6077ac1b28c3"),
            "Investigate parser"
        )
        XCTAssertEqual(SessionIdDisplay.preferred(title: "\nNamed session\nsecond line", id: "abc"), "Named session")
    }

    func testMissingTitleUsesCompleteID() {
        let id = "019fa671-a3fc-7902-8b91-6077ac1b28c3"
        XCTAssertEqual(SessionIdDisplay.preferred(title: nil, id: id), id)
        XCTAssertEqual(SessionIdDisplay.preferred(title: "  ", id: id), id)
        XCTAssertEqual(SessionIdDisplay.format("  \(id)  "), id)
    }

    func testCodexReadsCustomNameThenTitleThenID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let subpath = String(format: "sessions/%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let sessionsDir = root.appendingPathComponent(subpath, isDirectory: true)
        let rolloutDate = String(format: "%04d-%02d-%02dT00-00-00", components.year!, components.month!, components.day!)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let id = "019fa671-a3fc-7902-8b91-6077ac1b28c3"
        let timestamp = ISO8601DateFormatter().string(from: now)
        let usage: [String: Int] = [
            "input_tokens": 100, "cached_input_tokens": 0,
            "output_tokens": 20, "reasoning_output_tokens": 0, "total_tokens": 120,
        ]
        let events: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": id]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "info": ["last_token_usage": usage, "total_token_usage": usage],
            ]],
        ]
        let lines = try events.map { event in
            String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try lines.write(to: sessionsDir.appendingPathComponent("rollout-\(rolloutDate)-\(id).jsonl"), atomically: true, encoding: .utf8)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, updated_at_ms INTEGER, cwd TEXT, title TEXT, name TEXT)", nil, nil, nil), SQLITE_OK)
        let updatedAt = Int64(now.timeIntervalSince1970 * 1_000)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(id)', \(updatedAt), '/tmp', 'Automatic title', 'Custom title')", nil, nil, nil), SQLITE_OK)

        let service = CodexUsageService(codexHome: root.path)
        service.fullScan()
        XCTAssertEqual(service.todaySessions().first?.displayName, "Custom title")
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET name = ''", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(service.todaySessions().first?.displayName, "Automatic title")
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET title = ''", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(service.todaySessions().first?.displayName, id)
    }
}
