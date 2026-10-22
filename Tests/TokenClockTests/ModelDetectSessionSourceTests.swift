#if os(macOS)
import XCTest
import SQLite3
import Darwin
@testable import TokenClock

final class ModelDetectSessionSourceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-detect-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.resolvingSymlinksInPath()
    }

    private func json(_ object: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try data.write(to: path)
    }

    private func filesystemPath(_ path: String) throws -> String {
        // Foundation's directory enumerator can return /private/var while URL
        // construction preserves /var. Compare actual files, not this OS alias.
        let resolved = try XCTUnwrap(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testDefaultSourceDoesNotUseSessionIDModelOrProjectDirectory() {
        let session = SessionInfo(rawId: "/tmp/looks-like-a-log.jsonl", displayName: "named model",
                                  detail: "/tmp/project", todayTokens: 12, todayMessages: 1,
                                  isActive: true, model: "gpt-5.5")
        XCTAssertNil(session.sourceLogPath)
        XCTAssertNil(ModelDetectSessionSource.usablePath(session.sourceLogPath))
    }

    func testOnlyExplicitReadableRegularBoundedFilesCanPrefill() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("actual ; $(not-a-command).jsonl")
        try Data("{}\n".utf8).write(to: log)
        XCTAssertEqual(ModelDetectSessionSource.usablePath(log.path), log.path)
        for candidate in [nil, "", "relative.jsonl", "file://" + log.path, root.path,
                          root.appendingPathComponent("absent.jsonl").path, log.path + "\0hidden"] {
            XCTAssertNil(ModelDetectSessionSource.usablePath(candidate))
        }
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        XCTAssertNil(ModelDetectSessionSource.usablePath(link.path))
        let empty = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        XCTAssertNil(ModelDetectSessionSource.usablePath(empty.path))
        let large = root.appendingPathComponent("large.jsonl")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ModelDetectSessionSource.maxBytes + 1))
        try handle.close()
        XCTAssertNil(ModelDetectSessionSource.usablePath(large.path))
        try FileManager.default.removeItem(at: log)
        XCTAssertNil(ModelDetectSessionSource.usablePath(log.path), "A stale index falls back to file selection")
    }

    func testCodexUsesOnlyIndexedRolloutPathAndSupportsOlderIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let dir = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "019fa671-a3fc-7902-8b91-6077ac1b28c3"
        let log = dir.appendingPathComponent("rollout-\(date)T00-00-00-\(id).jsonl")
        let timestamp = ISO8601DateFormatter().string(from: now)
        let usage = ["input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 20, "reasoning_output_tokens": 0, "total_tokens": 120]
        let events: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": id]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": ["last_token_usage": usage, "total_token_usage": usage]]],
        ]
        let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try data.write(to: log, atomically: true, encoding: .utf8)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, updated_at_ms INTEGER, cwd TEXT, title TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(id)', \(Int64(now.timeIntervalSince1970 * 1000)), '/tmp/project-is-not-a-log', 'Source test')", nil, nil, nil), SQLITE_OK)
        let service = CodexUsageService(codexHome: root.path)
        service.fullScan()
        let old = try XCTUnwrap(service.todaySessions().first)
        XCTAssertEqual(old.todayTokens, 120)
        XCTAssertNil(old.sourceLogPath, "Even an existing conventional filename is not guessed from an ID")
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE threads ADD COLUMN rollout_path TEXT", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE threads SET rollout_path = ?", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_bind_text(statement, 1, log.path, -1, transient), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        let indexed = try XCTUnwrap(service.todaySessions().first)
        XCTAssertEqual(indexed.sourceLogPath, log.path)
        XCTAssertEqual(indexed.todayTokens, old.todayTokens)
        XCTAssertEqual(indexed.todayMessages, old.todayMessages)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET rollout_path = 'relative.jsonl'", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(service.todaySessions().first?.sourceLogPath)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET rollout_path = NULL", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(service.todaySessions().first?.sourceLogPath)
    }

    func testClaudeUsesScannedPathAndRefusesDuplicateOriginalsWithoutChangingTotals() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "recorded-session", log = root.appendingPathComponent("projects/actual-project/\(id).jsonl")
        let line: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["model": "claude-sonnet-5", "usage": ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 0]]]
        try json(line, to: log)
        try json(["sessionId": id, "cwd": "/tmp/never-use-project-as-log"], to: root.appendingPathComponent("sessions/metadata.json"))
        let service = ClaudeCodeUsageService(claudeHome: root.path)
        XCTAssertTrue(service.todaySessions().isEmpty, "No scan means no located source")
        service.fullScan()
        let original = try XCTUnwrap(service.todaySessions().first)
        XCTAssertEqual(try filesystemPath(XCTUnwrap(original.sourceLogPath)), try filesystemPath(log.path))
        XCTAssertEqual(original.todayTokens, 120)
        let duplicate = root.appendingPathComponent("projects/actual-project/nested/\(id).jsonl")
        try json(line, to: duplicate)
        service.incrementalScan()
        let ambiguous = try XCTUnwrap(service.todaySessions().first)
        XCTAssertNil(ambiguous.sourceLogPath)
        XCTAssertEqual(ambiguous.todayTokens, original.todayTokens)
        XCTAssertEqual(service.todayUsage().tokens, 120, "Nested detail-only files must not change the existing total boundary")
        try FileManager.default.removeItem(at: duplicate)
        service.incrementalScan()
        XCTAssertEqual(try filesystemPath(XCTUnwrap(service.todaySessions().first?.sourceLogPath)), try filesystemPath(log.path))
        XCTAssertEqual(service.todayUsage().tokens, 120)
    }

    func testModelDetectEntryStringsHaveAllSupportedTranslations() {
        let l10n = L10n.shared, before = L10n.shared.language
        defer { l10n.language = before }
        for language in AppLanguage.allCases {
            l10n.language = language
            for key in ["menu.sessionAssessment", "detail.modelDetectHint", "modelDetect.sessionOpen", "modelDetect.sessionChooseLog", "modelDetect.selectSessionLog"] {
                XCTAssertNotEqual(l10n.tr(key), key)
                XCTAssertFalse(l10n.tr(key).isEmpty)
            }
        }
    }
}
#endif
