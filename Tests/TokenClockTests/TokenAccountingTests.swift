import Foundation
import XCTest
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif
@testable import TokenClock

final class TokenAccountingTests: XCTestCase {
    func testInclusiveTotalsExcludeOnlyCacheRead() {
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveTotal: 1_000, cacheRead: 800), 200)
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveTotal: 10, cacheRead: 20), 0)
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveTotal: -1, cacheRead: 5), 0)

        // Cache creation/write is already part of this inclusive input. Subtracting read leaves it in.
        XCTAssertEqual(
            TokenAccounting.excludingCacheRead(
                inclusiveInput: 100, cacheRead: 40, output: 10, additional: [5]
            ),
            75
        )
    }

    func testSeparateFieldsIncludeCacheWriteButNeverCacheRead() {
        XCTAssertEqual(
            TokenAccounting.separateCacheFields(input: 10, cacheWrite: 3, output: 5),
            18
        )
        XCTAssertEqual(
            TokenAccounting.separateCacheFields(input: 10, cacheWrite: 3, output: 5, additional: [7, 2]),
            27
        )
        XCTAssertEqual(TokenAccounting.separateCacheFields(input: Int.max, cacheWrite: 1, output: 0), Int.max)
    }

    func testCacheReadShareUsesFreshPlusReadAsDenominator() {
        XCTAssertEqual(TokenAccounting.cacheReadShare(freshTokens: 60, cacheRead: 40), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(TokenAccounting.cacheReadShare(freshTokens: 0, cacheRead: 0), 0)
        XCTAssertEqual(TokenAccounting.cacheReadShare(freshTokens: -1, cacheRead: -1), 0)
    }
}

final class ThreeDayProviderAccountingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        PathConfig.setClinePath("")
        PathConfig.setHermesPath("")
        PathConfig.setOpenCodePath("")
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testThreeDaysAcrossCodexClaudeOpenClawGeminiQwenAndCopilot() throws {
        let samples = threeDaySamples()

        let codexHome = try makeRoot("codex")
        let codexLog = codexHome.appendingPathComponent(
            "sessions/three-days/rollout-2026-08-09T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        try write(samples.enumerated().map { index, sample in
            let total = [100, 200, 300][index]
            let read = [60, 50, 0][index]
            return #"{"timestamp":"\#(sample.timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\#(total),"cached_input_tokens":\#(read)}}}}"#
        }.joined(separator: "\n") + "\n", to: codexLog)
        let codex = CodexUsageService(codexHome: codexHome.path)
        codex.fullScan()
        assertDays(codex.dailyData, samples: samples, expected: [40, 150, 300])

        let claudeHome = try makeRoot("claude")
        let claudeLog = claudeHome.appendingPathComponent("projects/project/session.jsonl")
        try write(samples.enumerated().map { index, sample in
            let input = [10, 20, 30][index]
            let output = [2, 3, 4][index]
            let read = [90, 80, 70][index]
            let creation = [1, 2, 3][index]
            return #"{"type":"assistant","timestamp":"\#(sample.timestamp)","message":{"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(creation)}}}"#
        }.joined(separator: "\n") + "\n", to: claudeLog)
        let claude = ClaudeCodeUsageService(claudeHome: claudeHome.path)
        claude.fullScan()
        assertDays(claude.dailyData, samples: samples, expected: [13, 25, 37])
        assertCache(claude.dailyCache, samples: samples, expected: [90, 80, 70])

        let openClawHome = try makeRoot("openclaw")
        let openClawLog = openClawHome.appendingPathComponent("agents/main/sessions/session.jsonl")
        try write(samples.enumerated().map { index, sample in
            let input = [10, 20, 30][index]
            let output = [2, 3, 4][index]
            let read = [90, 80, 70][index]
            let write = [5, 6, 7][index]
            return #"{"timestamp":"\#(sample.timestamp)","message":{"role":"assistant","usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(read),"cacheWrite":\#(write)}}}"#
        }.joined(separator: "\n") + "\n", to: openClawLog)
        let openClaw = OpenClawUsageService(openclawHome: openClawHome.path)
        openClaw.fullScan()
        assertDays(openClaw.dailyData, samples: samples, expected: [17, 29, 41])
        assertCache(openClaw.dailyCache, samples: samples, expected: [90, 80, 70])

        let geminiHome = try makeRoot("gemini")
        let geminiLog = geminiHome.appendingPathComponent("tmp/project/chats/session-three-days.jsonl")
        try write("{\"sessionId\":\"three-days\"}\n" + samples.enumerated().map { index, sample in
            let input = [100, 200, 300][index]
            let read = [80, 70, 60][index]
            return #"{"type":"gemini","timestamp":"\#(sample.timestamp)","tokens":{"input":\#(input),"output":10,"cached":\#(read),"thought":5}}"#
        }.joined(separator: "\n") + "\n", to: geminiLog)
        let gemini = GeminiUsageService(geminiHome: geminiHome.path)
        gemini.fullScan()
        assertDays(gemini.dailyData, samples: samples, expected: [35, 145, 255])
        assertCache(gemini.dailyCache, samples: samples, expected: [80, 70, 60])

        let qwenHome = try makeRoot("qwen")
        let qwenLog = qwenHome.appendingPathComponent("projects/project/chats/session.jsonl")
        try write(samples.enumerated().map { index, sample in
            let prompt = [100, 200, 300][index]
            let read = [80, 70, 60][index]
            return #"{"timestamp":"\#(sample.timestamp)","usageMetadata":{"promptTokenCount":\#(prompt),"candidatesTokenCount":10,"thoughtsTokenCount":5,"cachedContentTokenCount":\#(read)}}"#
        }.joined(separator: "\n") + "\n", to: qwenLog)
        let qwen = QwenCodeUsageService(qwenHome: qwenHome.path)
        qwen.fullScan()
        assertDays(qwen.dailyData, samples: samples, expected: [35, 145, 255])
        assertCache(qwen.dailyCache, samples: samples, expected: [80, 70, 60])

        let copilotHome = try makeRoot("copilot")
        let copilotLog = copilotHome.appendingPathComponent("otel/usage.jsonl")
        try write(samples.enumerated().map { index, sample in
            let input = [100, 200, 300][index]
            let read = [75, 65, 55][index]
            let creation = [15, 25, 35][index]
            return #"{"startTime":"\#(sample.timestamp)","attributes":{"gen_ai.usage.input_tokens":\#(input),"gen_ai.usage.output_tokens":10,"gen_ai.usage.cache_read.input_tokens":\#(read),"gen_ai.usage.cache_creation.input_tokens":\#(creation)}}"#
        }.joined(separator: "\n") + "\n", to: copilotLog)
        let copilot = CopilotUsageService(copilotHome: copilotHome.path)
        copilot.fullScan()
        assertDays(copilot.dailyData, samples: samples, expected: [35, 145, 255])
        assertCache(copilot.dailyCache, samples: samples, expected: [75, 65, 55])
    }

    func testClineCacheAliasesAcrossThreeDays() throws {
        let samples = threeDaySamples()
        let root = try makeRoot("cline")
        PathConfig.setClinePath(root.path)
        let conversation = root.appendingPathComponent("tasks/task-one/api_conversation.json")
        let objects = [
            #"{"ts":\#(milliseconds(samples[0].date)),"message":{"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":90,"cache_creation_input_tokens":3}}}"#,
            #"{"ts":\#(milliseconds(samples[1].date)),"message":{"usage":{"inputTokens":20,"outputTokens":3,"cacheRead":80,"cacheWrite":4}}}"#,
            #"{"ts":\#(milliseconds(samples[2].date)),"message":{"metadata":{"usage":{"inputTokens":30,"outputTokens":4,"cacheReadInputTokens":70,"cacheCreationInputTokens":5}}}}"#,
        ]
        try write("[" + objects.joined(separator: ",") + "]", to: conversation)

        let cline = ClineUsageService()
        cline.fullScan()
        assertDays(cline.dailyData, samples: samples, expected: [15, 27, 39])
        assertCache(cline.dailyCache, samples: samples, expected: [90, 80, 70])
    }

    func testHermesAndOpenCodeDatabasesAcrossThreeDays() throws {
        let samples = threeDaySamples()

        let hermesRoot = try makeRoot("hermes")
        PathConfig.setHermesPath(hermesRoot.path)
        let hermesDB = hermesRoot.appendingPathComponent("state.db")
        try createDatabase(at: hermesDB, statements: [
            "CREATE TABLE sessions (started_at REAL, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, message_count INTEGER)",
            "INSERT INTO sessions VALUES (\(samples[0].date.timeIntervalSince1970),10,2,90,3,1)",
            "INSERT INTO sessions VALUES (\(samples[1].date.timeIntervalSince1970),0,0,80,4,1)",
            "INSERT INTO sessions VALUES (\(samples[2].date.timeIntervalSince1970),30,4,70,5,1)",
        ])
        let hermes = HermesUsageService()
        hermes.fullScan()
        assertDays(hermes.dailyData, samples: samples, expected: [15, 4, 39])
        assertCache(hermes.dailyCache, samples: samples, expected: [90, 80, 70])

        let openCodeRoot = try makeRoot("opencode")
        PathConfig.setOpenCodePath(openCodeRoot.path)
        let openCodeDB = openCodeRoot.appendingPathComponent("opencode.db")
        try createDatabase(at: openCodeDB, statements: [
            "CREATE TABLE session (tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER)",
            "INSERT INTO session VALUES (10,2,1,90,3,\(milliseconds(samples[0].date)))",
            "INSERT INTO session VALUES (0,0,0,80,4,\(milliseconds(samples[1].date)))",
            "INSERT INTO session VALUES (30,4,2,70,5,\(milliseconds(samples[2].date)))",
        ])
        let openCode = OpenCodeUsageService()
        openCode.fullScan()
        assertDays(openCode.dailyData, samples: samples, expected: [16, 4, 41])
        assertCache(openCode.dailyCache, samples: samples, expected: [90, 80, 70])
    }

    private struct Sample {
        let date: Date
        let timestamp: String
        let key: String
    }

    private func threeDaySamples() -> [Sample] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [-2, -1, 0].map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let noon = calendar.date(byAdding: .hour, value: 12, to: day)!
            return Sample(date: noon, timestamp: formatter.string(from: noon), key: DateHelper.dateKey(from: noon))
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenclock-accounting-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func createDatabase(at url: URL, statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "TokenClockTests", code: 1)
        }
        defer { sqlite3_close(db) }
        for statement in statements {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "TokenClockTests", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }
    }

    private func assertDays(
        _ data: [String: DayUsage], samples: [Sample], expected: [Int],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(samples.count, expected.count, file: file, line: line)
        for (sample, tokens) in zip(samples, expected) {
            XCTAssertEqual(data[sample.key]?.tokens, tokens, "date=\(sample.key)", file: file, line: line)
            XCTAssertEqual(data[sample.key]?.messages, 1, "date=\(sample.key)", file: file, line: line)
        }
    }

    private func assertCache(
        _ data: [String: Int], samples: [Sample], expected: [Int],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (sample, tokens) in zip(samples, expected) {
            XCTAssertEqual(data[sample.key] ?? 0, tokens, "date=\(sample.key)", file: file, line: line)
        }
    }
}
