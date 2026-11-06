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

@MainActor final class PanelResizeEdgeTests: XCTestCase {
    func testEveryEdgeAndCornerHasTheExpectedDirectionWithoutTakingTheInterior() {
        let bounds = NSRect(x: 100, y: 50, width: 300, height: 240)
        let samples: [(NSPoint, PanelResizeEdge)] = [
            (.init(x:101,y:170),.left), (.init(x:399,y:170),.right),
            (.init(x:250,y:51),.bottom), (.init(x:250,y:289),.top),
            (.init(x:101,y:51),.bottomLeft), (.init(x:399,y:51),.bottomRight),
            (.init(x:101,y:289),.topLeft), (.init(x:399,y:289),.topRight),
        ]
        for (point,edge) in samples { XCTAssertEqual(PanelResizeGeometry.edge(at:point,in:bounds),edge) }
        for point in [NSPoint(x:250,y:170),.init(x:108,y:58),.init(x:99,y:170)] {
            XCTAssertNil(PanelResizeGeometry.edge(at:point,in:bounds))
        }
        let regions = PanelResizeGeometry.regions(in:bounds)
        for i in regions.indices {
            for j in regions.indices where j > i {
                XCTAssertTrue(regions[i].rect.intersection(regions[j].rect).isEmpty, "Cursor regions must not overlap")
            }
        }
    }

    func testDragKeepsTheOppositeEdgeFixedAndRespectsScreenAndSizeLimits() {
        let original = NSRect(x:100,y:100,width:300,height:240)
        let minimum = NSSize(width:180,height:140), maximum = NSSize(width:500,height:400)
        let screen = NSRect(x:0,y:0,width:650,height:600)
        let expanded = PanelResizeGeometry.resizedFrame(from:original,edge:.bottomLeft,delta:.init(width:-500,height:-500),minimum:minimum,maximum:maximum,visibleFrame:screen)
        XCTAssertEqual(expanded,NSRect(x:0,y:0,width:400,height:340))
        XCTAssertEqual(expanded.maxX,original.maxX);XCTAssertEqual(expanded.maxY,original.maxY)
        let shrunk = PanelResizeGeometry.resizedFrame(from:original,edge:.bottomLeft,delta:.init(width:1000,height:1000),minimum:minimum,maximum:maximum,visibleFrame:screen)
        XCTAssertEqual(shrunk,NSRect(x:220,y:200,width:180,height:140))
        let topRight = PanelResizeGeometry.resizedFrame(from:original,edge:.topRight,delta:.init(width:1000,height:1000),minimum:minimum,maximum:maximum,visibleFrame:screen)
        XCTAssertEqual(topRight,NSRect(x:100,y:100,width:500,height:400))
        let horizontal = PanelResizeGeometry.resizedFrame(from:original,edge:.right,delta:.init(width:40,height:1000),minimum:minimum,maximum:maximum,visibleFrame:nil)
        XCTAssertEqual(horizontal,NSRect(x:100,y:100,width:340,height:240))
    }

    func testTranslatedViewHitTestingAndInteriorControlsRemainUsable() throws {
        let parent = NSView(frame:NSRect(x:0,y:0,width:600,height:600))
        let edgeView = PanelResizeEdgesView(frame:NSRect(x:150,y:70,width:240,height:200))
        parent.addSubview(edgeView)
        XCTAssertTrue(edgeView.hitTest(NSPoint(x:151,y:170)) === edgeView)
        XCTAssertNil(edgeView.hitTest(NSPoint(x:270,y:170)))
        XCTAssertNil(edgeView.hitTest(NSPoint(x:1,y:100)))
        edgeView.bounds.origin = NSPoint(x:10,y:20)
        XCTAssertTrue(edgeView.hitTest(NSPoint(x:151,y:170)) === edgeView)
        parent.isHidden = true
        XCTAssertNil(edgeView.hitTest(NSPoint(x:151,y:170)))

        let panel = NotificationPanel();panel.isReleasedWhenClosed=false
        defer {panel.close()}
        let content=NSView(frame:NSRect(x:0,y:0,width:280,height:240))
        let button=NSButton(title:"Existing control",target:nil,action:nil)
        button.frame=NSRect(x:80,y:80,width:120,height:30);content.addSubview(button)
        panel.contentView=PanelResizeEdgesView.wrapping(content)
        let installed=try XCTUnwrap(PanelResizeEdgesView.install(on:panel))
        XCTAssertTrue(PanelResizeEdgesView.install(on:panel) === installed)
        XCTAssertTrue(panel.contentView?.hitTest(NSPoint(x:130,y:95)) === button)
        XCTAssertNil(installed.hitTest(NSPoint(x:130,y:95)))
        installed.updateTrackingAreas()
        XCTAssertTrue(installed.trackingAreas.allSatisfy{$0.options.contains(.activeAlways) && $0.options.contains(.cursorUpdate)})
    }

