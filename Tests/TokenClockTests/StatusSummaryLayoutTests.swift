#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

@MainActor
final class StatusSummaryLayoutTests: XCTestCase {
    func testLargeQuotaSectionAndUsageRowsShareANonzeroScrollableViewport() throws {
        _ = NSApplication.shared
        let tools = (1...8).map { index in
            ToolUsage(name: "Harness \(index)", abbreviation: "H", emoji: "", todayTokens: index * 1_000,
                todayMessages: index, isActive: false, recentTokens: 0, hourlyTokens: 0)
        }
        let quotas = SubscriptionProvider.allCases.map { provider in
            StatusSummaryQuota(indicator: DialQuotaIndicator(provider: provider, outerRemainingPercent: 95,
                innerRemainingPercent: 80, thirdRemainingPercent: 20, details: []), isShared: false,
                resets: (0..<5).map { index in
                    StatusSummaryQuotaReset(labelKey: "quota.dial.weekly", windowMinutes: 10_080,
                        resetsAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 3_600)), source: "fixture")
                })
        }
        func content(_ values: [ToolUsage]) -> StatusSummaryContent {
            StatusSummaryContent(snapshot: StatusSummarySnapshot(tools: values, includesCache: false),
                models: [], date: "Oct 28", tokens: "36K", cost: "$3.60", quotas: quotas,
                onHistory: {}, onQuota: {}, onShare: {})
        }
        let host = NSHostingView(rootView: content(Array(tools.prefix(1))))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 612, height: 612),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 612, height: 612)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func settle() {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
        }
        func scrollers(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollers)
        }
        settle()
        let all = scrollers(host)
        let vertical = all.filter { $0.hasVerticalScroller }.max { $0.contentView.bounds.height < $1.contentView.bounds.height }
        let body = try XCTUnwrap(vertical, "The main summary must expose a native vertical scroll viewport")
        XCTAssertGreaterThan(body.contentView.bounds.height, 100, "Quota details must not squeeze the list viewport to zero")
        XCTAssertGreaterThan(try XCTUnwrap(body.documentView).bounds.height, body.contentView.bounds.height,
            "All quota details and usage rows must remain reachable by scrolling")
        let previousHeight = try XCTUnwrap(body.documentView).bounds.height
        host.rootView = content(tools)
        settle()
        let updated = try XCTUnwrap(scrollers(host).filter { $0.hasVerticalScroller }
            .max { $0.contentView.bounds.height < $1.contentView.bounds.height })
        XCTAssertGreaterThan(try XCTUnwrap(updated.documentView).bounds.height, previousHeight + 70,
            "Additional harness rows must contribute real content height instead of disappearing")
    }
}
#endif
