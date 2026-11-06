#if os(macOS)
import XCTest
@testable import TokenClock

final class StatusSummaryToolboxTests: XCTestCase {
    func testMergedActionsDoNotRepeatFooterToolsAndIncludeNews() {
        let actions = StatusSummaryToolboxAction.initialOrder(from: [.model,.network,.local,.quota,.history,.notebook,.share])
        XCTAssertEqual(actions.count,8)
        for item in StatusSummaryToolboxAction.allCases { XCTAssertEqual(actions.filter{$0==item}.count,1) }
        XCTAssertEqual(Array(actions.prefix(3)),[.model,.network,.local])
    }
    func testSavedOrderDropsDuplicatesAndUnknownsWithoutReaddingHiddenItems() {
        XCTAssertEqual(StatusSummaryToolboxAction.normalized(["news","history","unknown","news","share"]),[.news,.history,.share])
        XCTAssertTrue(StatusSummaryToolboxAction.normalized([]).isEmpty)
    }
}
#endif