    private func event(_ type:NSEvent.EventType,screenPoint:NSPoint,window:NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:window.convertPoint(fromScreen:screenPoint),
            modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }

    func testNotificationCornerDragChangesBothDimensionsAndRetainsThemAfterReopening() throws {
        _ = NSApplication.shared
        let screen=try XCTUnwrap(NSScreen.main).visibleFrame
        let clock=NSRect(x:screen.midX-120,y:screen.maxY-220,width:240,height:200)
        let panel=NotificationPanel();panel.alphaValue=0;panel.isReleasedWhenClosed=false
        defer {panel.orderOut(nil);panel.close()}
        panel.contentView=PanelResizeEdgesView.wrapping(NSView(frame:NSRect(origin:.zero,size:panel.frame.size)))
        let handle=try XCTUnwrap(PanelResizeEdgesView.install(on:panel))
        panel.show(near:clock)
        let original=panel.frame
        guard original.minX-screen.minX>20,original.minY-screen.minY>25 else {throw XCTSkip("A larger visible screen is needed for the outward corner drag")}
        let start=NSPoint(x:original.minX+1,y:original.minY+1)
        let end=NSPoint(x:start.x-20,y:start.y-25)
        handle.mouseDown(with:try event(.leftMouseDown,screenPoint:start,window:panel))
        handle.mouseDragged(with:try event(.leftMouseDragged,screenPoint:end,window:panel))
        handle.mouseUp(with:try event(.leftMouseUp,screenPoint:end,window:panel))
        XCTAssertEqual(panel.frame.width,original.width+20,accuracy:0.01)
        XCTAssertEqual(panel.frame.height,original.height+25,accuracy:0.01)
        XCTAssertEqual(panel.frame.maxX,original.maxX,accuracy:0.01)
        XCTAssertEqual(panel.frame.maxY,original.maxY,accuracy:0.01)
        panel.hide();panel.show(near:clock)
        XCTAssertEqual(panel.frame.width,original.width+20,accuracy:0.01)
        XCTAssertEqual(panel.frame.height,original.height+25,accuracy:0.01)
    }

    func testDropdownEdgeDragRetainsWidthAndTheOriginalBottomHandleStillWorks() throws {
        _ = NSApplication.shared
        let screen=try XCTUnwrap(NSScreen.main).visibleFrame
        let clock=NSRect(x:screen.midX-120,y:screen.maxY-220,width:240,height:200)
        let panel=DropdownPanel();panel.alphaValue=0;panel.isReleasedWhenClosed=false
        defer {panel.orderOut(nil);panel.close()}
        panel.contentView=PanelResizeEdgesView.wrapping(NSView(frame:NSRect(origin:.zero,size:panel.frame.size)))
        let handle=try XCTUnwrap(PanelResizeEdgesView.install(on:panel))
        panel.show(below:clock,activeToolCount:2,showsWeather:true)
        let original=panel.frame
        guard min(panel.maxSize.width-original.width,screen.maxX-original.maxX)>40 else {throw XCTSkip("A wider visible screen is needed for the outward side drag")}
        let start=NSPoint(x:original.maxX-1,y:original.midY),end=NSPoint(x:original.maxX+39,y:original.midY)
        handle.mouseDown(with:try event(.leftMouseDown,screenPoint:start,window:panel))
        handle.mouseDragged(with:try event(.leftMouseDragged,screenPoint:end,window:panel))
        handle.mouseUp(with:try event(.leftMouseUp,screenPoint:end,window:panel))
        XCTAssertEqual(panel.frame.width,original.width+40,accuracy:0.01)
        XCTAssertEqual(panel.frame.minX,original.minX,accuracy:0.01)
        panel.beginResize();panel.updateResize(deltaY:20);panel.endResize()
        XCTAssertEqual(panel.frame.width,original.width+40,accuracy:0.01)
        panel.hide();panel.show(below:clock,activeToolCount:2,showsWeather:true)
        XCTAssertEqual(panel.frame.width,original.width+40,accuracy:0.01)
    }
}
#endif
