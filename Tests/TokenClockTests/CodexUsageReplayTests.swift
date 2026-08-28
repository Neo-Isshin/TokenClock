import Foundation
import XCTest
@testable import TokenClock

final class CodexUsageReplayTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testSubagentReplayAndUnchangedCumulativeTotalsAreNotCountedTwice() throws {
        let home = try makeRoot()
        try write("service_tier = \"priority\"\n", to: home.appendingPathComponent("config.toml"))
        let directory = home.appendingPathComponent("sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parentId = "019fa671-a3fc-7902-8b91-6077ac1b28c3"
        let childId = "01a02f00-718b-7031-bb0b-ca131484f757"
        let now = Date()
        let parentFirst = now.addingTimeInterval(-30)
        let parentSecond = now.addingTimeInterval(-20)
        let fork = now.addingTimeInterval(-10)
        let childOwn = now.addingTimeInterval(-5)

        let first = usage(
            at: parentFirst, input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        let duplicate = usage(
            at: parentFirst.addingTimeInterval(1), input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        let second = usage(
            at: parentSecond, input: 60, cached: 40, output: 20, total: 80,
            cumulativeInput: 160, cumulativeCached: 100, cumulativeOutput: 40, cumulativeTotal: 200
        )
        let parent = [
            metadata(id: parentId, at: parentFirst.addingTimeInterval(-1)),
            turn(model: "gpt-5.6-sol"), first, duplicate, second,
        ].joined(separator: "\n") + "\n"
        try write(parent, to: directory.appendingPathComponent(
            "rollout-2026-08-23T12-00-00-\(parentId).jsonl"
        ))

        // Codex rewrites inherited events to the child's start time. Usage tuples and
        // cumulative snapshots still match the parent and must be filtered as replay.
        let childFirst = usage(
            at: fork, input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        let childDuplicate = usage(
            at: fork.addingTimeInterval(0.1), input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        let childSecond = usage(
            at: fork.addingTimeInterval(0.2), input: 60, cached: 40, output: 20, total: 80,
            cumulativeInput: 160, cumulativeCached: 100, cumulativeOutput: 40, cumulativeTotal: 200
        )
        let own = usage(
            at: childOwn, input: 40, cached: 10, output: 10, total: 50,
            cumulativeInput: 200, cumulativeCached: 110, cumulativeOutput: 50, cumulativeTotal: 250
        )
        let child = [
            metadata(id: childId, parent: parentId, at: fork),
            turn(model: "gpt-5.6-sol"), settings(tier: "default"),
            childFirst, childDuplicate, childSecond, own,
        ].joined(separator: "\n") + "\n"
        try write(child, to: directory.appendingPathComponent(
            "rollout-2026-08-23T12-01-00-\(childId).jsonl"
        ))

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        let result = service.todayUsage()
        XCTAssertEqual(result.tokens, 140) // parent 60 + 40; child own 40
        XCTAssertEqual(result.messages, 3)
        XCTAssertEqual(result.cacheRate, 110.0 / 250.0, accuracy: 0.000_001)
        XCTAssertEqual(service.todayCost().value, 0.002808, accuracy: 0.000_000_1)

        service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens, 140)
        XCTAssertEqual(service.todayUsage().messages, 3)
    }

    func testLegacyRewrittenReplayBurstIsSkippedWhenUsageTuplesDoNotMatch() throws {
        let home = try makeRoot()
        let directory = home.appendingPathComponent("sessions/current", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parentId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let childId = "ffffffff-1111-2222-3333-444444444444"
        let now = Date()
        let parentEvent = usage(
            at: now.addingTimeInterval(-20), input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        try write([
            metadata(id: parentId, at: now.addingTimeInterval(-21)),
            turn(model: "gpt-5.6-sol"), parentEvent,
        ].joined(separator: "\n") + "\n", to: directory.appendingPathComponent(
            "rollout-2026-08-23T12-00-00-\(parentId).jsonl"
        ))

        let fork = now.addingTimeInterval(-10)
        let rewrittenOne = usage(
            at: fork, input: 90, cached: 50, output: 20, total: 110,
            cumulativeInput: 90, cumulativeCached: 50, cumulativeOutput: 20, cumulativeTotal: 110
        )
        let rewrittenTwo = usage(
            at: fork.addingTimeInterval(0.2), input: 70, cached: 30, output: 20, total: 90,
            cumulativeInput: 160, cumulativeCached: 80, cumulativeOutput: 40, cumulativeTotal: 200
        )
        let own = usage(
            at: fork.addingTimeInterval(5), input: 40, cached: 10, output: 10, total: 50,
            cumulativeInput: 200, cumulativeCached: 90, cumulativeOutput: 50, cumulativeTotal: 250
        )
        try write([
            metadata(id: childId, parent: parentId, at: fork),
            turn(model: "gpt-5.6-sol"), rewrittenOne, rewrittenTwo, own,
        ].joined(separator: "\n") + "\n", to: directory.appendingPathComponent(
            "rollout-2026-08-23T12-01-00-\(childId).jsonl"
        ))

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        XCTAssertEqual(service.todayUsage().tokens, 100) // parent 60 + child own 40
        XCTAssertEqual(service.todayUsage().messages, 2)
        XCTAssertEqual(service.todayUsage().cacheRate, 70.0 / 170.0, accuracy: 0.000_001)
    }

    func testCodexRequestCostUsesRecordedPriorityAndLongContextTier() throws {
        let model = "codex-request-priced-test"
        PricingService.shared.setCustomPrice(
            model: model,
            price: ModelPrice(
                input: 4, output: 20, cacheRead: 0.4,
                longContextThreshold: 272_000,
                longInput: 8, longOutput: 30, longCacheRead: 0.8,
                priorityMultiplier: 2
            )
        )
        defer { PricingService.shared.setCustomPrice(model: model, price: nil) }
        let home = try makeRoot()
        let directory = home.appendingPathComponent("sessions/current", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "12345678-1111-2222-3333-444444444444"
        let now = Date()
        let event = usage(
            at: now, input: 273_000, cached: 200_000, output: 1_000, total: 274_000,
            cumulativeInput: 273_000, cumulativeCached: 200_000,
            cumulativeOutput: 1_000, cumulativeTotal: 274_000
        )
        let settings = json([
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["model": model, "service_tier": "priority"],
            ],
        ])
        try write([
            metadata(id: id, at: now.addingTimeInterval(-1)),
            turn(model: model), settings, event,
        ].joined(separator: "\n") + "\n", to: directory.appendingPathComponent(
            "rollout-2026-08-23T12-00-00-\(id).jsonl"
        ))

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        let freshInputCost: Double = 73_000 * 8.0
        let outputCost: Double = 1_000 * 30.0
        let cacheReadCost: Double = 200_000 * 0.8
        let expected = (freshInputCost + outputCost + cacheReadCost) / 1_000_000 * 2
        XCTAssertEqual(service.todayCost().value, expected, accuracy: 0.000_000_1)
    }

    func testResumedRolloutSharingSessionMetaIdDoesNotTrapAndCountsBothFiles() throws {
        // Codex resume keeps the original session_meta id in a new rollout filename.
        // Both descriptors must be processed without a duplicate-key trap.
        let home = try makeRoot()
        let directory = home.appendingPathComponent("sessions/2026/08/27", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionId = "01a02c64-4be9-7251-8dd1-cef7bfc9ce44"
        let resumeId = "01a04347-af92-7751-87ca-517ea9edda0d"
        let now = Date()

        let original = usage(
            at: now.addingTimeInterval(-30), input: 100, cached: 60, output: 20, total: 120,
            cumulativeInput: 100, cumulativeCached: 60, cumulativeOutput: 20, cumulativeTotal: 120
        )
        try write([
            metadata(id: sessionId, at: now.addingTimeInterval(-31)),
            turn(model: "gpt-5.6-sol"), original,
        ].joined(separator: "\n") + "\n", to: directory.appendingPathComponent(
            "rollout-2026-08-22T19-12-45-\(sessionId).jsonl"
        ))

        let resumedOwn = usage(
            at: now.addingTimeInterval(-5), input: 40, cached: 10, output: 10, total: 50,
            cumulativeInput: 40, cumulativeCached: 10, cumulativeOutput: 10, cumulativeTotal: 50
        )
        try write([
            metadata(id: sessionId, at: now.addingTimeInterval(-6)),
            turn(model: "gpt-5.6-sol"), resumedOwn,
        ].joined(separator: "\n") + "\n", to: directory.appendingPathComponent(
            "rollout-2026-08-27T05-52-46-\(sessionId)_\(resumeId).jsonl"
        ))

        let service = CodexUsageService(codexHome: home.path)
        service.fullScan()
        XCTAssertEqual(service.todayUsage().tokens, 100)
        XCTAssertEqual(service.todayUsage().messages, 2)

        service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens, 100)
        XCTAssertEqual(service.todayUsage().messages, 2)
    }

    private func metadata(id: String, parent: String? = nil, at date: Date) -> String {
        var payload: [String: Any] = ["id": id]
        if let parent {
            payload["source"] = [
                "subagent": ["thread_spawn": ["parent_thread_id": parent, "depth": 1]],
            ]
        }
        return json(["type": "session_meta", "timestamp": iso(date), "payload": payload])
    }

    private func turn(model: String) -> String {
        json(["type": "turn_context", "payload": ["type": "turn_context", "model": model]])
    }

    private func settings(tier: String) -> String {
        json([
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": tier],
            ],
        ])
    }

    private func usage(
        at date: Date,
        input: Int, cached: Int, output: Int, total: Int,
        cumulativeInput: Int, cumulativeCached: Int, cumulativeOutput: Int, cumulativeTotal: Int
    ) -> String {
        json([
            "type": "event_msg",
            "timestamp": iso(date),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                        "reasoning_output_tokens": 0,
                        "total_tokens": total,
                    ],
                    "total_token_usage": [
                        "input_tokens": cumulativeInput,
                        "cached_input_tokens": cumulativeCached,
                        "output_tokens": cumulativeOutput,
                        "reasoning_output_tokens": 0,
                        "total_tokens": cumulativeTotal,
                    ],
                ],
            ],
        ])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClockCodexReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
}
