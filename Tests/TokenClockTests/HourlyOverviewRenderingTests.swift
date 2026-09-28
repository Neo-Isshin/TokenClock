#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class HourlyOverviewRenderingTests: XCTestCase {
    @MainActor func testTwentyFourHourOverviewRendersWithoutClipping() throws {
        let date = Calendar.current.startOfDay(for: Date())
        let key = DateHelper.dateKey(from: date)
        let snapshots = (0..<24).map { index -> DaySnapshot in
            let tokens = index < 6 ? 0 : ((index * 17) % 13 + 1) * 8000
            var hour = HourlyUsage(tokens: tokens,messages:tokens > 0 ? 1:0)
            if tokens > 0 { hour.recordMetadata(tokens:tokens,cache:tokens/2,model:"gpt-6-sol",cost:.init(value:Double(tokens)/100000)) }
            return DaySnapshot(date:key+"-"+String(format:"%02d",index), totalTokens:tokens,totalMessages:hour.messages,
                tools:tokens > 0 ? [hour.historyTool(name:"Codex")] : [])
        }
        let data = UsageOverviewBuilder.makeHourly(date:date,hourly:snapshots,daily:[],grouping:.tool)
        let models = UsageOverviewBuilder.makeHourly(date:date,hourly:snapshots,daily:[],grouping:.model)
        let view = NSHostingView(rootView: UsageOverviewView(previewData:data,modelData:models).environment(\.colorScheme,.light))
        view.frame = NSRect(x:0,y:0,width:900,height:680)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(png.count,10000)
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_HOURLY_PREVIEW"] {
            try png.write(to:URL(fileURLWithPath:path))
        }
    }
}
#endif
