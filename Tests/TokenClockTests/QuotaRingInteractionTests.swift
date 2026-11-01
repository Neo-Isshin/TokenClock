#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor
final class QuotaRingInteractionTests: XCTestCase {
    private final class Window: NSWindow {
        var ordinaryRightClicks = 0
        override func rightMouseDown(with event: NSEvent) { ordinaryRightClicks += 1 }
    }
    private func event(_ type: NSEvent.EventType, _ point: NSPoint, time: TimeInterval = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: time, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func testQuotaClicksAreRoutedWithoutStealingClockClicksContextMenuOrDragging() throws {
        var clockClicks = 0, nextPages = 0, quotaWindows = 0, drags = 0
        let window = Window(contentRect: NSRect(x: -10_000, y: -10_000, width: 240, height: 240),
                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ClockInteractionNSView(onClick: { clockClicks += 1 }, onDragStart: { drags += 1 },
            onQuotaClick: { nextPages += 1 }, onQuotaRightClick: { quotaWindows += 1 },
            tooltipRegions: [.init(rect: NSRect(x: 170, y: 100, width: 40, height: 40), text: "Codex")])
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 240); window.contentView = view
        defer { window.close() }
        let ring = NSPoint(x: 185, y: 120), face = NSPoint(x: 90, y: 80)
        view.mouseDown(with: try event(.leftMouseDown, ring))
        view.mouseUp(with: try event(.leftMouseUp, ring, time: 1.1))
        XCTAssertEqual(nextPages, 1); XCTAssertEqual(clockClicks, 0)
        view.rightMouseDown(with: try event(.rightMouseDown, ring))
        XCTAssertEqual(quotaWindows, 1); XCTAssertEqual(window.ordinaryRightClicks, 0)
        view.rightMouseDown(with: try event(.rightMouseDown, face))
        XCTAssertEqual(window.ordinaryRightClicks, 1)
        view.mouseDown(with: try event(.leftMouseDown, face))
        view.mouseUp(with: try event(.leftMouseUp, face, time: 1.1))
        XCTAssertEqual(clockClicks, 1)
        view.mouseDown(with: try event(.leftMouseDown, ring))
        view.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 200, y: 120), time: 1.1))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 200, y: 120), time: 1.2))
        XCTAssertEqual(drags, 1); XCTAssertEqual(nextPages, 1)
        view.onQuotaClick = nil // One group retains the existing clock-details click.
        view.mouseDown(with: try event(.leftMouseDown, ring))
        view.mouseUp(with: try event(.leftMouseUp, ring, time: 1.1))
        XCTAssertEqual(clockClicks, 2)
    }

    func testRingEdgeHitTestingUsesLocalCoordinatesInsideWiderWindow() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let view = ClockInteractionNSView(onClick: {}, onQuotaRightClick: {},
            tooltipRegions: [.init(rect: NSRect(x: 176, y: 100, width: 42, height: 40), text: "Codex")])
        view.frame = NSRect(x: 40, y: 0, width: 240, height: 240)
        container.addSubview(view)
        XCTAssertTrue(view.hitTest(NSPoint(x: 250, y: 120)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 41, y: 1)))
    }
}
#endif
