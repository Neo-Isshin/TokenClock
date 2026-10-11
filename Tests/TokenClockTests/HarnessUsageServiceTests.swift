import XCTest
@testable import TokenClock
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

final class HarnessUsageServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenclock-harness-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10)) }
    private func write(_ name: String, _ records: [[String: Any]]) throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try lines.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    private func pi(_ id: String, model: String = "gpt-5") -> [String: Any] {
        ["type": "message", "id": id, "timestamp": timestamp,
         "message": ["role": "assistant", "model": model, "usage": ["input": 100, "output": 20, "cacheRead": 40, "cacheWrite": 10]]]
    }
    func testPiAndOMPCountSeparateCacheAndModelSwitches() throws {
        _ = try write("sessions/project/one.jsonl", [
            ["type": "session", "id": "session-one"], ["type": "session_info", "name": "Fix login"], pi("one"), pi("two", model: "claude-sonnet-4-5")])
        for harness in [AdditionalHarness.pi, .omp] {
            let reader = HarnessUsageService(harness, roots: [root.path]); reader.fullScan()
            XCTAssertEqual(reader.todayUsage().tokens, 260)
            XCTAssertEqual(reader.todayUsage().messages, 2)
            XCTAssertEqual(reader.todayCacheReadTokens(), 80)
            XCTAssertEqual(reader.todaySessions().first?.displayName, "Fix login")
            XCTAssertEqual(reader.todaySessions().first?.modelBreakdown.count, 2)
            XCTAssertEqual(reader.hourlyData.values.reduce(0) { $0 + $1.tokens }, 260)
        }
    }
    func testForkCopiesAndDuplicateRootsDoNotDoubleCount() throws {
        let record = pi("shared-entry")
        _ = try write("a.jsonl", [["type": "session", "id": "a"], record])
        _ = try write("b.jsonl", [["type": "session", "id": "b", "parentSession": "a.jsonl"], record, pi("new-entry")])
        let reader = HarnessUsageService(.pi, roots: [root.path, root.path]); reader.fullScan(); reader.incrementalScan()
        XCTAssertEqual(reader.todayUsage().messages, 2)
        XCTAssertEqual(reader.todayUsage().tokens, 260)
    }
    func testReplacementDeletionAndCorruptJSONL() throws {
        let file = try write("a.jsonl", [pi("one")])
        let reader = HarnessUsageService(.pi, roots: [root.path]); reader.fullScan()
        _ = try write("a.jsonl", [pi("two"), pi("three")])
        reader.incrementalScan(); XCTAssertEqual(reader.todayUsage().messages, 2)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken\n".utf8)); try handle.close()
        reader.incrementalScan(); XCTAssertEqual(reader.todayUsage().messages, 2)
        try FileManager.default.removeItem(at: file); reader.incrementalScan()
        XCTAssertEqual(reader.todayUsage().messages, 0)
    }
    func testCommandCodeUsageLivesOnEntryAndInputIncludesCache() throws {
        _ = try write("project/cmd.jsonl", [["type": "session", "id": "cmd"],
            ["type": "message", "id": "entry", "timestamp": timestamp, "model": "gpt-5",
             "message": ["role": "assistant"], "usage": ["inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 40, "cacheWriteTokens": 10]]])
        let reader = HarnessUsageService(.commandCode, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().tokens, 80)
        XCTAssertEqual(reader.todayCacheReadTokens(), 40)
        XCTAssertEqual(reader.todayUsage().tokens + reader.todayCacheReadTokens(), 120)
        let meta = root.appendingPathComponent("project/cmd.meta.json")
        try Data("{\"title\":\"Named command session\"}".utf8).write(to: meta)
        reader.incrementalScan()
        XCTAssertEqual(reader.todaySessions().first?.displayName, "Named command session")
    }
    func testCompactionReceiptsCountButContextCountersDoNot() throws {
        _ = try write("one.jsonl", [
            ["type": "usage", "id": "warm", "timestamp": timestamp, "model": "gpt-5", "usage": ["input": 5, "output": 0, "cacheWrite": 7]],
            ["type": "compaction", "id": "compact", "timestamp": timestamp, "usage": ["input": 8, "output": 3]],
            ["type": "custom", "id": "context", "timestamp": timestamp, "usage": ["input": 50000]],
            ["type": "message", "id": "user", "timestamp": timestamp, "message": ["role": "user", "usage": ["input": 999]]]])
        let reader = HarnessUsageService(.pi, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().tokens, 23); XCTAssertEqual(reader.todayUsage().messages, 2)
    }
    func testMalformedCountsAndMissingDatesFailClosed() throws {
        XCTAssertNil(HarnessUsageService.buckets(["input": -1, "output": 20], format: .pi))
        XCTAssertNil(HarnessUsageService.buckets(["input": true, "output": 20], format: .pi))
        XCTAssertNil(HarnessUsageService.buckets(["input": Double.infinity], format: .pi))
        XCTAssertNil(HarnessUsageService.buckets(["input": 1.5], format: .pi))
        XCTAssertNil(HarnessUsageService.buckets(["input": 1_000_000_001], format: .pi))
        XCTAssertNil(HarnessUsageService.buckets(["input": Int.max / 9], format: .pi))
        XCTAssertNil(HarnessUsageService.date(true))
        var missing = pi("missing"); missing.removeValue(forKey: "timestamp")
        _ = try write("one.jsonl", [missing]); let reader = HarnessUsageService(.pi, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().tokens, 0)
    }
    func testKiloExtensionReceiptsAreNotClineRecords() throws {
        let obj: [String: Any] = ["tokensIn": 100, "tokensOut": 20, "cacheReads": 40, "cacheWrites": 10, "modelId": "gpt-5"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let rows: [[String: Any]] = [["ts": Date().addingTimeInterval(-10).timeIntervalSince1970 * 1000, "say": "api_req_started", "text": text]]
        let file = root.appendingPathComponent("task/ui_messages.json"); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        let reader = HarnessUsageService(.kiloCode, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().tokens, 130); XCTAssertEqual(reader.todayCacheReadTokens(), 40)
        XCTAssertEqual(reader.todaySessions().first?.rawId, "task")
    }
    func testKiloSQLiteUsesMessagesNotCumulativeSessionCounters() throws {
        let path = root.appendingPathComponent("kilo.db").path; var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE session(id TEXT, title TEXT, tokens_input INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, data TEXT); INSERT INTO session VALUES('s','Database session',999999);", nil, nil, nil), SQLITE_OK)
        let obj: [String: Any] = ["role": "assistant", "modelID": "gpt-5", "time": ["created": Date().addingTimeInterval(-10).timeIntervalSince1970 * 1000], "tokens": ["input": 100, "output": 20, "reasoning": 5, "cache": ["read": 40, "write": 10]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES('m','s','\(json)')", nil, nil, nil), SQLITE_OK)
        let reader = HarnessUsageService(.kiloCode, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().tokens, 135); XCTAssertEqual(reader.todayUsage().messages, 1)
        XCTAssertEqual(reader.todaySessions().first?.displayName, "Database session")
        XCTAssertEqual(sqlite3_exec(db, "SELECT 1", nil, nil, nil), SQLITE_OK)
    }
    func testFreebuffOnlyCountsLocalCompletionsNeverContextOrCreditsAsTokens() throws {
        let rows: [[String: Any]] = [
            ["id": "one", "variant": "ai", "isComplete": true, "timestamp": timestamp, "credits": 50, "metadata": ["runState": ["contextTokenCount": 99999]]],
            ["id": "user", "variant": "user", "isComplete": true, "timestamp": timestamp],
            ["id": "unfinished", "variant": "ai", "timestamp": timestamp]]
        let file = root.appendingPathComponent("chats/chat/chat-messages.json"); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        let reader = HarnessUsageService(.freebuff, roots: [root.path]); reader.fullScan()
        XCTAssertEqual(reader.todayUsage().messages, 1); XCTAssertEqual(reader.todayUsage().tokens, 0)
        XCTAssertFalse(reader.todayCost().available); XCTAssertTrue(reader.hourlyData.isEmpty)
        XCTAssertEqual(AdditionalHarness.freebuff.unit, .requests)
    }
    func testSidecarsAreNotTranscripts() throws {
        _ = try write("a.checkpoints.jsonl", [pi("bad")]); _ = try write("a.prompts.jsonl", [pi("bad2")]); _ = try write("a.jsonl", [pi("good")])
        XCTAssertEqual(HarnessUsageService.sourceFiles(roots: [root.path], harness: .commandCode).count, 1)
    }
    func testHistoricalDatesAreImportedWithoutUsingFileMtime() throws {
        var yesterday = pi("yesterday")
        let old = Date().addingTimeInterval(-86400)
        yesterday["timestamp"] = ISO8601DateFormatter().string(from: old)
        _ = try write("history.jsonl", [yesterday, pi("today")])
        let reader = HarnessUsageService(.pi, roots: [root.path]); reader.fullScan()
        let snapshots = reader.historicalSnapshots(retentionDays: 30)
        XCTAssertEqual(reader.todayUsage().tokens, 130)
        XCTAssertEqual(snapshots[DateHelper.dateKey(from: old)]?.tokens, 130)
        XCTAssertEqual(snapshots[DateHelper.dateKey(from: old)]?.cacheReadTokens, 40)
        XCTAssertEqual(snapshots[DateHelper.dateKey(from: old)]?.sessions.count, 1)
    }
    func testUnknownPriceBeforeKnownPriceRemainsIncomplete() throws {
        _ = try write("one.jsonl", [pi("unknown", model: "unlisted-model-xyz"), pi("known")])
        let reader = HarnessUsageService(.pi, roots: [root.path]); reader.fullScan()
        XCTAssertTrue(reader.todayCost().available)
        XCTAssertFalse(reader.todayCost().complete)
        XCTAssertFalse(reader.todaySessions().first?.todayCost.complete ?? true)
    }
    func testFreebuffCannotLeakIntoTokenOrModelTotals() {
        let tool = ToolUsage(name: "Freebuff", abbreviation: "FB", emoji: "🦬", measurementUnit: .requests,
            measurementValue: 20, todayTokens: 0, todayMessages: 20, isActive: true, recentTokens: 0, hourlyTokens: 0)
        XCTAssertEqual(UsageAggregator.totalTokens([tool]), 0)
        XCTAssertEqual(UsageAggregator.totalMessages([tool]), 0)
        XCTAssertTrue(UsageAggregator.groupedByModel([tool], unknownLabel: "Unknown").isEmpty)
    }
    func testHermesBrandResourceIsPresent() {
        XCTAssertEqual(BrandIconCatalog.key(for: "Hermes"), "hermes")
        XCTAssertNotNil(BrandIconCatalog.url(forKey: "hermes"))
        XCTAssertEqual(BrandIconCatalog.token(for: "Hermes", fallback: "⚕️", style: .emoji), "[[brand:hermes]]")
    }
    func testHistoryReplacementOnlyTouchesTheRequestedHarness() throws {
        let history = HistoryStore(path: root.appendingPathComponent("history.sqlite"))
        let day = DateHelper.todayKey()
        history.upsertDay(dateKey: day, snapshots: [
            ToolSnapshot(name: "Codex", tokens: 7, messages: 1, cacheRate: 0, isActive: false),
            ToolSnapshot(name: "Pi", tokens: 999, messages: 1, cacheRate: 0, isActive: false)])
        let replacement = ToolSnapshot(name: "Pi", tokens: 50, messages: 2, cacheRate: 0.1, isActive: false, cacheReadTokens: 3)
        XCTAssertTrue(history.replaceToolHistory(toolName: "Pi", snapshotsByDate: [day: replacement], from: day, through: day))
        let tools = history.query(from: day, through: day).first?.tools ?? []
        XCTAssertEqual(tools.first { $0.name == "Codex" }?.tokens, 7)
        XCTAssertEqual(tools.first { $0.name == "Pi" }?.tokens, 50)
        XCTAssertEqual(tools.first { $0.name == "Pi" }?.cacheReadTokens, 3)
        XCTAssertTrue(history.replaceToolHistory(toolName: "Pi", snapshotsByDate: [:], from: day, through: day))
        let remaining = history.query(from: day, through: day).first?.tools ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, "Codex")
    }
    func testSharedAgentOverrideIsNotAttributedToBothPiAndOMP() {
        let environment = ["PI_CODING_AGENT_DIR": root.path + "/shared"]
        XCTAssertFalse(AdditionalHarness.pi.roots(home: root.path, environment: environment, includeCustom: false).contains(root.path + "/shared"))
        XCTAssertFalse(AdditionalHarness.omp.roots(home: root.path, environment: environment, includeCustom: false).contains(root.path + "/shared"))
        let ompEnvironment = ["PI_CODING_AGENT_DIR": root.path + "/.omp/agent"]
        XCTAssertFalse(AdditionalHarness.pi.roots(home: root.path, environment: ompEnvironment, includeCustom: false).contains(root.path + "/.omp/agent"))
        XCTAssertTrue(AdditionalHarness.omp.roots(home: root.path, environment: ompEnvironment, includeCustom: false).contains(root.path + "/.omp/agent"))
    }
}
