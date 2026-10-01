import Foundation
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
        XCTAssertTrue(speed.formatted.hasPrefix("≈"))
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
