import Foundation
import XCTest
@testable import TokenClock

final class DialQuotaPagerTests: XCTestCase {
    func testFourSelectionsRotateInTwoNonoverlappingGroups() {
        XCTAssertEqual(DialQuotaPager.maximumSelection, 4)
        XCTAssertEqual(DialQuotaPager.interval, 60)
        var pager = DialQuotaPager()
        XCTAssertEqual(pager.visible(from: [1, 2, 3, 4]), [1, 2])
        pager.advance(count: 4)
        XCTAssertEqual(pager.visible(from: [1, 2, 3, 4]), [3, 4])
        pager.advance(count: 4)
        XCTAssertEqual(pager.visible(from: [1, 2, 3, 4]), [1, 2])
    }

    func testOddCountUsesSingleLastRingAndMissingIndicatorsCannotMakeAnEmptyPage() {
        var pager = DialQuotaPager()
        pager.advance(count: 3)
        XCTAssertEqual(pager.visible(from: ["a", "b", "c"]), ["c"])
        XCTAssertEqual(pager.visible(from: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(pager.visible(from: ["a"]), ["a"])
        XCTAssertEqual(pager.visible(from: [Int]()), [])
        pager.advance(count: 3)
        XCTAssertEqual(pager.visible(from: ["a", "b", "c"]), ["a", "b"])
        XCTAssertEqual(DialQuotaPager().visible(from: [1, 2, 3, 4]), [1, 2])
    }
}
