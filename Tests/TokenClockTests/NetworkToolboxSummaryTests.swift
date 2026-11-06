#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor final class NetworkToolboxSummaryTests: XCTestCase {
    func testUnknownAndDNSWithoutExpectationAreNotClaimedSafeOrLeaking() {
        let model = NetworkToolboxPresentation()
        model.cards = [.init(id:"dns",title:"DNS",status:"Review",text:"",state:"review"),.init(id:"rtc",title:"WebRTC",status:"",text:"",state:"incomplete")]
        XCTAssertFalse(model.issueSummary.contains("possible leak"))
        XCTAssertFalse(model.issueSummary.contains("可能泄漏"))
        XCTAssertFalse(model.issueSummary.contains("未检出"))
        XCTAssertFalse(model.issueSummary.contains("No leak"))
        XCTAssertTrue(model.pendingSummary.contains("DNS"))
        XCTAssertTrue(model.pendingSummary.contains("WebRTC"))
    }
    func testSummaryNamesOnlyRisksAndKeepsUnknownSeparate() {
        let model = NetworkToolboxPresentation()
        model.cards = [.init(id:"dns",title:"DNS",status:"",text:"",state:"risk"),.init(id:"rtc",title:"WebRTC",status:"",text:"",state:"match"),.init(id:"doh",title:"DoH",status:"",text:"",state:"incomplete")]
        XCTAssertTrue(model.issueSummary.contains("DNS"))
        XCTAssertFalse(model.issueSummary.contains("WebRTC"))
        XCTAssertFalse(model.issueSummary.contains("DoH"))
        XCTAssertTrue(model.pendingSummary.contains("DoH"))
        model.running = true
        XCTAssertFalse(model.issueSummary.contains("DNS"))
    }
}
#endif
