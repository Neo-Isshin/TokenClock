import XCTest
@testable import TokenClock

#if os(macOS)
import AppKit
import SwiftUI

final class UsageShareTests: XCTestCase {
    func testRecentDaysAndNaturalMonthWeeksHaveExactBounds() {
        let september = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let recent = UsageSharePeriod.recent(days: 7, ending: september).bounds
        XCTAssertEqual(DateHelper.dateKey(from: recent.start), "2026-09-05")
        XCTAssertEqual(DateHelper.dateKey(from: recent.end), "2026-09-11")

        let week = UsageSharePeriod.weekOfMonth(containing: september, index: 2).bounds
        XCTAssertEqual(DateHelper.dateKey(from: week.start), "2026-09-07")
        XCTAssertEqual(DateHelper.dateKey(from: week.end), "2026-09-13")

        let february = Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 12))!
        let month = UsageSharePeriod.month(containing: february).bounds
        XCTAssertEqual(DateHelper.dateKey(from: month.start), "2024-02-01")
        XCTAssertEqual(DateHelper.dateKey(from: month.end), "2024-02-29")
    }

    func testShareDataKeepsSixLargestToolsAndAggregatesTheRest() {
        let overview = makeOverview()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!

        let data = UsageShareBuilder.make(date: date, overview: overview)

        XCTAssertEqual(data.totalTokens, 3_600)
        XCTAssertEqual(data.rows.count, 7)
        XCTAssertEqual(data.rows.prefix(6).map(\.name), ["Codex", "Claude Code", "Cursor Agent", "Grok Bot", "Gemini CLI", "OpenClaw"])
        XCTAssertEqual(data.rows.last?.tokens, 300)
        XCTAssertEqual(data.rows.last?.name, L10n.shared.tr("share.otherTools"))
        XCTAssertEqual(data.rows.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.000_001)
        XCTAssertEqual(data.quoteKey, UsageShareBuilder.make(date: date, overview: overview).quoteKey)
    }

    @MainActor
    func testShareCardRendersToExpectedPNGSize() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let data = UsageShareBuilder.make(date: date, overview: makeOverview())
        for style in UsageShareStyle.allCases {
            let image = try XCTUnwrap(UsageShareImageRenderer.image(for: data, style: style))
            let representation = try XCTUnwrap(image.representations.first)
            XCTAssertEqual(representation.pixelsWide, 1_200)
            XCTAssertEqual(representation.pixelsHigh, 1_500)

            if let directory = ProcessInfo.processInfo.environment["TOKENCLOCK_SHARE_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("share-\(style.rawValue).png"), options: .atomic)
            }
        }
    }

    @MainActor
    func testShareChooserRendersAllControlsWithoutClipping() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let size = NSSize(width: 470, height: 680)
        let view = NSHostingView(rootView: UsageShareWindowView(initialDate: date, onDone: {}))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 940, pixelsHigh: 1_360,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, 940)
        XCTAssertEqual(bitmap.pixelsHigh, 1_360)
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_SHARE_CHOOSER_PREVIEW_PATH"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func makeOverview() -> UsageOverviewData {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let values: [(String, String, Int)] = [
            ("Codex", "⚛️", 800), ("Claude Code", "✳️", 700),
            ("Cursor Agent", "💎", 600), ("Grok Bot", "😶", 500),
            ("Gemini CLI", "❇️", 400), ("OpenClaw", "🦞", 300),
            ("Qwen Code", "♻️", 200), ("Antigravity", "🔃", 100),
        ]
        let rows = values.map { name, emoji, tokens in
            UsageOverviewRow(
                name: name, emoji: emoji,
                metrics: UsageOverviewMetrics(
                    tokens: tokens, messages: max(1, tokens / 25), cacheReadTokens: tokens / 2,
                    cost: .unavailable, cacheIsExact: true
                )
            )
        }
        let summary = UsageOverviewMetrics(
            tokens: 3_600, messages: 144, cacheReadTokens: 1_800,
            cost: .unavailable, cacheIsExact: true
        )
        return UsageOverviewData(
            startDate: start, endDate: start, summary: summary,
            days: [UsageOverviewDay(dateKey: "2026-09-11", metrics: summary, rows: rows)],
            rows: rows, containsLegacyCacheEstimate: false,
            containsUnavailableCost: true, containsUnknownModel: false
        )
    }
}
#endif
