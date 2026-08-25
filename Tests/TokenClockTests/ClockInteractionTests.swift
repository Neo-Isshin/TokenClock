#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor
final class ClockInteractionTests: XCTestCase {
    func testSmallDetailPanelUsesMediumWidthWithoutChangingOtherSizes() {
        XCTAssertEqual(ClockSize.small.panelWidth, 280)
        XCTAssertEqual(ClockSize.small.detailPanelWidth, ClockSize.medium.panelWidth)
        XCTAssertEqual(ClockSize.medium.detailPanelWidth, ClockSize.medium.panelWidth)
        XCTAssertEqual(ClockSize.large.detailPanelWidth, ClockSize.large.panelWidth)
        XCTAssertEqual(ClockSize.extraLarge.detailPanelWidth, ClockSize.extraLarge.panelWidth)
    }

    func testDropdownPanelAppliesDetailWidthForEveryClockSize() {
        let key = SettingsKey.clockSize.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.setString(ClockSize.small.rawValue, for: .clockSize)
        let panel = DropdownPanel()
        XCTAssertEqual(panel.frame.width, ClockSize.medium.panelWidth)

        for size in ClockSize.allCases {
            UserDefaults.standard.setString(size.rawValue, for: .clockSize)
            panel.reposition(below: NSRect(x: 200, y: 500, width: size.panelWidth, height: size.diameter))
            XCTAssertEqual(panel.frame.width, size.detailPanelWidth)
        }
    }

    func testDefaultWindowPositionKeepsEverySizeInsideVisibleFrame() {
        let screen = NSRect(x: 0, y: 98, width: 3440, height: 1312)
        for size in ClockSize.allCases {
            let panel = NSSize(width: size.panelWidth, height: size.diameter)
            let origin = ViewModel.defaultWindowPosition(screenFrame: screen, panelSize: panel)
            let frame = NSRect(origin: origin, size: panel)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
        }
    }

    func testStationaryClickTogglesWithoutMovingWindow() throws {
        var clickCount = 0
        let (window, view) = makeWindow { clickCount += 1 }
        let origin = window.frame.origin

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 120, y: 120)))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 120, y: 120)))

        XCTAssertEqual(clickCount, 1)
        XCTAssertEqual(window.frame.origin, origin)
    }

    func testUnpairedMouseUpAfterNativeTrackingDoesNotToggleAgain() throws {
        var clickCount = 0
        let (_, view) = makeWindow { clickCount += 1 }

        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 120, y: 120)))

        XCTAssertEqual(clickCount, 0)
    }

    func testDragMovesWindowWithoutToggling() throws {
        var clickCount = 0
        var dragStartCount = 0
        let (window, view) = makeWindow(
            onClick: { clickCount += 1 },
            onDragStart: { dragStartCount += 1 }
        )

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 120, y: 120)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 170, y: 150)))
        // Once the window follows the pointer, the same screen point is back at the original
        // local coordinate in the moved window.
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 120, y: 120)))

        XCTAssertEqual(clickCount, 0)
        XCTAssertEqual(dragStartCount, 1)
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

    private func makeWindow(
        onClick: @escaping () -> Void,
        onDragStart: @escaping () -> Void = {}
    ) -> (NSWindow, ClockInteractionNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 240, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = ClockInteractionNSView(onClick: onClick, onDragStart: onDragStart)
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
