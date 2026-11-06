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

    func testHiddenClockIsTemporarilyRaisedAndNextDoubleClickHidesRegardlessOfCoverage() {
        var state = StatusBarVisibilityState()
        state.setHidden(true)
        XCTAssertTrue(state.shouldShowOnDoubleClick(windowVisible: false, coveredFraction: nil))
        state.showTemporarilyOnTop()
        XCTAssertFalse(state.isHidden)
        XCTAssertTrue(state.isTemporarilyOnTop)
        for coverage: Double? in [nil, 0, 0.9, 1] {
            XCTAssertFalse(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: coverage))
        }
        state.setHidden(true)
        XCTAssertFalse(state.isTemporarilyOnTop)
        XCTAssertTrue(state.shouldShowOnDoubleClick(windowVisible: false, coveredFraction: 1))
    }

    func testCoveredClockUsesTemporaryPhaseBeforeReturningToHidden() {
        var state = StatusBarVisibilityState()
        XCTAssertFalse(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: 0.84))
        XCTAssertTrue(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: 0.85))
        state.showTemporarilyOnTop()
        XCTAssertFalse(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: 1))
        state.setHidden(true)
        XCTAssertTrue(state.isHidden)
        XCTAssertFalse(state.isTemporarilyOnTop)
    }

    func testUnhideNotificationPreservesTemporaryPhaseButExternalHideClearsIt() {
        var state = StatusBarVisibilityState()
        state.showTemporarilyOnTop()
        state.setHidden(false)
        XCTAssertTrue(state.isTemporarilyOnTop)
        XCTAssertFalse(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: nil))
        state.setHidden(true)
        state.setHidden(false)
        XCTAssertFalse(state.isTemporarilyOnTop)
        XCTAssertFalse(state.shouldShowOnDoubleClick(windowVisible: true, coveredFraction: 0))
        state.showTemporarilyOnTop()
        XCTAssertTrue(state.shouldShowOnDoubleClick(windowVisible: false, coveredFraction: nil))
    }

    func testTemporaryLevelRestoresNormalWhenAlwaysOnTopIsOff() {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var state = StatusBarVisibilityState()
        state.apply(to: window, alwaysOnTop: false)
        XCTAssertEqual(window.level, .normal)
        state.showTemporarilyOnTop()
        state.apply(to: window, alwaysOnTop: false)
        XCTAssertEqual(window.level, .statusBar)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        state.setHidden(true)
        state.apply(to: window, alwaysOnTop: false)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.collectionBehavior.isEmpty)
    }

    func testTemporaryLevelPreservesPermanentOnTopAndUsesLatestPreference() {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var state = StatusBarVisibilityState()
        state.showTemporarilyOnTop()
        state.apply(to: window, alwaysOnTop: true)
        XCTAssertEqual(window.level, .statusBar)
        state.setHidden(true)
        state.apply(to: window, alwaysOnTop: true)
        XCTAssertEqual(window.level, .statusBar)
        state.showTemporarilyOnTop()
        state.apply(to: window, alwaysOnTop: false)
        XCTAssertEqual(window.level, .statusBar)
        state.setHidden(true)
        state.apply(to: window, alwaysOnTop: false)
        XCTAssertEqual(window.level, .normal)
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

    func testMouseDownActionRetainsNativeDoubleClickCount() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0, doubles = 0
        clicks.click(event: try event(.leftMouseDown, count: 1, time: 100), single: { summaries += 1 }, double: { doubles += 1 })
        clicks.click(event: try event(.leftMouseDown, count: 2, time: 100.02), single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(doubles, 1)
        XCTAssertEqual(summaries, 0)
    }

    func testMenuBarCounterRestartsStillRecognizeTwoDoubleClicks() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0, doubles = 0
        for index in 0..<4 {
            clicks.click(event: try event(.leftMouseUp, count: 1, time: 100 + Double(index) * 0.01),
                single: { summaries += 1 }, double: { doubles += 1 })
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(doubles, 2)
        XCTAssertEqual(summaries, 0)
    }

    func testSeparatedClicksAndMovedPointerDoNotBecomeDoubleClicks() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0, doubles = 0
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 100), single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 100.2), single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(summaries, 2)
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 101), single: { summaries += 1 }, double: { doubles += 1 })
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 101.02, point: NSPoint(x: 30, y: 30)), single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(doubles, 0)
    }

    func testContextMenuCancellationAlsoClearsPhysicalClickPair() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0, doubles = 0
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 100), single: { summaries += 1 }, double: { doubles += 1 })
        clicks.cancel()
        clicks.click(event: try event(.leftMouseUp, count: 1, time: 100.02), single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(doubles, 0)
        XCTAssertEqual(summaries, 1)
    }

    func testRelayedCallbacksWithoutCurrentMouseEventStillRecognizeDoubleClick() async throws {
        let clicks = StatusBarClickCoordinator(interval: 0.04)
        var summaries = 0, doubles = 0
        clicks.click(event: nil, single: { summaries += 1 }, double: { doubles += 1 })
        clicks.click(event: nil, single: { summaries += 1 }, double: { doubles += 1 })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(doubles, 1)
        XCTAssertEqual(summaries, 0)
    }

    private func event(_ type: NSEvent.EventType, count: Int, time: TimeInterval,
                       point: NSPoint = NSPoint(x: 5, y: 5)) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
    }
}
#endif
