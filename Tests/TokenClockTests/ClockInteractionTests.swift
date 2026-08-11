#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor
final class ClockInteractionTests: XCTestCase {
    func testStationaryClickTogglesWithoutMovingWindow() throws {
        var clickCount = 0
        let (window, view) = makeWindow { clickCount += 1 }
        let origin = window.frame.origin

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 120, y: 120)))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 120, y: 120)))

        XCTAssertEqual(clickCount, 1)
        XCTAssertEqual(window.frame.origin, origin)
    }

    func testDragMovesWindowWithoutToggling() throws {
        var clickCount = 0
        let (window, view) = makeWindow { clickCount += 1 }

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 120, y: 120)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 170, y: 150)))
        // Once the window follows the pointer, the same screen point is back at the original
        // local coordinate in the moved window.
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 120, y: 120)))

        XCTAssertEqual(clickCount, 0)
        XCTAssertEqual(window.frame.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(window.frame.origin.y, 130, accuracy: 0.001)
    }

    func testCoalescedDownUpDragStillMovesWindow() throws {
        var clickCount = 0
        let (window, view) = makeWindow { clickCount += 1 }

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 120, y: 120)))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 170, y: 150)))

        XCTAssertEqual(clickCount, 0)
        XCTAssertEqual(window.frame.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(window.frame.origin.y, 130, accuracy: 0.001)
    }

    private func makeWindow(onClick: @escaping () -> Void) -> (NSWindow, ClockInteractionNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 240, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = ClockInteractionNSView(onClick: onClick)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        window.contentView = view
        return (window, view)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
#endif
