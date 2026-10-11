import Foundation
#if canImport(Combine)
import Combine
#endif
import XCTest
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif
@testable import TokenClock

final class GenerationSpeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_800_000)
    private func sample(_ id: String, output: Int, seconds: Double, ago: Double = 1, model: String = "gpt-6-astra", estimated: Bool = false) -> GenerationSample {
        GenerationSample(id: id, model: model, completedAt: now.addingTimeInterval(-ago), outputTokens: output, seconds: seconds, estimated: estimated)
    }
    func testThreeMinuteSamplingCadenceAndToolChangesAndClockRollback() {
        var schedule = GenerationSpeedRefreshSchedule()
        XCTAssertEqual(GenerationSpeedRefreshSchedule.interval, 180)
        XCTAssertTrue(schedule.shouldRefresh(enabledTools: ["Codex"], now: now))
        for seconds in [30.0, 60, 90, 120, 150, 179.999] {
            XCTAssertFalse(schedule.shouldRefresh(enabledTools: ["Codex"], now: now.addingTimeInterval(seconds)))
        }
        XCTAssertTrue(schedule.shouldRefresh(enabledTools: ["Codex"], now: now.addingTimeInterval(180)))
        XCTAssertTrue(schedule.shouldRefresh(enabledTools: ["ZCode"], now: now.addingTimeInterval(181)))
        XCTAssertTrue(schedule.shouldRefresh(enabledTools: ["ZCode"], now: now.addingTimeInterval(-1)))
    }
    func testWeightedSpeedUsesGenerationTimeAndRollingCompletionWindow() {
        let data = ["Codex": [
            sample("a", output: 100, seconds: 2),
            sample("b", output: 900, seconds: 9, estimated: true),
            sample("expired", output: 90000, seconds: 1, ago: 600.001),
            sample("future", output: 90000, seconds: 1, ago: -1),
            sample("other-model", output: 500, seconds: 1, model: "gpt-6.1-sol")
        ]]
        let speed = GenerationSpeedStore.summarize(data, model: "gpt-6-astra", providers: ["Codex"], now: now)
        XCTAssertEqual(speed.tokensPerSecond!, 1000.0 / 11, accuracy: 0.000001)
        XCTAssertEqual(speed.sampleCount, 2)
        XCTAssertTrue(speed.estimated)
        XCTAssertEqual(speed.formatted, "90.9")
        XCTAssertNil(GenerationSpeedStore.summarize(data, model: "gpt-6-astra", providers: ["Codex"], now: now.addingTimeInterval(602)).tokensPerSecond)
    }
    func testDuplicateReplayInvalidSamplesAndDisabledProvidersDoNotInflateSpeed() {
        let a = sample("request-a", output: 100, seconds: 2)
        let data = ["Codex": [a, a, sample("bad", output: 10, seconds: 0),
                              sample("nan", output: 10, seconds: .nan), sample("negative", output: -1, seconds: 1)],
                    "ZCode": [sample("b", output: 200, seconds: 2)]]
        let speed = GenerationSpeedStore.summarize(data, model: "gpt-6-astra", providers: ["Codex"], now: now)
        XCTAssertEqual(speed.outputTokens, 100)
        XCTAssertEqual(speed.sampleCount, 1)
        XCTAssertEqual(speed.tokensPerSecond, 50)
        XCTAssertEqual(GenerationSpeedStore.summarize(data, model: "gpt-6-astra", providers: [], now: now).formatted, "—")
    }
    func testSpeedOnlyChangesAndExpirationChangeModelAndContributionRowValues() {
        let store = GenerationSpeedStore()
        let session = SessionInfo(rawId: "same", displayName: "same", detail: nil,
            todayTokens: 1000, todayMessages: 1, isActive: true, model: "gpt-6-astra")
        let tool = ToolUsage(name: "Codex", abbreviation: "CX", emoji: "X",
            todayTokens: 1000, todayMessages: 1, isActive: true,
            recentTokens: 0, hourlyTokens: 0, sessions: [session])
        let before = UsageAggregator.groupedByModel([tool], unknownLabel: "Unknown",
            generationSpeedStore: store, now: now)[0]
        store.replace(provider: "Codex", with: [sample("new", output: 100, seconds: 2)])
        let after = UsageAggregator.groupedByModel([tool], unknownLabel: "Unknown",
            generationSpeedStore: store, now: now)[0]
        XCTAssertEqual(after.totalTokens, before.totalTokens)
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(before.contributions[0], after.contributions[0])
        XCTAssertEqual(after.generationSpeed.formatted, "50.0")
        XCTAssertEqual(after.contributions[0].generationSpeed.formatted, "50.0")
        let expired = UsageAggregator.groupedByModel([tool], unknownLabel: "Unknown",
            generationSpeedStore: store, now: now.addingTimeInterval(601))[0]
        XCTAssertNotEqual(after, expired)
        XCTAssertEqual(expired.generationSpeed.formatted, "—")
    }
    #if canImport(Combine)
    func testRefreshNotifiesViewsEvenWithoutNewUsageOnMainThread() {
        let store = GenerationSpeedStore()
        let event = expectation(description: "Speed refresh invalidates detail view")
        let subscription = store.objectWillChange.sink {
            XCTAssertTrue(Thread.isMainThread)
            event.fulfill()
        }
        store.refresh(enabledTools: [], now: now)
        wait(for: [event], timeout: 2)
        withExtendedLifetime(subscription) {}
    }
    #endif
    private func line(_ type: String, _ payload: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: [
            "type": type, "timestamp": ISO8601DateFormatter().string(from: now),
            "payload": payload]), encoding: .utf8)!
    }
    private func item(_ id: String, kind: String = "AgentMessage", start: Double = 3000, end: Double = 1000) throws -> String {
        try line("event_msg", ["type": "item_completed", "thread_id": "thread-a", "turn_id": "turn-a",
                               "item": ["id": id, "type": kind],
                               "started_at_ms": now.timeIntervalSince1970 * 1000 - start,
                               "completed_at_ms": now.timeIntervalSince1970 * 1000 - end])
    }
    private func count(_ output: Int, total: Int) throws -> String {
        try line("event_msg", ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 999999, "output_tokens": output],
            "total_token_usage": ["output_tokens": total]]])
    }
    func testCodexPairsCompleteOutputAndMergesOverlapsWithoutInputTokens() throws {
        var parser = CodexGenerationParser()
        parser.consume(try line("turn_context", ["model": "gpt-6-astra"]))
        parser.consume(try item("reasoning", kind: "Reasoning", start: 4000, end: 2000))
        parser.consume(try item("answer", start: 3000, end: 1000))
        parser.consume(try count(90, total: 90))
        XCTAssertEqual(parser.samples.count, 1)
        XCTAssertEqual(parser.samples[0].outputTokens, 90)
        XCTAssertEqual(parser.samples[0].seconds, 3)
        parser.consume(try count(90, total: 90))
        XCTAssertEqual(parser.samples.count, 1)
    }
    func testCodexOmitsToolAndIncompleteTimingBatches() throws {
        var parser = CodexGenerationParser()
        parser.consume(try line("turn_context", ["model": "gpt-6.1-sol"]))
        parser.consume(try item("answer"))
        parser.consume(try item("tool", kind: "CommandExecution"))
        parser.consume(try count(100, total: 100))
        XCTAssertTrue(parser.samples.isEmpty)
        parser.consume(try item("zero", start: 1000, end: 1000))
        parser.consume(try count(100, total: 200))
        XCTAssertTrue(parser.samples.isEmpty)
        parser.consume(try item("valid"))
        parser.consume(try count(100, total: 300))
        XCTAssertEqual(parser.samples.count, 1)
        XCTAssertEqual(parser.samples[0].model, "gpt-6.1-sol")
    }
    func testColdReaderRetainsOldModelAndCounterBaselineThenReadsAppendsAndExpiration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-cold-speed-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        let formatter = ISO8601DateFormatter()
        func old(_ value: String) -> String {
            value.replacingOccurrences(of: formatter.string(from: now),
                                       with: formatter.string(from: now.addingTimeInterval(-3600)))
        }
        let records = [
            old(try line("turn_context", ["model": "gpt-6-astra"])),
            #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(-3600)))","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","output":"\#(String(repeating: "历史工具输出", count: 100_000))"}}}"#,
            old(try item("old-tool", kind: "CommandExecution")),
            old(try count(100, total: 100)),
            try item("replayed"), try count(100, total: 100),
            try item("recent"), try count(20, total: 120)
        ]
        try Data(records.joined(separator: "\n").utf8).write(to: file)
        let reader = CodexGenerationReader()
        let first = reader.scan(home: root.path, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].model, "gpt-6-astra")
        XCTAssertEqual(first[0].outputTokens, 20)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + (try item("append")) + "\n" + (try count(10, total: 130)) + "\n").utf8))
        try handle.close()
        let appended = reader.scan(home: root.path, now: now)
        XCTAssertEqual(appended.count, 2)
        XCTAssertEqual(appended.reduce(0) { $0 + $1.outputTokens }, 30)
        XCTAssertTrue(reader.scan(home: root.path, now: now.addingTimeInterval(601)).isEmpty)
    }
    func testColdFilterKeepsBoundarySecondsAndFallsBackForNonUTCTimestamps() {
        XCTAssertTrue(CodexGenerationReader.precedesWindow(#"{"timestamp":"2026-10-01T09:59:59.999Z"}"#,
            cutoffSecond: "2026-10-01T10:00:00"))
        XCTAssertFalse(CodexGenerationReader.precedesWindow(#"{"timestamp":"2026-10-01T10:00:00.001Z"}"#,
            cutoffSecond: "2026-10-01T10:00:00"))
        XCTAssertFalse(CodexGenerationReader.precedesWindow(#"{"timestamp":"2026-10-01T01:00:00-07:00"}"#,
            cutoffSecond: "2026-10-01T10:00:00"))
    }
    func testCodexReasoningOnlyCompletedResponseDoesNotRequireFinalAnswer() throws {
        var parser = CodexGenerationParser()
        parser.consume(try line("turn_context", ["model": "gpt-6.1-sol"]))
        parser.consume(try item("thinking", kind: "Reasoning"))
        parser.consume(try count(100, total: 100))
        XCTAssertEqual(parser.samples.count, 1)
        let speed = GenerationSpeedStore.summarize(["Codex": parser.samples],
            model: "gpt-6.1-sol", providers: ["Codex"], now: now)
        XCTAssertEqual(speed.formatted, "50.0")
        XCTAssertTrue(speed.estimated)
    }
    func testMultiModelSessionUsesExactModelsWithoutChangingTotals() {
        var session = SessionInfo(rawId: "multi", displayName: "multi", detail: nil,
            todayTokens: 1000, todayMessages: 2, isActive: true, model: "glm-5.3",
            cacheReadTokens: 300)
        session.modelBreakdown = [
            SessionModelUsage(model: "glm-5.3", tokens: 900, messages: 1, cacheReadTokens: 200),
            SessionModelUsage(model: "glm-5.3-flash", tokens: 100, messages: 1, cacheReadTokens: 100)
        ]
        let tool = ToolUsage(name: "ZCode", abbreviation: "ZC", emoji: "Z",
            todayTokens: 1000, todayMessages: 2, isActive: true,
            recentTokens: 100, hourlyTokens: 100, sessions: [session])
        let groups = UsageAggregator.groupedByModel([tool], unknownLabel: "Unknown")
        XCTAssertEqual(Set(groups.map(\.name)), ["glm-5.3", "glm-5.3-flash"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.totalTokens }, 1000)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.totalMessages }, 2)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.totalCacheReadTokens }, 300)
        let records = [sample("flash", output: 100, seconds: 2, model: "GLM-5.3-Flash")]
        XCTAssertEqual(GenerationSpeedStore.summarize(["ZCode": records],
            model: groups[1].name, providers: ["ZCode"], now: now).formatted, "50.0")
        var incomplete = tool
        incomplete.sessions[0].modelBreakdown.removeLast()
        let fallback = UsageAggregator.groupedByModel([incomplete], unknownLabel: "Unknown")
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback[0].totalTokens, 1000)
        XCTAssertEqual(fallback[0].totalCacheReadTokens, 300)
    }
    func testLatestCompletedRankingPreservesRetriesTiesAndNullMetadataWithoutCorrelatedScans() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE model_usage(logical_request_id TEXT, attempt_index INT, status TEXT);
          INSERT INTO model_usage VALUES
            ('a',0,'completed'),('a',1,'completed'),('a',2,'failed'),('a',1,'completed'),
            ('b',NULL,'completed'),('b',NULL,'completed'),('b',0,'completed'),
            (NULL,1,'completed'),(NULL,2,'completed'),('',0,'completed'),('',1,'completed');
          """, nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        let query = ZCodeLedger.latestCompletedRowsSQL + " SELECT ledger_rowid FROM latest_completed WHERE completion_rank=1"
        XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK)
        var ids = Set<Int64>()
        while sqlite3_step(statement) == SQLITE_ROW { ids.insert(sqlite3_column_int64(statement, 0)) }
        sqlite3_finalize(statement)
        XCTAssertEqual(ids, [4,5,6,7,8,9,11])
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + query, -1, &statement, nil), SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW {
            let detail = String(cString: sqlite3_column_text(statement, 3))
            XCTAssertFalse(detail.uppercased().contains("CORRELATED"))
        }
        sqlite3_finalize(statement)
    }
    func testNewerCompletionWithoutTimingSuppressesOlderTimedAttempt() throws {
        var db: OpaquePointer?
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tc-speed-retry-\(UUID().uuidString).sqlite")
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: file) }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE model_usage(logical_request_id TEXT, model_id TEXT, status TEXT, attempt_index INT,
            started_at INT, first_token_at INT, completed_at INT, output_tokens INT, reasoning_tokens INT);
          INSERT INTO model_usage VALUES
            ('a','glm-5.3','completed',0,\(ms-9000),\(ms-5000),\(ms-1000),100,0),
            ('a','glm-5.3','completed',1,\(ms-9000),NULL,\(ms-1000),100,0);
          """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(GenerationSpeedStore.zcodeSamples(home: file.path, now: now).isEmpty)
    }
    func testZCodeUsesFirstTokenAndLatestCompletedAttemptIncludingReasoning() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tc-speed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE model_usage(logical_request_id TEXT, model_id TEXT, status TEXT, attempt_index INT,
          started_at INT, first_token_at INT, completed_at INT, output_tokens INT, reasoning_tokens INT);
        INSERT INTO model_usage VALUES('a','GLM-5.3','completed',0,\(ms-9000),\(ms-5000),\(ms-1000),999,0);
        INSERT INTO model_usage VALUES('a','GLM-5.3','completed',1,\(ms-9000),\(ms-3000),\(ms-1000),80,20);
        INSERT INTO model_usage VALUES('missing','GLM-5.3','completed',0,\(ms-9000),NULL,\(ms-1000),999,0);
        INSERT INTO model_usage VALUES('failed','GLM-5.3','failed',0,\(ms-9000),\(ms-3000),\(ms-1000),999,0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let records = GenerationSpeedStore.zcodeSamples(home: home.path, now: now)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].outputTokens, 100)
        XCTAssertEqual(records[0].seconds, 2)
        XCTAssertFalse(records[0].estimated)
    }
    func testReadOnlyLiveGenerationSourcesWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_GENERATION_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in local timing scan") }
        let realNow = Date()
        let codex = CodexGenerationReader().scan(home: PathConfig.codexHome(), now: realNow)
        #if !os(Linux)
        let zcode = GenerationSpeedStore.zcodeSamples(home: PathConfig.zcodeHome(), now: realNow)
        let service = ZCodeUsageService()
        service.fullScan()
        let sessions = service.todaySessions()
        for session in sessions {
            XCTAssertEqual(session.modelBreakdown.reduce(0) { $0 + $1.tokens }, session.todayTokens)
            XCTAssertEqual(session.modelBreakdown.reduce(0) { $0 + $1.messages }, session.todayMessages)
            XCTAssertEqual(session.modelBreakdown.reduce(0) { $0 + $1.cacheReadTokens }, session.cacheReadTokens)
        }
        let displayedModels = Set(sessions.flatMap { $0.modelBreakdown.map(\.model) })
        for model in Set(zcode.map(\.model)) {
            XCTAssertTrue(displayedModels.contains(model), "Recent generation model missing from today's rows")
        }
        #else
        let zcode: [GenerationSample] = []
        #endif
        for (provider, records) in [("Codex", codex), ("ZCode", zcode)] {
            for model in Set(records.map(\.model)).sorted() {
                let speed = GenerationSpeedStore.summarize([provider: records], model: model, providers: [provider], now: realNow)
                XCTAssertNotNil(speed.tokensPerSecond)
                print("[generation] \(provider) \(model): \(speed.formatted) t/s, \(speed.sampleCount) completed samples")
            }
        }
    }
}
