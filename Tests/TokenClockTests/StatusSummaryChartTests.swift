import Foundation
import XCTest
@testable import TokenClock
#if os(macOS)
import AppKit
import SwiftUI
#endif

final class StatusSummaryChartTests: XCTestCase {
    private func day(_ key: String) -> StatusSummaryHourlyData {
        .init(day: key, hours: (0..<24).map {
            StatusSummaryHour(hour: $0, tokens: ($0 + 1) * 100, cacheReadTokens: $0 * 10,
                              hasRecords: true, cacheIsExact: $0 != 23)
        })
    }

    func testSixHourWindowCrossesMidnightWithoutLosingCacheOrDateIdentity() {
        let today = day("2026-11-01"), yesterday = day("2026-10-31")
        let result = today.chartHours(expanded: false, currentHour: 2, previous: yesterday)
        XCTAssertEqual(result.map(\.id), ["2026-10-31-21", "2026-10-31-22", "2026-10-31-23",
                                         "2026-11-01-00", "2026-11-01-01", "2026-11-01-02"])
        XCTAssertEqual(result[2].usage.displayedTokens(includingCache: true), 2_630)
        XCTAssertFalse(result[2].usage.cacheIsExact)
        XCTAssertEqual(today.hours.count, 24)
    }

    func testRecentWindowExcludesFutureHoursAndKeepsMissingHistoryUnrecorded() {
        let today = day("2026-11-01")
        let recent = today.chartHours(expanded: false, currentHour: 17, previous: day("2026-10-31"))
        XCTAssertEqual(recent.map { $0.usage.hour }, [12, 13, 14, 15, 16, 17])
        let midnight = today.chartHours(expanded: false, currentHour: 0, previous: day("2026-10-30"))
        XCTAssertTrue(midnight.prefix(5).allSatisfy { !$0.usage.hasRecords && $0.usage.tokens == 0 })
        XCTAssertEqual(midnight.last?.id, "2026-11-01-00")
        let expanded = today.chartHours(expanded: true, currentHour: 0, previous: day("2026-10-31"))
        XCTAssertEqual(expanded.map(\.usage), today.hours)
        XCTAssertTrue(expanded.allSatisfy { $0.day == today.day })
    }

    #if os(macOS)
    @MainActor
    func testHourlyChartCanExpandAndCollapseWithoutRemovingUsageRows() throws {
        _ = NSApplication.shared
        let dayKey = DateHelper.dateKey(from: Date())
        let names = ["Codex", "Claude Code", "Cursor Agent", "Grok Bot", "ZCode", "Gemini CLI"]
        let tools = names.enumerated().map { index, name in
            ToolUsage(name: name, abbreviation: "", emoji: "", todayTokens: (6 - index) * 10_000,
                todayMessages: (6 - index) * 10, isActive: false, recentTokens: 0, hourlyTokens: 0)
        }
        let quotas: [StatusSummaryQuota] = [SubscriptionProvider.codex, .antigravity, .cursor, .zhipu].map { provider in
            StatusSummaryQuota(indicator: DialQuotaIndicator(provider: provider, outerRemainingPercent: 83,
                innerRemainingPercent: 65, details: []), isShared: false,
                resets: [StatusSummaryQuotaReset(labelKey: "quota.dial.weekly", windowMinutes: 10_080,
                    resetsAt: Date().addingTimeInterval(86_400), source: "fixture")])
        }
        let view = StatusSummaryContent(snapshot: .init(tools: tools, includesCache: false), models: [],
            date: "Thursday, Oct 29", tokens: "210K", cost: "$12.30", hourly: day(dayKey),
            previousHourly: day(StatusSummaryComparisonData.previousDay(dayKey)!), quotas: quotas,
            onHistory: {}, onQuota: {}, onShare: {})
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 612, height: 612),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 612, height: 612)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func settle() {
            for _ in 0..<9 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        }
        func scrollers(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollers)
        }
        settle()
        let scroll = try XCTUnwrap(scrollers(host).filter { $0.hasVerticalScroller }
            .max { $0.contentView.bounds.height < $1.contentView.bounds.height })
        let document = try XCTUnwrap(scroll.documentView)
        let collapsedHeight = document.bounds.height
        let viewportHeight = scroll.contentView.bounds.height
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
        let point = host.convert(CGPoint(x: viewport.midX,
            y: host.isFlipped ? viewport.minY + 100 : viewport.maxY - 100), to: nil)
        func clickChart() throws {
            // Deliver native events to this offscreen fixture only, without
            // moving the user's pointer or sending events to another window.
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            settle()
        }
        try clickChart()
        XCTAssertGreaterThan(document.bounds.height, collapsedHeight + 20)
        XCTAssertEqual(scroll.contentView.bounds.height, viewportHeight, accuracy: 1)
        try clickChart()
        XCTAssertEqual(document.bounds.height, collapsedHeight, accuracy: 1)

    }
    #endif
}
