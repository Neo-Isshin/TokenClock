import XCTest
@testable import TokenClock

final class CursorAgentUsageServiceTests: XCTestCase {
    func testGrokBotHasItsOwnDisplayTool() {
        let names = MockUsageService.generateInitialData().map(\.name)
        XCTAssertTrue(names.contains("Grok"))
        XCTAssertTrue(names.contains("Grok Bot"))
        XCTAssertNotEqual(names.firstIndex(of: "Grok"), names.firstIndex(of: "Grok Bot"))
    }

    func testDashboardEventsPreserveModelsAndTokenBuckets() {
        let service = CursorAgentUsageService()
        let now = Date()
        let timestamp = Int(now.timeIntervalSince1970 * 1_000)
        let sonnet = "cursor-test-sonnet-medium"
        let opus = "cursor-test-opus-high"
        let sonnetPrice = ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)
        let opusPrice = ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        PricingService.shared.setCustomPrice(model: "cursor-test-sonnet", price: sonnetPrice)
        PricingService.shared.setCustomPrice(model: "cursor-test-opus", price: opusPrice)
        defer {
            PricingService.shared.setCustomPrice(model: "cursor-test-sonnet", price: nil)
            PricingService.shared.setCustomPrice(model: "cursor-test-opus", price: nil)
        }

        service.applyEvents([
            event(timestamp: String(timestamp), model: sonnet, input: 100, output: 20, cacheRead: 300, cacheWrite: 40),
            event(timestamp: timestamp, model: sonnet, input: 10, output: 2, cacheRead: 30, cacheWrite: 4),
            event(timestamp: Double(timestamp), model: opus, input: 50, output: 8, cacheRead: 70, cacheWrite: 6),
        ], rangeDays: 30)

        let usage = service.todayUsage()
        // Cursor 的四个字段彼此独立；主口径排除 cache read，包含 cache write。
        XCTAssertEqual(usage.tokens, 240)
        XCTAssertEqual(usage.messages, 3)
        XCTAssertEqual(service.todayCacheReadTokens(), 400)
        XCTAssertEqual(usage.cacheRate, 400.0 / 640.0, accuracy: 0.000_001)

        let buckets = service.todayModelBuckets()
        XCTAssertEqual(buckets["cursor-test-sonnet"]?.input, 110)
        XCTAssertEqual(buckets["cursor-test-sonnet"]?.output, 22)
        XCTAssertEqual(buckets["cursor-test-sonnet"]?.cacheRead, 330)
        XCTAssertEqual(buckets["cursor-test-sonnet"]?.cacheWrite, 44)
        XCTAssertEqual(buckets["cursor-test-opus"]?.input, 50)

        let sessions = service.todaySessions()
        XCTAssertEqual(sessions.map(\.model).compactMap { $0 }.sorted(), ["cursor-test-opus", "cursor-test-sonnet"])
        XCTAssertEqual(sessions.first(where: { $0.model == "cursor-test-sonnet" })?.todayTokens, 176)
        XCTAssertEqual(sessions.first(where: { $0.model == "cursor-test-sonnet" })?.cacheReadTokens, 330)
        XCTAssertTrue(service.todayCost().complete)
        XCTAssertGreaterThan(service.todayCost().value, 0)
    }

    func testIncrementalWindowReplacesRatherThanDuplicatesModels() {
        let service = CursorAgentUsageService()
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let first = event(timestamp: timestamp, model: "cursor-replace-medium", input: 100, output: 10)
        let replacement = event(timestamp: timestamp, model: "cursor-replace-medium", input: 7, output: 3)

        service.applyEvents([first], rangeDays: 2)
        service.applyEvents([replacement], rangeDays: 2)

        XCTAssertEqual(service.todayUsage().tokens, 10)
        XCTAssertEqual(service.todaySessions().first?.todayTokens, 10)
        XCTAssertEqual(service.todayModelBuckets()["cursor-replace"]?.input, 7)
    }

    func testGrokBotModelsAreSeparatedFromDirectCursorUsage() {
        let service = CursorAgentUsageService()
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        service.applyEvents([
            event(timestamp: timestamp, model: "cursor-direct", input: 100, output: 20, cacheRead: 300),
            event(timestamp: timestamp, model: "grok-bot-default", input: 400, output: 50, cacheRead: 900),
            event(timestamp: timestamp, model: "grok-bot-automation", input: 70, output: 10, cacheRead: 120),
            event(timestamp: timestamp, model: "grok-4-fast", input: 30, output: 5, cacheRead: 15),
        ], rangeDays: 30)

        XCTAssertEqual(service.todayUsage().tokens, 155)
        XCTAssertEqual(service.todayUsage().messages, 2)
        XCTAssertEqual(service.todayCacheReadTokens(), 315)
        XCTAssertEqual(service.todayGrokBotUsage().tokens, 530)
        XCTAssertEqual(service.todayGrokBotUsage().messages, 2)
        XCTAssertEqual(service.todayGrokBotCacheReadTokens(), 1_020)
        XCTAssertEqual(
            service.todayGrokBotSessions().map(\.displayName).sorted(),
            ["grok-bot-automation", "grok-bot-default"]
        )
        XCTAssertTrue(service.todayGrokBotSessions().allSatisfy { $0.source == "Cursor" })
        XCTAssertTrue(CursorAgentUsageService.isGrokBotDashboardModel(" GROK-BOT-CUA "))
        XCTAssertFalse(CursorAgentUsageService.isGrokBotDashboardModel("grok-4-fast"))
    }

    func testCursorDashboardAliasesCollapseWithoutDamagingCursorModels() {
        let aliases: [(raw: String, expected: String)] = [
            ("claude-fable-5-thinking-medium", "claude-fable-5"),
            ("cursor-chatgpt-high", "chatgpt"),
            ("cursor-gpt-5.6-sol-high-fast", "gpt-5.6-sol"),
            ("cursor-claude-opus-5-thinking-medium", "claude-opus-5"),
            ("cursor-gemini-3.7-flash-high", "gemini-3.7-flash"),
            ("cursor-grok-4.6-high-fast", "grok-4.6"),
            ("cursor-qwen3.8-max", "qwen3.8-max"),
            ("cursor-MiniMax-M2.7-highspeed", "MiniMax-M2.7-highspeed"),
            ("cursor-composer-2.5-fast", "composer-2.5"),
        ]
        for alias in aliases {
            XCTAssertEqual(CursorAgentUsageService.normalizeDashboardModel(alias.raw), alias.expected)
        }
        XCTAssertEqual(CursorAgentUsageService.normalizeDashboardModel("cursor-small"), "cursor-small")
        XCTAssertEqual(CursorAgentUsageService.normalizeDashboardModel("cursor-auto-fast"), "cursor-auto")
        XCTAssertTrue(CursorAgentUsageService.isGrokBotDashboardModel("cursor-grok-bot-default"))
    }

    private func event(
        timestamp: Any,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> [String: Any] {
        [
            "timestamp": timestamp,
            "model": model,
            "conversationId": UUID().uuidString,
            "tokenUsage": [
                "inputTokens": input,
                "outputTokens": output,
                "cacheReadTokens": cacheRead,
                "cacheWriteTokens": cacheWrite,
            ],
        ]
    }
}
