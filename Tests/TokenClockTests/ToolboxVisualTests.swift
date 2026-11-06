#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock
final class ToolboxVisualTests: XCTestCase {
    @MainActor func testSharingArtworkAndNativePanelsRender() throws {
        guard let output=ProcessInfo.processInfo.environment["TOKENCLOCK_UI_PREVIEW_DIR"] else {throw XCTSkip("Opt-in rendering artifacts")}
        _=NSApplication.shared
        let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func save(_ image:NSImage,_ name:String) throws {let bitmap=NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))!;try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name))}
        let names=["Codex","Claude Code","Grok Bot","Gemini CLI","Cursor Agent","ZCode","Other"]
        let rows=names.enumerated().map { i,n in UsageShareRow(name:n,emoji:"◈",tokens:(7-i)*100000,fraction:Double(7-i)/28) }
        let data=UsageShareData(period:.recent(days:7,ending:Date()),includesCacheRead:false,dateKey:"2026-10-29",endDateKey:"2026-11-04",totalTokens:2800000,messages:500,averageCacheRate:0.8,rows:rows,quoteKey:"share.quote1")
        XCTAssertNotNil(ShareArtwork.image("ailyre"))
        for scene in ["alpine","forest"] {
            let image=try XCTUnwrap(UsageShareImageRenderer.image(for:data,artwork:ShareArtwork.image(scene)))
            XCTAssertEqual(image.size.width,1200)
            try save(image,"share-"+scene+".png")
        }
        let tools = ["Codex","Claude Code","Cursor Agent","Grok Bot","ZCode","Gemini CLI"].enumerated().map { index,name in
            ToolUsage(name:name,abbreviation:"",emoji:"",todayTokens:(6-index)*100000,todayMessages:50,isActive:false,recentTokens:0,hourlyTokens:0)
        }
        let quotas = SubscriptionProvider.allCases.prefix(6).map { provider in
            StatusSummaryQuota(indicator:.init(provider:provider,outerRemainingPercent:83,innerRemainingPercent:65,details:[]),isShared:false,resets:[.init(labelKey:"quota.dial.weekly",windowMinutes:10080,resetsAt:Date().addingTimeInterval(72000),source:"fixture")])
        }
        let summary=NSHostingView(rootView:StatusSummaryContent(snapshot:.init(tools:tools,includesCache:false),models:[],date:"Nov 4",tokens:"2.1M",cost:"$12.30",side:600,quotas:quotas,onHistory:{},onQuota:{},onShare:{}))
        summary.frame=NSRect(x:0,y:0,width:612,height:612);summary.layoutSubtreeIfNeeded()
        let bitmapSummary=try XCTUnwrap(summary.bitmapImageRepForCachingDisplay(in:summary.bounds));summary.cacheDisplay(in:summary.bounds,to:bitmapSummary)
        let summaryImage=NSImage(size:summary.frame.size);summaryImage.addRepresentation(bitmapSummary);try save(summaryImage,"summary-adaptive.png")
        for item in QuickTool.allCases {XCTAssertNotNil(NSImage(systemSymbolName:item.symbol,accessibilityDescription:nil))}
        let model=NetworkToolboxPresentation()
        model.update(["status":"检测完成","running":false,"cards":[["id":"ip","title":"出口与地区","status":"观测一致","text":"Ailyre · 203.0.113.10\nCloudflare · 203.0.113.10\nCountry · US","state":"match"],["id":"dns","title":"DNS 解析器","status":"需要核对","text":"1.1.1.1\n8.8.8.8","state":"review"]]])
        let view=NSHostingView(rootView:NetworkToolboxView(model:model,onRun:{},onStop:{},onBrowser:{},onOptions:{}))
        view.frame=NSRect(x:0,y:0,width:780,height:650);view.layoutSubtreeIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
        let image=NSImage(size:view.frame.size);image.addRepresentation(bitmap);try save(image,"network-native.png")
    }
}
#endif
