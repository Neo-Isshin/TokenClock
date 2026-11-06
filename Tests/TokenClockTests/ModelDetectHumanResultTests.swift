#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor
final class ModelDetectHumanResultTests: XCTestCase {
    private func make(_ value: [String: Any]) throws -> ModelDetectResultPresentation {
        ModelDetectResultPresentation(report: try JSONDecoder().decode(ModelDetectJSON.self, from: JSONSerialization.data(withJSONObject: value)))
    }
    func testRadarMeasuresUniqueCoverageNotPassingRateOrLayerVotes() throws {
        let child: [String: Any] = ["facts": [["code":"source.model_claim_difference"]]]
        let p = try make(["workflow_mode":"combined","result":["components":[["report":child],["report":child]]]])
        XCTAssertEqual(p.radarAxes.count,6)
        XCTAssertEqual(p.radarAxes[0].observed,1)
        XCTAssertEqual(p.radarAxes[0].coverage,1)
        XCTAssertEqual(p.radarAxes[0].state,.issue)
        XCTAssertEqual(p.radarAxes[4].coverage,0)
        XCTAssertEqual(p.radarAxes[4].state,.notRun)
    }
    func testUnknownDoesNotBecomeCoverageOrSuccess() throws {
        let p = try make(["unknowns":[["code":"source.unbound_model_claims"]]])
        XCTAssertEqual(p.radarAxes[0].coverage,0)
        XCTAssertEqual(p.radarAxes[0].state,.limited)
    }
    func testSharedHumanResultIsNotOverwrittenByNativeStatusWording() throws {
        let p = try make(["user_summary":["brief":["status":"source_conflict","title":"old","display":["schema":"tokenclock-human-result/v1","title":"型号记录不一致","summary":"请求和返回记录不同。","tone":"issue"]]]])
        XCTAssertEqual(p.title,"型号记录不一致")
        XCTAssertEqual(p.summary,"请求和返回记录不同。")
        XCTAssertEqual(p.tone,.issue)
    }
    func testReadableReportEscapesInputAndPreservesMissingDataAndConclusion() throws {
        let brief = ModelDetectNativeModel.Brief(title:"尚未完成<script>",summary:"缺少回答",reasons:["<img src=x onerror=alert(1)>"],caveat:"不能判断",primaryActionTitle:nil)
        let html = ModelDetectReadableReport.render(brief:brief,presentation:try make([:]),target:"<unsafe>",suggestion:"查看原因",cost:"$0")
        XCTAssertTrue(html.contains("尚未完成&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"));XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("<svg"));XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains(ModelDetectRadarView.label(.notRun)))
        XCTAssertFalse(html.contains("fill-opacity='.13'"))
    }
    func testReadableExportIncludesComparisonWithoutChangingCurrentConclusion() throws {
        let brief = ModelDetectNativeModel.Brief(title:"本次结论",summary:"本次观察",reasons:[],caveat:"",primaryActionTitle:nil)
        let comparison: ModelDetectJSON = .object(["title":.string("这两次暂时不能直接比较"),"summary":.string("条件不同"),"left":.object(["title":.string("<script>历史</script>")])])
        let html = ModelDetectReadableReport.render(brief:brief,presentation:try make([:]),target:"test",suggestion:"",cost:"",comparison:comparison)
        XCTAssertTrue(html.contains("<h1>本次结论</h1>"))
        XCTAssertTrue(html.contains(ModelDetectNativeText.localized("历史对照", "History comparison")));XCTAssertFalse(html.contains("<script>"))
    }
}
#endif
