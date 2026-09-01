import XCTest
@testable import TokenClock

final class CursorAgentUsageServiceTests: XCTestCase {
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

    func testBareThinkingRouteSuffixUsesOfficialCursorModelName() {
        let service = CursorAgentUsageService()
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)

        service.applyEvents([
            event(timestamp: timestamp, model: "claude-fable-5-thinking", input: 100, output: 20),
        ], rangeDays: 30)

        XCTAssertEqual(
            CursorAgentUsageService.normalizeDashboardModel("claude-fable-5-thinking"),
            "claude-fable-5"
        )
        XCTAssertNotNil(service.todayModelBuckets()["claude-fable-5"])
        XCTAssertNil(service.todayModelBuckets()["claude-fable-5-thinking"])
        XCTAssertEqual(service.todaySessions().first?.model, "claude-fable-5")
        XCTAssertEqual(service.todaySessions().first?.displayName, "claude-fable-5")
        XCTAssertTrue(service.todayCost().complete)
        XCTAssertGreaterThan(service.todayCost().value, 0)
    }

    func testCursorRouteMarkerOrdersCollapseWithoutDamagingOfficialNames() {
        let aliases = [
            "claude-fable-5-medium",
            "claude-fable-5-thinking-medium",
            "claude-fable-5-medium-thinking",
            "claude-fable-5-thinking-xhigh",
            "claude-fable-5-thinking-max",
            "claude-fable-5-high-thinking-fast",
        ]
        for alias in aliases {
            XCTAssertEqual(CursorAgentUsageService.normalizeDashboardModel(alias), "claude-fable-5")
        }
        XCTAssertEqual(
            CursorAgentUsageService.normalizeDashboardModel("claude-opus-4-7-thinking-medium-fast"),
            "claude-opus-4-7"
        )
        XCTAssertEqual(
            CursorAgentUsageService.normalizeDashboardModel("claude-4.6-opus-max-thinking-fast"),
            "claude-4.6-opus"
        )
        XCTAssertEqual(
            CursorAgentUsageService.normalizeDashboardModel("claude-4-5-sonnet-20250929-thinking"),
            "claude-4-5-sonnet"
        )
        XCTAssertEqual(CursorAgentUsageService.normalizeDashboardModel("qwen3.8-max"), "qwen3.8-max")
        XCTAssertEqual(
            CursorAgentUsageService.normalizeDashboardModel("MiniMax-M2.7-highspeed"),
            "MiniMax-M2.7-highspeed"
        )
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
