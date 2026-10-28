import AppKit
import XCTest
@testable import TokenClock

final class StatusSummaryTests: XCTestCase {
    private func tool(_ name: String, tokens: Int, cache: Int = 0, messages: Int = 1) -> ToolUsage {
        var value = ToolUsage(name: name, abbreviation: name, emoji: "", todayTokens: tokens,
                              todayMessages: messages, isActive: false, recentTokens: 0, hourlyTokens: 0)
        value.todayCacheReadTokens = cache
        return value
    }

    func testSummaryUsesDialCacheBasisForTotalsAndRanking() {
        let tools = [tool("Codex", tokens: 100, cache: 900), tool("ZCode", tokens: 400)]
        let excluding = StatusSummarySnapshot(tools: tools, includesCache: false)
        XCTAssertEqual(excluding.totalTokens, 500)
        XCTAssertEqual(excluding.rankedTools.map(\.name), ["ZCode", "Codex"])
        let including = StatusSummarySnapshot(tools: tools, includesCache: true)
        XCTAssertEqual(including.totalTokens, 1_400)
        XCTAssertEqual(including.rankedTools.map(\.name), ["Codex", "ZCode"])
        XCTAssertEqual(including.totalMessages, 2)
        XCTAssertEqual(including.rankedTools.reduce(0) { $0 + including.tokens(for: $1) }, including.totalTokens)
        let cacheOnly = StatusSummarySnapshot(tools: [tool("Cache", tokens: 0, cache: 100, messages: 0)], includesCache: true)
        XCTAssertEqual(cacheOnly.rankedTools.count, 1)
        XCTAssertEqual(cacheOnly.totalTokens, 100)
    }

    func testCreditsAndOtherPeriodsCannotAppearAsTodayTokens() {
        var credit = tool("Credits", tokens: 10_000, messages: 50)
        credit.measurementUnit = .credits
        var lifetime = tool("Lifetime", tokens: 20_000, messages: 100)
        lifetime.measurementScope = .lifetime
        let summary = StatusSummarySnapshot(tools: [credit, lifetime, tool("Codex", tokens: 100)], includesCache: true)
        XCTAssertEqual(summary.totalTokens, 100)
        XCTAssertEqual(summary.totalMessages, 1)
        XCTAssertEqual(summary.rankedTools.map(\.name), ["Codex"])
    }

    func testEmptyAndMessageOnlySnapshots() {
        let empty = StatusSummarySnapshot(tools: [tool("Idle", tokens: 0, messages: 0)], includesCache: false)
        XCTAssertTrue(empty.rankedTools.isEmpty)
        let message = StatusSummarySnapshot(tools: [tool("Codex", tokens: 0, messages: 3)], includesCache: false)
        XCTAssertEqual(message.rankedTools.count, 1)
        XCTAssertEqual(message.totalTokens, 0)
        XCTAssertEqual(message.totalMessages, 3)
    }

    @MainActor
    func testOpeningSummaryKeepsClockHiddenAndRestoresOnlyPreviouslyVisibleWindows() {
        _ = NSApplication.shared
        let clock = window(), hiddenSettings = window(), status = window()
        defer { [clock, hiddenSettings, status].forEach { $0.orderOut(nil) } }
        clock.orderFront(nil)
        status.orderFront(nil)
        let visibility = StatusSummaryHiddenWindows()
        visibility.hide([clock, hiddenSettings, status], excluding: status)
        XCTAssertFalse(clock.isVisible)
        XCTAssertFalse(hiddenSettings.isVisible)
        XCTAssertTrue(status.isVisible)
        // Reopening the summary while the clock is hidden must preserve its restore list.
        visibility.hide([clock, hiddenSettings, status], excluding: status)
        visibility.restore()
        XCTAssertTrue(clock.isVisible)
        XCTAssertFalse(hiddenSettings.isVisible)
        clock.orderOut(nil)
        visibility.restore()
        XCTAssertFalse(clock.isVisible)
    }

    @MainActor
    func testHiddenWindowTrackingDoesNotRetainClosedWindows() {
        _ = NSApplication.shared
        let visibility = StatusSummaryHiddenWindows()
        weak var reference: NSWindow?
        autoreleasepool {
            let temporary = window()
            temporary.isReleasedWhenClosed = false
            reference = temporary
            temporary.orderFront(nil)
            visibility.hide([temporary], excluding: nil)
            temporary.close()
        }
        XCTAssertNil(reference)
        visibility.restore()
    }

    @MainActor
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                 styleMask: .borderless, backing: .buffered, defer: false)
    }
}
