import Foundation
import XCTest
@testable import TokenClock

final class UsageServicePerformanceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testCodexAppendOnlyIncrementalScanPreservesTotalsAndEvictsDeletedFile() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home.appendingPathComponent("sessions/2026/08/06", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent(
            "rollout-2026-08-06T12-00-00-11111111-2222-3333-4444-555555555555.jsonl"
        )
        let timestamp = todayTimestamp()
        let first = codexTurn(model: "gpt-5.6") + "\n" + codexUsage(timestamp: timestamp, total: 120, cached: 40) + "\n"
        try Data(first.utf8).write(to: rollout)

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 80, messages: 1, cacheRate: 40.0 / 120.0)

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexUsage(timestamp: timestamp, total: 80, cached: 20).utf8))
        try handle.close()

        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 140, messages: 2, cacheRate: 60.0 / 200.0)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 140, messages: 2, cacheRate: 60.0 / 200.0)

        try FileManager.default.removeItem(at: rollout)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
    }

    func testCodexPreservesHourlyAndBoundedRecentUsageAcrossAppendAndTruncate() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home.appendingPathComponent("sessions/current", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent(
            "rollout-2026-08-06T12-00-00-99999999-2222-3333-4444-555555555555.jsonl"
        )
        let now = Date()
        let recentTimestamp = isoTimestamp(now)
        let staleTimestamp = isoTimestamp(now.addingTimeInterval(-2 * 60 * 60))
        let initial = codexUsageWithReorderedFields(timestamp: staleTimestamp, total: 900, cached: 90)
            + "\n" + codexUsageWithReorderedFields(timestamp: recentTimestamp, total: 100, cached: 10) + "\n"
        try write(initial, to: rollout)

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        XCTAssertEqual(service.currentHourTokens(), 90)
        XCTAssertEqual(service.recentUsage(minutes: 10).tokens, 90)
        XCTAssertEqual(service.recentUsage(minutes: 10).messages, 1)
        XCTAssertEqual(service.recentUsage(minutes: 60).tokens, 90)

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((codexUsage(timestamp: recentTimestamp, total: 50, cached: 5) + "\n").utf8))
        try handle.close()
        service.incrementalScan()
        XCTAssertEqual(service.currentHourTokens(), 135)
        XCTAssertEqual(service.recentUsage(minutes: 10).tokens, 135)
        XCTAssertEqual(service.recentUsage(minutes: 10).messages, 2)

        try write(codexUsage(timestamp: recentTimestamp, total: 7, cached: 2) + "\n", to: rollout)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 5, messages: 1, cacheRate: 2.0 / 7.0)
        XCTAssertEqual(service.currentHourTokens(), 5)
        XCTAssertEqual(service.recentUsage(minutes: 10).tokens, 5)
        XCTAssertEqual(service.recentUsage(minutes: 10).messages, 1)
    }

    func testOptimizedDateHelperMatchesLegacyDateAndHourKeys() {
        for timestamp in [
            "2026-01-01T00:00:00Z",
            "2026-03-08T09:59:59.999Z",
            "2026-11-01T09:00:00Z",
            "2026-12-31T23:59:59Z",
        ] {
            XCTAssertEqual(DateHelper.localDateKey(from: timestamp), legacyLocalDateKey(from: timestamp))
            XCTAssertEqual(DateHelper.localHourKey(from: timestamp), legacyLocalHourKey(from: timestamp))
        }
    }

    func testDateHelperMatchesISO8601ReferenceForFractionsAndOffsets() throws {
        for timestamp in [
            "2026-08-06T12:00:00Z",
            "2026-08-06T12:00:00.125Z",
            "2026-08-06T00:30:00+08:00",
            "2026-08-06T23:45:30.500-0730",
            "2026-01-01T00:15:00+14:00",
            "2026-12-31T23:45:00-12:00",
        ] {
            let expected = try XCTUnwrap(referenceISO8601Date(timestamp))
            let actual = try XCTUnwrap(DateHelper.parseISO8601(timestamp))
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)
            XCTAssertEqual(DateHelper.localDateKey(from: timestamp), DateHelper.dateKey(from: expected))
            XCTAssertEqual(DateHelper.localHourKey(from: timestamp), DateHelper.hourKey(from: expected))
        }
    }

    func testClaudeNestedSessionRemainsVisibleWithoutChangingToolTotal() throws {
        let home = try makeTemporaryDirectory()
        let project = home.appendingPathComponent("projects/project-a", isDirectory: true)
        let nested = project.appendingPathComponent("subagents", isDirectory: true)
        let metadata = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        let timestamp = todayTimestamp()
        try write(claudeUsage(timestamp: timestamp, input: 10, output: 5, cacheRead: 2, cacheCreate: 1, model: "claude-sonnet-4-5"),
                  to: project.appendingPathComponent("top-session.jsonl"))
        let nestedLog = nested.appendingPathComponent("nested-session.jsonl")
        try write(claudeUsage(timestamp: timestamp, input: 20, output: 3, cacheRead: 1, cacheCreate: 0, model: "claude-opus-4-1"),
                  to: nestedLog)
        try write("{\"sessionId\":\"top-session\",\"cwd\":\"/tmp/top\"}",
                  to: metadata.appendingPathComponent("top.json"))
        try write("{\"sessionId\":\"nested-session\",\"cwd\":\"/tmp/nested\"}",
                  to: metadata.appendingPathComponent("nested.json"))

        let service = ClaudeCodeUsageService(claudeHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 16, messages: 1, cacheRate: 2.0 / 18.0)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: service.todaySessions().map { ($0.rawId, $0.todayTokens) }), [
            "top-session": 16,
            "nested-session": 23,
        ])

        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 16, messages: 1, cacheRate: 2.0 / 18.0)
        try FileManager.default.removeItem(at: nestedLog)
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions().map(\.rawId), ["top-session"])
    }

    func testOpenClawCachedDetailsExcludeCronAndEvictRenamedAndDeletedFiles() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = todayTimestamp()
        let live = sessions.appendingPathComponent("live.jsonl")
        try write(openClawUsage(timestamp: timestamp, input: 3, output: 4, cacheRead: 5, cacheWrite: 6, model: "gpt-5.6"), to: live)
        try write(openClawCronLine() + "\n" + openClawUsage(timestamp: timestamp, input: 100, output: 100, cacheRead: 0, cacheWrite: 0, model: "ignored"),
                  to: sessions.appendingPathComponent("cron.jsonl"))

        let service = OpenClawUsageService(openclawHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 13, messages: 1, cacheRate: 5.0 / 18.0)
        XCTAssertEqual(service.todaySessions().first?.todayTokens, 13)
        XCTAssertEqual(service.todaySessions().first?.model, "gpt-5.6")
        let expectedCost = (3.0 * 5.0 + 4.0 * 30.0 + 5.0 * 0.5 + 6.0 * 6.25) / 1_000_000.0
        XCTAssertEqual(service.todayCost().value, expectedCost, accuracy: 0.0000001)
        XCTAssertTrue(service.todayCost().available)
        XCTAssertEqual(service.todaySessions().first?.todayCost.value ?? -1, expectedCost, accuracy: 0.0000001)
        XCTAssertEqual(service.todayCacheReadTokens(), 5)

        let renamed = sessions.appendingPathComponent("renamed.jsonl")
        try FileManager.default.moveItem(at: live, to: renamed)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 13, messages: 1, cacheRate: 5.0 / 18.0)
        XCTAssertEqual(service.todaySessions().count, 1)

        try FileManager.default.removeItem(at: renamed)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        XCTAssertTrue(service.todaySessions().isEmpty)
    }

    func testGeminiCachedDetailsPreserveJSONLPriorityAndFallbackAfterDeletion() throws {
        let home = try makeTemporaryDirectory()
        let chats = home.appendingPathComponent("tmp/project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let timestamp = todayTimestamp()
        let jsonl = chats.appendingPathComponent("session-shared.jsonl")
        let json = chats.appendingPathComponent("session-shared.json")
        try write(
            "{\"sessionId\":\"gemini-jsonl\"}\n"
                + geminiEvent(timestamp: timestamp, input: 10, output: 5, cached: 3, thought: 2, model: "gemini-2.5-pro"),
            to: jsonl
        )
        try write(
            "{\"sessionId\":\"gemini-json\",\"messages\":["
                + geminiEvent(timestamp: timestamp, input: 40, output: 1, cached: 4, thought: 0, model: "gemini-2.5-flash")
                + "]}",
            to: json
        )

        let service = GeminiUsageService(geminiHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 14, messages: 1, cacheRate: 3.0 / 17.0)
        XCTAssertEqual(service.todaySessions().map(\.rawId), ["gemini-jsonl"])
        XCTAssertEqual(service.todaySessions().first?.model, "gemini-2.5-pro")

        try FileManager.default.removeItem(at: jsonl)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 37, messages: 1, cacheRate: 4.0 / 41.0)
        XCTAssertEqual(service.todaySessions().map(\.rawId), ["gemini-json"])
        XCTAssertEqual(service.todaySessions().first?.model, "gemini-2.5-flash")
    }

    func testGeminiSkipsSessionsOutsideRecentLookbackUntilTheyChange() throws {
        let home = try makeTemporaryDirectory()
        let chats = home.appendingPathComponent("tmp/project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let session = chats.appendingPathComponent("session-stale.jsonl")
        try write(
            "{\"sessionId\":\"stale-session\"}\n"
                + geminiEvent(timestamp: todayTimestamp(), input: 10, output: 5, cached: 3, thought: 2, model: "gemini-2.5-pro"),
            to: session
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * AppConfig.Scan.oneDaySeconds)],
            ofItemAtPath: session.path
        )

        let service = GeminiUsageService(geminiHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: session.path)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 14, messages: 1, cacheRate: 3.0 / 17.0)
    }

    func testQwenCachedDetailsPreserveTotalsAndEvictRenamedDeletedFiles() throws {
        let home = try makeTemporaryDirectory()
        let chats = home.appendingPathComponent("projects/project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let original = chats.appendingPathComponent("qwen-one.jsonl")
        try write(geminiEvent(timestamp: todayTimestamp(), input: 10, output: 5, cached: 3, thought: 2, model: "qwen3-coder") + "\n", to: original)

        let service = QwenCodeUsageService(qwenHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 14, messages: 1, cacheRate: 3.0 / 17.0)
        XCTAssertEqual(service.todaySessions().first?.rawId, "qwen-one.jsonl")
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 14, messages: 1, cacheRate: 3.0 / 17.0)

        let renamed = chats.appendingPathComponent("qwen-two.jsonl")
        try FileManager.default.moveItem(at: original, to: renamed)
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions().first?.rawId, "qwen-two.jsonl")
        try FileManager.default.removeItem(at: renamed)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        XCTAssertTrue(service.todaySessions().isEmpty)
    }

    func testCopilotCachedSessionDetailsAndFileEviction() throws {
        let home = try makeTemporaryDirectory()
        let otel = home.appendingPathComponent("otel", isDirectory: true)
        let sessionOne = home.appendingPathComponent("session-state/session-one", isDirectory: true)
        try FileManager.default.createDirectory(at: otel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionOne, withIntermediateDirectories: true)
        let timestamp = todayTimestamp()
        let otelLog = otel.appendingPathComponent("usage.jsonl")
        try write(copilotOtelEvent(timestamp: timestamp, input: 10, output: 5, cached: 2, cacheWrite: 3) + "\n", to: otelLog)
        try write(copilotSessionEvent(timestamp: timestamp, input: 3, output: 4, cached: 1, cacheWrite: 2) + "\n", to: sessionOne.appendingPathComponent("events.jsonl"))

        let service = CopilotUsageService(copilotHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 19, messages: 2, cacheRate: 3.0 / 22.0)
        XCTAssertEqual(service.todaySessions().first?.rawId, "session-one")
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 19, messages: 2, cacheRate: 3.0 / 22.0)

        let sessionTwo = home.appendingPathComponent("session-state/session-two", isDirectory: true)
        try FileManager.default.moveItem(at: sessionOne, to: sessionTwo)
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions().first?.rawId, "session-two")
        try FileManager.default.removeItem(at: sessionTwo)
        try FileManager.default.removeItem(at: otelLog)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        XCTAssertTrue(service.todaySessions().isEmpty)
    }

    func testContinueCachedSessionDetailsAndFileEviction() throws {
        let home = try makeTemporaryDirectory()
        let devData = home.appendingPathComponent("dev_data", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: devData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = todayTimestamp()
        let devLog = devData.appendingPathComponent("dev.jsonl")
        let sessionOne = sessions.appendingPathComponent("continue-one.jsonl")
        try write(continueEvent(timestamp: timestamp, input: 10, output: 5) + "\n", to: devLog)
        try write(continueEvent(timestamp: timestamp, input: 3, output: 2) + "\n", to: sessionOne)

        let service = ContinueUsageService(continueHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 20, messages: 2, cacheRate: 0)
        XCTAssertEqual(service.todaySessions().first?.rawId, "continue-one.jsonl")
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 20, messages: 2, cacheRate: 0)

        let sessionTwo = sessions.appendingPathComponent("continue-two.jsonl")
        try FileManager.default.moveItem(at: sessionOne, to: sessionTwo)
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions().first?.rawId, "continue-two.jsonl")
        try FileManager.default.removeItem(at: sessionTwo)
        try FileManager.default.removeItem(at: devLog)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        XCTAssertTrue(service.todaySessions().isEmpty)
    }

    func testGrokCachedSessionDetailsAndDirectoryRenameEviction() throws {
        let home = try makeTemporaryDirectory()
        let sessionOne = home.appendingPathComponent("sessions/project-a/session-one", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionOne, withIntermediateDirectories: true)
        try write(grokEvent(timestamp: todayTimestamp(), tokens: 12) + "\n" + grokEvent(timestamp: todayTimestamp(), tokens: 8) + "\n",
                  to: sessionOne.appendingPathComponent("updates.jsonl"))

        let service = GrokUsageService(grokHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 20, messages: 2, cacheRate: 0)
        XCTAssertEqual(service.todaySessions().first?.rawId, "session-one")
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 20, messages: 2, cacheRate: 0)

        let sessionTwo = home.appendingPathComponent("sessions/project-a/session-two", isDirectory: true)
        try FileManager.default.moveItem(at: sessionOne, to: sessionTwo)
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions().first?.rawId, "session-two")
        try FileManager.default.removeItem(at: sessionTwo)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        XCTAssertTrue(service.todaySessions().isEmpty)
    }

    func testAiderSharedReaderPreservesTotalsAndClearsMissingLog() throws {
        let home = try makeTemporaryDirectory()
        let analytics = home.appendingPathComponent("analytics.jsonl")
        try write(aiderEvent(time: Date().timeIntervalSince1970, prompt: 7, completion: 3) + "\n", to: analytics)

        let service = AiderUsageService(aiderHome: home.path)
        service.fullScan()
        assertUsage(service.todayUsage(), tokens: 10, messages: 1, cacheRate: 0)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 10, messages: 1, cacheRate: 0)

        let renamed = home.appendingPathComponent("analytics-renamed.jsonl")
        try FileManager.default.moveItem(at: analytics, to: renamed)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 0, messages: 0, cacheRate: 0)
        try FileManager.default.moveItem(at: renamed, to: analytics)
        service.incrementalScan()
        assertUsage(service.todayUsage(), tokens: 10, messages: 1, cacheRate: 0)
    }

    func testCodexLargeFixtureBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_BENCHMARKS=1 to run the large JSONL benchmark")
        }

        let home = try makeTemporaryDirectory()
        let sessions = home.appendingPathComponent("sessions/benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent(
            "rollout-2026-08-06T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        let timestamp = todayTimestamp()
        let turn = codexTurn(model: "gpt-5.6") + "\n"
        let usage = codexUsage(timestamp: timestamp, total: 10, cached: 4) + "\n"
        var fixture = Data(turn.utf8)
        for _ in 0..<20_000 { fixture.append(contentsOf: usage.utf8) }
        try fixture.write(to: rollout)

        var legacyResult = (tokens: 0, messages: 0, cache: 0)
        let legacyFullMilliseconds = elapsedMilliseconds {
            legacyResult = legacyCodexScan(rollout)
        }
        let legacyUnchangedMilliseconds = elapsedMilliseconds {
            _ = (try? FileManager.default.attributesOfItem(atPath: rollout.path)[.size]) as? NSNumber
        }

        let service = CodexUsageService(codexHome: home.path)
        let fullMilliseconds = elapsedMilliseconds { service.fullScan() }
        let unchangedMilliseconds = elapsedMilliseconds { service.incrementalScan() }

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(usage.utf8))
        try handle.close()
        let legacyAppendMilliseconds = elapsedMilliseconds {
            legacyResult = legacyCodexScan(rollout)
        }
        let appendMilliseconds = elapsedMilliseconds { service.incrementalScan() }

        let result = service.todayUsage()
        XCTAssertEqual(result.tokens, 120_006)
        XCTAssertEqual(result.messages, 20_001)
        XCTAssertEqual(legacyResult.tokens, result.tokens)
        XCTAssertEqual(legacyResult.messages, result.messages)
        XCTAssertEqual(legacyResult.cache, 80_004)
        print(String(format:
            "TOKENCLOCK_BENCHMARK bytes=%d legacy_full_ms=%.3f legacy_unchanged_ms=%.3f legacy_append_ms=%.3f optimized_full_ms=%.3f optimized_unchanged_ms=%.3f optimized_append_ms=%.3f",
            fixture.count,
            legacyFullMilliseconds, legacyUnchangedMilliseconds, legacyAppendMilliseconds,
            fullMilliseconds, unchangedMilliseconds, appendMilliseconds
        ))
    }

    func testProviderLargeFixtureBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_BENCHMARKS=1 to run provider JSONL benchmarks")
        }
        let home = try makeTemporaryDirectory()
        let timestamp = todayTimestamp()
        let iterations = 5_000

        let qwenURL = home.appendingPathComponent("qwen/projects/project/chats/large.jsonl")
        let continueURL = home.appendingPathComponent("continue/sessions/large.jsonl")
        let copilotURL = home.appendingPathComponent("copilot/session-state/large/events.jsonl")
        let grokURL = home.appendingPathComponent("grok/sessions/project/large/updates.jsonl")
        let aiderURL = home.appendingPathComponent("aider/analytics.jsonl")
        for url in [qwenURL, continueURL, copilotURL, grokURL, aiderURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try writeRepeated(geminiEvent(timestamp: timestamp, input: 10, output: 5, cached: 3, thought: 2, model: "qwen3") + "\n", count: iterations, to: qwenURL)
        try writeRepeated(continueEvent(timestamp: timestamp, input: 10, output: 5) + "\n", count: iterations, to: continueURL)
        try writeRepeated(copilotSessionEvent(timestamp: timestamp, input: 3, output: 4, cached: 1) + "\n", count: iterations, to: copilotURL)
        try writeRepeated(grokEvent(timestamp: timestamp, tokens: 12) + "\n", count: iterations, to: grokURL)
        try writeRepeated(aiderEvent(time: Date().timeIntervalSince1970, prompt: 7, completion: 3) + "\n", count: iterations, to: aiderURL)

        var legacyTotal = 0
        let qwenLegacy = elapsedMilliseconds { legacyTotal = legacyJSONLTokenScan(qwenURL, tokenExtractor: qwenTokens) }
        let qwen = QwenCodeUsageService(qwenHome: home.appendingPathComponent("qwen").path)
        let qwenFull = elapsedMilliseconds { qwen.fullScan() }
        let qwenDetail = elapsedMilliseconds { _ = qwen.todaySessions() }
        XCTAssertEqual(legacyTotal, qwen.todayUsage().tokens)

        let continueLegacy = elapsedMilliseconds { legacyTotal = legacyJSONLTokenScan(continueURL, tokenExtractor: continueTokens) }
        let continueService = ContinueUsageService(continueHome: home.appendingPathComponent("continue").path)
        let continueFull = elapsedMilliseconds { continueService.fullScan() }
        let continueDetail = elapsedMilliseconds { _ = continueService.todaySessions() }
        XCTAssertEqual(legacyTotal, continueService.todayUsage().tokens)

        let copilotLegacy = elapsedMilliseconds { legacyTotal = legacyJSONLTokenScan(copilotURL, tokenExtractor: copilotTokens) }
        let copilot = CopilotUsageService(copilotHome: home.appendingPathComponent("copilot").path)
        let copilotFull = elapsedMilliseconds { copilot.fullScan() }
        let copilotDetail = elapsedMilliseconds { _ = copilot.todaySessions() }
        XCTAssertEqual(legacyTotal, copilot.todayUsage().tokens)

        let grokLegacy = elapsedMilliseconds { legacyTotal = legacyJSONLTokenScan(grokURL, tokenExtractor: grokTokens) }
        let grok = GrokUsageService(grokHome: home.appendingPathComponent("grok").path)
        let grokFull = elapsedMilliseconds { grok.fullScan() }
        let grokDetail = elapsedMilliseconds { _ = grok.todaySessions() }
        XCTAssertEqual(legacyTotal, grok.todayUsage().tokens)

        let aiderLegacy = elapsedMilliseconds { legacyTotal = legacyJSONLTokenScan(aiderURL, tokenExtractor: aiderTokens) }
        let aider = AiderUsageService(aiderHome: home.appendingPathComponent("aider").path)
        let aiderFull = elapsedMilliseconds { aider.fullScan() }
        XCTAssertEqual(legacyTotal, aider.todayUsage().tokens)

        print(String(format:
            "TOKENCLOCK_PROVIDER_BENCHMARK lines=%d qwen_legacy_decode_lower_bound_ms=%.3f qwen_full_ms=%.3f qwen_cached_detail_ms=%.3f continue_legacy_decode_lower_bound_ms=%.3f continue_full_ms=%.3f continue_cached_detail_ms=%.3f copilot_legacy_decode_lower_bound_ms=%.3f copilot_full_ms=%.3f copilot_cached_detail_ms=%.3f grok_legacy_decode_lower_bound_ms=%.3f grok_full_ms=%.3f grok_cached_detail_ms=%.3f aider_legacy_decode_lower_bound_ms=%.3f aider_full_ms=%.3f",
            iterations,
            qwenLegacy, qwenFull, qwenDetail,
            continueLegacy, continueFull, continueDetail,
            copilotLegacy, copilotFull, copilotDetail,
            grokLegacy, grokFull, grokDetail,
            aiderLegacy, aiderFull
        ))
    }

    func testReadOnlyRealDataBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_REAL_DATA_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_REAL_DATA_BENCHMARKS=1 to scan local provider data")
        }

        let codex = CodexUsageService()
        let codexFull = elapsedMilliseconds { codex.fullScan() }
        let codexDetails = elapsedMilliseconds { _ = codex.todaySessions() }
        let codexIncremental = elapsedMilliseconds { codex.incrementalScan() }

        let claude = ClaudeCodeUsageService()
        let claudeFull = elapsedMilliseconds { claude.fullScan() }
        let claudeDetails = elapsedMilliseconds { _ = claude.todaySessions() }
        let claudeIncremental = elapsedMilliseconds { claude.incrementalScan() }

        let openClaw = OpenClawUsageService()
        let openClawFull = elapsedMilliseconds { openClaw.fullScan() }
        let openClawDetails = elapsedMilliseconds { _ = openClaw.todaySessions() }
        let openClawIncremental = elapsedMilliseconds { openClaw.incrementalScan() }

        let gemini = GeminiUsageService()
        let geminiFull = elapsedMilliseconds { gemini.fullScan() }
        let geminiDetails = elapsedMilliseconds { _ = gemini.todaySessions() }
        let geminiIncremental = elapsedMilliseconds { gemini.incrementalScan() }

        let cline = ClineUsageService()
        let clineFull = elapsedMilliseconds { cline.fullScan() }
        let clineDetails = elapsedMilliseconds { _ = cline.todaySessions() }
        let clineIncremental = elapsedMilliseconds { cline.incrementalScan() }

        let antigravity = AntigravityUsageService()
        let antigravityFull = elapsedMilliseconds { antigravity.fullScan() }
        let antigravityDetails = elapsedMilliseconds { _ = antigravity.todaySessions() }
        let antigravityIncremental = elapsedMilliseconds { antigravity.incrementalScan() }

        let hermes = HermesUsageService()
        let hermesFull = elapsedMilliseconds { hermes.fullScan() }
        let hermesDetails = elapsedMilliseconds { _ = hermes.todaySessions() }
        let hermesIncremental = elapsedMilliseconds { hermes.incrementalScan() }

        let openCode = OpenCodeUsageService()
        let openCodeFull = elapsedMilliseconds { openCode.fullScan() }
        let openCodeDetails = elapsedMilliseconds { _ = openCode.todaySessions() }
        let openCodeIncremental = elapsedMilliseconds { openCode.incrementalScan() }

        let qwen = QwenCodeUsageService()
        let qwenFull = elapsedMilliseconds { qwen.fullScan() }
        let qwenDetails = elapsedMilliseconds { _ = qwen.todaySessions() }
        let qwenIncremental = elapsedMilliseconds { qwen.incrementalScan() }

        let copilot = CopilotUsageService()
        let copilotFull = elapsedMilliseconds { copilot.fullScan() }
        let copilotDetails = elapsedMilliseconds { _ = copilot.todaySessions() }
        let copilotIncremental = elapsedMilliseconds { copilot.incrementalScan() }

        let continueService = ContinueUsageService()
        let continueFull = elapsedMilliseconds { continueService.fullScan() }
        let continueDetails = elapsedMilliseconds { _ = continueService.todaySessions() }
        let continueIncremental = elapsedMilliseconds { continueService.incrementalScan() }

        let grok = GrokUsageService()
        let grokFull = elapsedMilliseconds { grok.fullScan() }
        let grokDetails = elapsedMilliseconds { _ = grok.todaySessions() }
        let grokIncremental = elapsedMilliseconds { grok.incrementalScan() }

        let aider = AiderUsageService()
        let aiderFull = elapsedMilliseconds { aider.fullScan() }
        let aiderIncremental = elapsedMilliseconds { aider.incrementalScan() }

        print(String(format:
            "TOKENCLOCK_REAL_BENCHMARK codex_full_ms=%.3f codex_detail_ms=%.3f codex_incremental_ms=%.3f claude_full_ms=%.3f claude_detail_ms=%.3f claude_incremental_ms=%.3f openclaw_full_ms=%.3f openclaw_detail_ms=%.3f openclaw_incremental_ms=%.3f gemini_full_ms=%.3f gemini_detail_ms=%.3f gemini_incremental_ms=%.3f cline_full_ms=%.3f cline_detail_ms=%.3f cline_incremental_ms=%.3f antigravity_full_ms=%.3f antigravity_detail_ms=%.3f antigravity_incremental_ms=%.3f hermes_full_ms=%.3f hermes_detail_ms=%.3f hermes_incremental_ms=%.3f opencode_full_ms=%.3f opencode_detail_ms=%.3f opencode_incremental_ms=%.3f qwen_full_ms=%.3f qwen_detail_ms=%.3f qwen_incremental_ms=%.3f copilot_full_ms=%.3f copilot_detail_ms=%.3f copilot_incremental_ms=%.3f continue_full_ms=%.3f continue_detail_ms=%.3f continue_incremental_ms=%.3f grok_full_ms=%.3f grok_detail_ms=%.3f grok_incremental_ms=%.3f aider_full_ms=%.3f aider_incremental_ms=%.3f",
            codexFull, codexDetails, codexIncremental,
            claudeFull, claudeDetails, claudeIncremental,
            openClawFull, openClawDetails, openClawIncremental,
            geminiFull, geminiDetails, geminiIncremental,
            clineFull, clineDetails, clineIncremental,
            antigravityFull, antigravityDetails, antigravityIncremental,
            hermesFull, hermesDetails, hermesIncremental,
            openCodeFull, openCodeDetails, openCodeIncremental,
            qwenFull, qwenDetails, qwenIncremental,
            copilotFull, copilotDetails, copilotIncremental,
            continueFull, continueDetails, continueIncremental,
            grokFull, grokDetails, grokIncremental,
            aiderFull, aiderIncremental
        ))
        if let rawSeconds = ProcessInfo.processInfo.environment["TOKENCLOCK_REAL_IDLE_SECONDS"],
           let seconds = UInt32(rawSeconds), seconds > 0 {
            Thread.sleep(forTimeInterval: TimeInterval(seconds))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClockPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func todayTimestamp() -> String {
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        return ISO8601DateFormatter().string(from: noon)
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func referenceISO8601Date(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: timestamp)
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    private func writeRepeated(_ line: String, count: Int, to url: URL) throws {
        let bytes = Data(line.utf8)
        var data = Data()
        data.reserveCapacity(bytes.count * count)
        for _ in 0..<count { data.append(bytes) }
        try data.write(to: url)
    }

    private func elapsedMilliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Test-only reproduction of the e7611ea Codex line-buffer/date path. It is
    /// intentionally not shared with product code and provides before/after
    /// timing plus an independent parity result on the same fixture.
    private func legacyCodexScan(_ url: URL) -> (tokens: Int, messages: Int, cache: Int) {
        guard let stream = InputStream(url: url) else { return (0, 0, 0) }
        stream.open()
        defer { stream.close() }
        let bufferSize = AppConfig.Scan.jsonlBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var lineBuffer = Data()
        var totals = (tokens: 0, messages: 0, cache: 0)

        func parse(_ lineData: Data.SubSequence) {
            guard let line = String(data: lineData, encoding: .utf8),
                  line.contains("\"type\":\"token_count\",\"info\""),
                  let usageRange = line.range(of: "\"last_token_usage\":{") else { return }
            let timestamp = legacyTimestamp(from: line)
            guard !timestamp.isEmpty, !legacyLocalDateKey(from: timestamp).isEmpty else { return }
            let usage = String(line[usageRange.lowerBound...].prefix(500))
            let total = legacyExtractInt(usage, key: "\"total_tokens\"")
            let cached = legacyExtractInt(usage, key: "\"cached_input_tokens\"")
            let tokens = max(0, total - cached)
            guard tokens > 0 else { return }
            totals.tokens += tokens
            totals.messages += 1
            totals.cache += cached
        }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            lineBuffer.append(buffer, count: count)
            while let newline = lineBuffer.range(of: Data([0x0A])) {
                parse(lineBuffer[lineBuffer.startIndex..<newline.lowerBound])
                lineBuffer = lineBuffer[newline.upperBound...]
            }
        }
        if !lineBuffer.isEmpty { parse(lineBuffer[lineBuffer.startIndex...]) }
        return totals
    }

    private func legacyTimestamp(from line: String) -> String {
        guard let range = line.range(of: "\"timestamp\":\"") else { return "" }
        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return "" }
        return String(line[start..<end])
    }

    private func legacyLocalDateKey(from timestamp: String) -> String {
        legacyLocalKey(from: timestamp, format: "yyyy-MM-dd")
    }

    private func legacyLocalHourKey(from timestamp: String) -> String {
        legacyLocalKey(from: timestamp, format: "yyyy-MM-dd-HH")
    }

    private func legacyLocalKey(from timestamp: String, format: String) -> String {
        let characters = Array(timestamp)
        guard characters.count >= 19 else { return "" }
        let year = Int(String(characters[0...3])) ?? 0
        let month = Int(String(characters[5...6])) ?? 1
        let day = Int(String(characters[8...9])) ?? 1
        let hour = Int(String(characters[11...12])) ?? 0
        let minute = Int(String(characters[14...15])) ?? 0
        let second = Int(String(characters[17...18])) ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func legacyExtractInt(_ string: String, key: String) -> Int {
        guard let range = string.range(of: key) else { return 0 }
        let digits = string[range.upperBound...].drop(while: { $0 == ":" || $0 == " " })
        return Int(digits.prefix(while: \.isNumber)) ?? 0
    }

    private func legacyJSONLTokenScan(
        _ url: URL,
        tokenExtractor: ([String: Any]) -> Int
    ) -> Int {
        guard let stream = InputStream(url: url) else { return 0 }
        stream.open()
        defer { stream.close() }
        let size = AppConfig.Scan.jsonlBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var lineBuffer = Data()
        var tokens = 0
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: size)
            if count <= 0 { break }
            lineBuffer.append(buffer, count: count)
            while let newline = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer[lineBuffer.startIndex..<newline.lowerBound]
                lineBuffer = lineBuffer[newline.upperBound...]
                guard !lineData.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                tokens += tokenExtractor(object)
            }
        }
        return tokens
    }

    private func qwenTokens(_ object: [String: Any]) -> Int {
        guard let values = object["tokens"] as? [String: Any] else { return 0 }
        return max(0, (values["input"] as? Int ?? 0) - (values["cached"] as? Int ?? 0))
            + (values["output"] as? Int ?? 0)
            + (values["thought"] as? Int ?? 0)
    }

    private func continueTokens(_ object: [String: Any]) -> Int {
        guard let values = object["tokens"] as? [String: Any] else { return 0 }
        return (values["input"] as? Int ?? 0) + (values["output"] as? Int ?? 0)
    }

    private func copilotTokens(_ object: [String: Any]) -> Int {
        guard let values = object["usage"] as? [String: Any] else { return 0 }
        return max(0, (values["inputTokens"] as? Int ?? 0) - (values["cacheReadTokens"] as? Int ?? 0))
            + (values["outputTokens"] as? Int ?? 0)
    }

    private func grokTokens(_ object: [String: Any]) -> Int {
        object["totalTokens"] as? Int ?? 0
    }

    private func aiderTokens(_ object: [String: Any]) -> Int {
        guard let values = object["properties"] as? [String: Any] else { return 0 }
        return (values["prompt_tokens"] as? Int ?? 0)
            + (values["completion_tokens"] as? Int ?? 0)
    }

    private func assertUsage(
        _ usage: (tokens: Int, messages: Int, cacheRate: Double),
        tokens: Int,
        messages: Int,
        cacheRate: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(usage.tokens, tokens, file: file, line: line)
        XCTAssertEqual(usage.messages, messages, file: file, line: line)
        XCTAssertEqual(usage.cacheRate, cacheRate, accuracy: 0.000_001, file: file, line: line)
    }

    private func codexTurn(model: String) -> String {
        "{\"payload\":{\"type\":\"turn_context\",\"model\":\"\(model)\"}}"
    }

    private func codexUsage(timestamp: String, total: Int, cached: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(total),\"cached_input_tokens\":\(cached)}}}}"
    }

    private func codexUsageWithReorderedFields(timestamp: String, total: Int, cached: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"info\":{\"last_token_usage\":{\"total_tokens\":\(total),\"cached_input_tokens\":\(cached)}},\"extra\":true,\"type\":\"token_count\"}}"
    }

    private func claudeUsage(
        timestamp: String, input: Int, output: Int, cacheRead: Int, cacheCreate: Int, model: String
    ) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheCreate)}}}"
    }

    private func openClawUsage(
        timestamp: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, model: String
    ) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"message\":{\"role\":\"assistant\",\"model\":\"\(model)\",\"usage\":{\"input\":\(input),\"output\":\(output),\"cacheRead\":\(cacheRead),\"cacheWrite\":\(cacheWrite)}}}"
    }

    private func openClawCronLine() -> String {
        "{\"message\":{\"role\":\"user\",\"content\":[{\"text\":\"[cron:12345678-1234-1234-1234-123456789abc task]\"}]}}"
    }

    private func geminiEvent(
        timestamp: String, input: Int, output: Int, cached: Int, thought: Int, model: String
    ) -> String {
        "{\"type\":\"gemini\",\"timestamp\":\"\(timestamp)\",\"model\":\"\(model)\",\"tokens\":{\"input\":\(input),\"output\":\(output),\"cached\":\(cached),\"thought\":\(thought)}}"
    }

    private func copilotOtelEvent(timestamp: String, input: Int, output: Int, cached: Int, cacheWrite: Int = 0) -> String {
        "{\"startTime\":\"\(timestamp)\",\"attributes\":{\"gen_ai.usage.input_tokens\":\(input),\"gen_ai.usage.output_tokens\":\(output),\"gen_ai.usage.cache_read.input_tokens\":\(cached),\"gen_ai.usage.cache_creation.input_tokens\":\(cacheWrite)}}"
    }

    private func copilotSessionEvent(timestamp: String, input: Int, output: Int, cached: Int, cacheWrite: Int = 0) -> String {
        "{\"type\":\"assistant.usage\",\"timestamp\":\"\(timestamp)\",\"usage\":{\"inputTokens\":\(input),\"outputTokens\":\(output),\"cacheReadTokens\":\(cached),\"cacheWriteTokens\":\(cacheWrite)}}"
    }

    private func continueEvent(timestamp: String, input: Int, output: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"tokens\":{\"input\":\(input),\"output\":\(output)}}"
    }

    private func grokEvent(timestamp: String, tokens: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"totalTokens\":\(tokens)}"
    }

    private func aiderEvent(time: TimeInterval, prompt: Int, completion: Int) -> String {
        "{\"event\":\"message_send\",\"time\":\(time),\"properties\":{\"prompt_tokens\":\(prompt),\"completion_tokens\":\(completion)}}"
    }
}
