#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock
final class DoHVisualTests:XCTestCase {
    @MainActor func testMixedToolbarAndNativeSummaryRender() throws {
        guard let output=ProcessInfo.processInfo.environment["TOKENCLOCK_UI_PREVIEW_DIR"] else{throw XCTSkip("Opt-in preview")}
        _=NSApplication.shared
        let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func render<V:View>(_ view:V,_ size:NSSize,_ file:String)throws {
            let host=NSHostingView(rootView:view);host.frame=NSRect(origin:.zero,size:size)
            let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host;window.setFrameOrigin(NSPoint(x:-10000,y:-10000));window.orderFront(nil)
            defer{window.orderOut(nil);window.close()}
            for _ in 0..<5 {host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(file))
        }
        try render(QuickToolGrid(action:{_ in}).padding(12).background(Color(nsColor:.windowBackgroundColor)),NSSize(width:310,height:90),"toolbar-mixed.png")
        let model=NetworkToolboxPresentation()
        model.update(["status":"Check finished","summary":"需核对：DNS；未确认：IPv6、DoH。仅代表本次检测。","running":false,"cards":[
            ["id":"exit","title":"网页出口","status":"已观测","text":"203.0.113.10 · HTTPS / IPv4","state":"observed"],
            ["id":"doh","title":"DoH 路径检查","status":"DNS 已验证 2/2","text":"Cloudflare · DoH 与权威记录已双向验证\nCloudflare DoH 出口 · 203.0.113.10 · 与网页出口一致\nGoogle · DNS 响应已验证，客户端 IP 未确认","state":"incomplete"]]])
        try render(NetworkToolboxView(model:model,onRun:{},onStop:{},onBrowser:{},onOptions:{}),NSSize(width:780,height:600),"network-summary.png")
    }
}
#endif
