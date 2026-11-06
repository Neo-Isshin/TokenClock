import Foundation
import XCTest
@testable import TokenClock

final class CodexGenerationAttributionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_800_000)

    private func line(_ type: String, _ payload: [String: Any], at: Double = 0) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return String(data: try JSONSerialization.data(withJSONObject: [
            "type": type, "timestamp": formatter.string(from: now.addingTimeInterval(at)),
            "payload": payload]), encoding: .utf8)!
    }
    private func context(_ parser: inout CodexGenerationParser, thread: String = "a", turn: String = "turn", model: String = "gpt-6-astra") throws {
        parser.consume(try line("session_meta", ["id": thread]))
        parser.consume(try line("turn_context", ["thread_id": thread, "turn_id": turn, "model": model]))
    }
    private func item(_ id: String, thread: String = "a", turn: String = "turn", kind: String = "Reasoning", start: Double = -4, end: Double = -2) throws -> String {
        try line("event_msg", ["type": "item_completed", "thread_id": thread, "turn_id": turn,
            "item": ["type": kind, "id": id], "started_at_ms": now.addingTimeInterval(start).timeIntervalSince1970 * 1000,
            "completed_at_ms": now.addingTimeInterval(end).timeIntervalSince1970 * 1000], at: end)
    }
    private func usage(_ response: String, thread: String = "a", turn: String = "turn", output: Int = 100, total: Int = 100, at: Double = -1) throws -> String {
        try line("token_usage_record", ["thread_id": thread, "turn_id": turn, "response_id": response,
            "usage": ["output_tokens": output, "reasoning_output_tokens": output / 2],
            "turn_token_usage": ["output_tokens": total]], at: at)
    }
    private func legacyCount(_ output: Int, total: Int) throws -> String {
        try line("event_msg", ["type": "token_count", "info": [
            "last_token_usage": ["output_tokens": output], "total_token_usage": ["output_tokens": total]]])
    }

    func testMixedToolBatchUsesNativeRequestWithoutCountingToolWait() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("user", kind: "UserMessage", start: -8, end: -8))
        parser.consume(try item("reasoning"))
        parser.consume(try item("tool", kind: "CommandExecution", start: -2, end: -1))
        parser.consume(try usage("response"))
        parser.consume(try legacyCount(100, total: 100))
        let sample = try XCTUnwrap(parser.samples.first)
        XCTAssertEqual(parser.samples.count, 1)
        XCTAssertEqual(sample.outputTokens, 100) // Reasoning is a subset, not another 50 tokens.
        XCTAssertEqual(sample.seconds, 2, accuracy: 0.0001)
        XCTAssertEqual(sample.model, "gpt-6-astra")
        XCTAssertTrue(sample.estimated)
    }

    func testLateToolCompletionRefinesOnlyTheSameRequestScope() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("reasoning"))
        parser.consume(try usage("response"))
        XCTAssertEqual(try XCTUnwrap(parser.samples.first).seconds, 3, accuracy: 0.0001)
        parser.consume(try item("foreign-tool", thread: "b", kind: "McpToolCall", start: -2, end: -1))
        XCTAssertEqual(try XCTUnwrap(parser.samples.first).seconds, 3, accuracy: 0.0001)
        parser.consume(try item("own-tool", kind: "McpToolCall", start: -2, end: 1))
        XCTAssertEqual(try XCTUnwrap(parser.samples.first).seconds, 2, accuracy: 0.0001)
    }

    func testToolOverlappingKnownGenerationDoesNotRemoveModelTime() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("reasoning"))
        parser.consume(try item("parallel-tool", kind: "McpToolCall", start: -3, end: -1))
        parser.consume(try usage("response"))
        XCTAssertEqual(try XCTUnwrap(parser.samples.first).seconds, 2, accuracy: 0.0001)
    }

    func testConcurrentThreadsHaveSeparateModelsAndSeparateDenominators() throws {
        var parser = CodexGenerationParser()
        try context(&parser, thread: "a")
        try context(&parser, thread: "b")
        parser.consume(try item("a-item", start: -3, end: -1))
        parser.consume(try item("b-item", thread: "b", start: -4, end: -1))
        parser.consume(try usage("b-response", thread: "b", output: 300, total: 300))
        parser.consume(try usage("a-response"))
        let speed = GenerationSpeedStore.summarize(["Codex": parser.samples], model: "gpt-6-astra", providers: ["Codex"], now: now)
        XCTAssertEqual(speed.sampleCount, 2)
        XCTAssertEqual(speed.outputTokens, 400)
        XCTAssertEqual(speed.generationSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(speed.tokensPerSecond), 80, accuracy: 0.0001)
    }

    func testInterleavedTurnsDoNotBorrowTheLatestGlobalModel() throws {
        var parser = CodexGenerationParser()
        try context(&parser, turn: "old", model: "gpt-6-astra")
        parser.consume(try item("old-output", turn: "old"))
        try context(&parser, turn: "new", model: "gpt-6.1-sol")
        parser.consume(try item("new-output", turn: "new"))
        parser.consume(try usage("new-response", turn: "new"))
        parser.consume(try usage("old-response", turn: "old"))
        XCTAssertEqual(Set(parser.samples.map(\.model)), ["gpt-6-astra", "gpt-6.1-sol"])
    }

    func testDuplicateRequestAndRepeatedItemsAndLegacyCounterDoNotDoubleCount() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("output"))
        parser.consume(try legacyCount(100, total: 100)) // Older clients may flush this first.
        XCTAssertEqual(parser.samples.count, 1)
        parser.consume(try usage("response"))
        parser.consume(try item("output"))
        parser.consume(try usage("response"))
        parser.consume(try legacyCount(100, total: 100))
        XCTAssertEqual(parser.samples.count, 1)
        XCTAssertEqual(parser.samples.first?.outputTokens, 100)
    }

    func testMissingRequestCounterGapDropsUnattributableItemsAndRecovers() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("first", start: -10, end: -9))
        parser.consume(try usage("first-response", at: -8))
        parser.consume(try item("missing", start: -7, end: -6))
        parser.consume(try item("third", start: -5, end: -4))
        parser.consume(try usage("third-response", output: 50, total: 250, at: -3))
        parser.consume(try item("fourth", start: -2, end: -1))
        parser.consume(try usage("fourth-response", output: 25, total: 275, at: 0))
        XCTAssertEqual(parser.samples.count, 2)
        XCTAssertEqual(parser.samples.reduce(0) { $0 + $1.outputTokens }, 125)
    }

    func testUnknownModelScopeAndToolOnlyResponseRemainUnavailable() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("unknown", thread: "b"))
        parser.consume(try usage("unknown-response", thread: "b"))
        parser.consume(try item("tool-only", kind: "CommandExecution", start: -2, end: -1))
        parser.consume(try usage("tool-only-response"))
        XCTAssertTrue(parser.samples.isEmpty)
    }

    func testOverlappingModelStreamsInOneScopeAreNotGuessed() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("overlap-a", start: -4, end: -2))
        parser.consume(try item("overlap-b", start: -3, end: -1))
        parser.consume(try usage("ambiguous-response", at: 0))
        XCTAssertTrue(parser.samples.isEmpty)
    }

    func testOutOfOrderItemsForFutureRequestStayInTheirOwnBoundary() throws {
        var parser = CodexGenerationParser()
        try context(&parser)
        parser.consume(try item("first", start: -6, end: -5))
        parser.consume(try item("second", start: -3, end: -2))
        parser.consume(try usage("first-response", at: -4))
        parser.consume(try usage("second-response", output: 50, total: 150, at: -1))
        XCTAssertEqual(parser.samples.count, 2)
        XCTAssertEqual(parser.samples.reduce(0) { $0 + $1.outputTokens }, 150)
    }

    func testColdNativeReaderHasContextAndBaselineAndNeverWritesProviderLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-native-speed-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = dir.appendingPathComponent("rollout.jsonl")
        let lines = [
            try line("session_meta", ["id": "a"], at: -3600),
            try line("turn_context", ["turn_id": "turn", "model": "gpt-6-astra"], at: -3600),
            try usage("old-response", output: 100, total: 100, at: -3600),
            try item("current"), try item("tool", kind: "CommandExecution", start: -2, end: -1),
            try usage("current-response", output: 50, total: 150)
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path.path)
        let before = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        let samples = CodexGenerationReader().scan(home: root.path, now: now)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.outputTokens, 50)
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date, before)
    }

    func testIdleRetainsExactLastWindowAndNewOutputRollsItForward() throws {
        let store = GenerationSpeedStore()
        let a = GenerationSample(id: "a", model: "gpt-6-astra", completedAt: now.addingTimeInterval(-500), outputTokens: 100, seconds: 2, estimated: true)
        let b = GenerationSample(id: "b", model: "gpt-6-astra", completedAt: now, outputTokens: 300, seconds: 3, estimated: true)
        store.replace(provider: "Codex", with: [a, b], now: now)
        let original = store.summary(model: "gpt-6-astra", providers: ["Codex"], now: now)
        store.replace(provider: "Codex", with: [], now: now.addingTimeInterval(7200))
        let idle = store.summary(model: "gpt-6-astra", providers: ["Codex"], now: now.addingTimeInterval(7200))
        XCTAssertEqual(idle, original)
        XCTAssertEqual(idle.tokensPerSecond, 80)
        XCTAssertEqual(idle.lastCompletedAt, now)
        let c = GenerationSample(id: "c", model: "gpt-6-astra", completedAt: now.addingTimeInterval(7200), outputTokens: 50, seconds: 2, estimated: true)
        store.replace(provider: "Codex", with: [c], now: now.addingTimeInterval(7200))
        XCTAssertEqual(store.summary(model: "gpt-6-astra", providers: ["Codex"], now: now.addingTimeInterval(7200)).tokensPerSecond, 25)
        store.clear(provider: "Codex")
        XCTAssertNil(store.summary(model: "gpt-6-astra", providers: ["Codex"], now: now.addingTimeInterval(7200)).tokensPerSecond)
    }

    func testFutureSamplesAndDisabledProvidersCannotLeakIntoRetainedValue() {
        let store = GenerationSpeedStore()
        let a = GenerationSample(id: "valid", model: "gpt-6-astra", completedAt: now, outputTokens: 100, seconds: 2, estimated: true)
        let future = GenerationSample(id: "future", model: "gpt-6-astra", completedAt: now.addingTimeInterval(7200), outputTokens: 9999, seconds: 1, estimated: true)
        store.replace(provider: "Codex", with: [a, future], now: now)
        XCTAssertEqual(store.summary(model: "gpt-6-astra", providers: ["Codex"], now: now).tokensPerSecond, 50)
        XCTAssertNil(store.summary(model: "gpt-6-astra", providers: [], now: now).tokensPerSecond)
    }
}
