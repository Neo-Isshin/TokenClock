#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor final class FloatingPanelResizeTests: XCTestCase {
    private func clockFrame() throws -> NSRect {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        return NSRect(x:screen.visibleFrame.midX-120,y:screen.visibleFrame.maxY-220,width:240,height:200)
    }
    func testDropdownRetainsWidthThroughHeightDragRepositionAndReopening() throws {
        let clock = try clockFrame(), panel = DropdownPanel()
        panel.alphaValue=0;panel.isReleasedWhenClosed=false
        defer {panel.orderOut(nil);panel.close()}
        panel.show(below:clock,activeToolCount:2,showsWeather:true)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        let width=min(panel.maxSize.width,panel.frame.width+100)
        panel.setFrame(NSRect(x:panel.frame.minX,y:panel.frame.minY,width:width,height:panel.frame.height),display:false)
        panel.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:panel))
        panel.beginResize();panel.updateResize(deltaY:30);panel.endResize()
        XCTAssertEqual(panel.frame.width,width,accuracy:0.01)
        panel.reposition(below:clock.offsetBy(dx:10,dy:0))
        XCTAssertEqual(panel.frame.width,width,accuracy:0.01)
        panel.hide();panel.show(below:clock,activeToolCount:2,showsWeather:true)
        XCTAssertEqual(panel.frame.width,width,accuracy:0.01)
        panel.ensureHeight(panel.frame.height+20)
        XCTAssertEqual(panel.frame.width,width,accuracy:0.01)
    }
    func testNotificationRetainsBothDimensionsAndStaysOnScreen() throws {
        let clock=try clockFrame(),panel=NotificationPanel()
        panel.alphaValue=0;panel.isReleasedWhenClosed=false
        defer {panel.orderOut(nil);panel.close()}
        panel.show(near:clock)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        let size=NSSize(width:min(panel.maxSize.width,420),height:min(panel.maxSize.height,400))
        panel.setFrame(NSRect(origin:panel.frame.origin,size:size),display:false)
        panel.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:panel))
        panel.hide();panel.show(near:clock)
        XCTAssertEqual(panel.frame.width,size.width,accuracy:0.01)
        XCTAssertEqual(panel.frame.height,size.height,accuracy:0.01)
        let visible=try XCTUnwrap(panel.screen ?? NSScreen.main).visibleFrame
        XCTAssertGreaterThanOrEqual(panel.frame.minX,visible.minX)
        XCTAssertLessThanOrEqual(panel.frame.maxX,visible.maxX)
        XCTAssertGreaterThanOrEqual(panel.frame.minY,visible.minY)
        XCTAssertLessThanOrEqual(panel.frame.maxY,visible.maxY)
    }
}
#endif
