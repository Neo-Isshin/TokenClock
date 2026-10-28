#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor
final class StatusBarIconTests: XCTestCase {
    func testStatusBarIconIsTemplateImageAtMenuBarSize() {
        let image = StatusBarIcon.makeImage(size: 18)

        XCTAssertEqual(image.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.001)
        XCTAssertTrue(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testVisibilityStateTogglesBetweenHiddenAndVisible() {
        var state = StatusBarVisibilityState()
        XCTAssertFalse(state.isHidden)

        XCTAssertTrue(state.toggle())
        XCTAssertTrue(state.isHidden)

        XCTAssertFalse(state.toggle())
        XCTAssertFalse(state.isHidden)
    }

    func testVisibilityStateCanSynchronizeWithAppKitNotifications() {
        var state = StatusBarVisibilityState()
        state.setHidden(true)
        XCTAssertTrue(state.isHidden)

        state.setHidden(false)
        XCTAssertFalse(state.isHidden)
    }

    func testSingleClickWaitsForSystemDoubleClickDecision() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var singleCount = 0
        clicks.click(count: 1, single: { singleCount += 1 }, double: { XCTFail("Not a double click") })
        XCTAssertEqual(singleCount, 0)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(singleCount, 1)
        clicks.cancel()
    }

    func testDoubleClicksToggleVisibilityWithoutOpeningSummary() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var state = StatusBarVisibilityState()
        state.setHidden(true)
        var summaries = 0
        clicks.click(count: 1, single: { summaries += 1 }, double: { state.toggle() })
        clicks.click(count: 2, single: { summaries += 1 }, double: { state.toggle() })
        XCTAssertFalse(state.isHidden)
        clicks.click(count: 3, single: { summaries += 1 }, double: { state.toggle() })
        clicks.click(count: 4, single: { summaries += 1 }, double: { state.toggle() })
        XCTAssertTrue(state.isHidden)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(summaries, 0)
    }

    func testRightMenuCancellationPreventsLateSummary() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0
        clicks.click(count: 1, single: { summaries += 1 }, double: {})
        clicks.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(summaries, 0)
    }
}
#endif
