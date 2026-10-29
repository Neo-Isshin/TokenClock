import Foundation
import XCTest
@testable import TokenClock

final class StatusSummaryResponsiveTests: XCTestCase {
    func testQuotaCountsScaleRingSizeAndWrapWithoutHorizontalOverflow() {
        for side: CGFloat in [268, 320, 420, 480, 600] {
            let layout = StatusSummaryLayout(side: side)
            let available = side - 2 * layout.padding - 2 * layout.sectionPadding
            for count in 1...6 {
                let grid = layout.quotaGrid(count: count)
                XCTAssertGreaterThanOrEqual(grid.columns, 1)
                XCTAssertLessThanOrEqual(grid.columns, count)
                XCTAssertLessThanOrEqual(CGFloat(grid.columns) * grid.cardWidth + CGFloat(grid.columns - 1) * layout.spacing + 16, available + 0.001)
                XCTAssertGreaterThan(grid.ringSize, 0)
                XCTAssertLessThanOrEqual(grid.ringSize, grid.cardWidth - 12 + 0.001)
            }
        }
        let wide = StatusSummaryLayout(side: 600)
        XCTAssertGreaterThan(wide.quotaGrid(count: 1).ringSize, wide.quotaGrid(count: 4).ringSize)
        XCTAssertGreaterThan(wide.quotaGrid(count: 4).ringSize, wide.quotaGrid(count: 6).ringSize)
        XCTAssertGreaterThan(wide.quotaGrid(count: 4).ringSize, 48)
        XCTAssertEqual(wide.quotaGrid(count: 4).columns, 4)
        XCTAssertEqual(wide.quotaGrid(count: 6).columns, 3)
        XCTAssertLessThan(StatusSummaryLayout(side: 320).quotaGrid(count: 6).columns, 6)
    }

    func testPanelFitsUsableScreenBoundsIncludingOuterGlassPadding() {
        for size in [CGSize(width: 1_280, height: 672), CGSize(width: 1_440, height: 850),
                     CGSize(width: 1_920, height: 1_030), CGSize(width: 640, height: 450),
                     CGSize(width: 360, height: 360)] {
            let side = StatusSummaryLayout.panelSide(available: size)
            XCTAssertLessThanOrEqual(side, 600)
            XCTAssertLessThanOrEqual(side + 12, size.width - 40 + 0.001)
            XCTAssertLessThanOrEqual(side + 12, size.height - 80 + 0.001)
        }
        XCTAssertFalse(StatusSummaryLayout(side: 600).isCompact)
        XCTAssertTrue(StatusSummaryLayout(side: 420).isCompact)
        XCTAssertTrue(StatusSummaryLayout(side: 320).isCompact)
    }
}
