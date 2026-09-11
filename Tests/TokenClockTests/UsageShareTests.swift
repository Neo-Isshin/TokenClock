import XCTest
@testable import TokenClock

#if os(macOS)
import AppKit

final class UsageShareTests: XCTestCase {
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
        let image = try XCTUnwrap(UsageShareImageRenderer.image(for: data))
        let representation = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(representation.pixelsWide, 1_200)
        XCTAssertEqual(representation.pixelsHigh, 1_500)

        if let output = ProcessInfo.processInfo.environment["TOKENCLOCK_SHARE_PREVIEW_PATH"] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
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
