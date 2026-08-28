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
}
#endif
