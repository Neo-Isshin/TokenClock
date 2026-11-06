import XCTest
@testable import TokenClock

final class QuotaCenterLabelTests: XCTestCase {
    func testDisplayedHundredUsesFAndOtherPercentagesKeepTheirFormat() {
        XCTAssertEqual(QuotaCenterLabel(remaining: 100), QuotaCenterLabel(remaining: 110))
        XCTAssertEqual(QuotaCenterLabel(remaining: 100).text, "F")
        XCTAssertFalse(QuotaCenterLabel(remaining: 100).showsPercent)
        XCTAssertEqual(QuotaCenterLabel(remaining: 99.99).text, "F")
        for value in [99.4, 95, 11, 0] {
            XCTAssertNotEqual(QuotaCenterLabel(remaining: value).text, "F")
            XCTAssertTrue(QuotaCenterLabel(remaining: value).showsPercent)
        }
        XCTAssertEqual(QuotaCenterLabel(remaining: 99.4).text, "99")
        XCTAssertEqual(QuotaCenterLabel(remaining: 0).text, "0")
    }

    func testUnknownQuotaIsNotMistakenForFullOrEmpty() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(QuotaCenterLabel(remaining: value).text, "—")
            XCTAssertFalse(QuotaCenterLabel(remaining: value).showsPercent)
        }
    }
}
