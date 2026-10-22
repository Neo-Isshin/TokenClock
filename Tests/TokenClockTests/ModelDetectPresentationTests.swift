#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor
final class ModelDetectPresentationTests: XCTestCase {
    private func make(_ value: [String: Any]) throws -> ModelDetectResultPresentation {
        ModelDetectResultPresentation(report: try JSONDecoder().decode(ModelDetectJSON.self, from: JSONSerialization.data(withJSONObject: value)))
    }
    func testRegistryIsExactly22EvidenceItemsNotInfrastructureOrDuplicateVotes() throws {
        let p = try make([:])
        XCTAssertEqual(Set(ModelDetectResultPresentation.items.map(\.id)), Set(["S01", "T01", "T02", "T03", "T04", "T05", "P01", "P02", "P03", "P04", "P05", "Q01", "H01", "H02", "H03", "H04", "B01", "B02", "B03", "B04", "N01", "R01"]))
        XCTAssertEqual(p.cells.count, 66)
        XCTAssertEqual(p.observedCount, 0)
        XCTAssertEqual(p.cell("H04", 2).state, .unavailable)
        XCTAssertEqual(p.cell("H04", 3).state, .notRun)
        XCTAssertEqual(p.issueCount, 0)
    }

    func testHarnessDifferenceIsVisibleButChildFieldsAndModelChangesAreObservations() throws {
        let p = try make(["facts":[
            ["code":"source.harness_model_observed", "value":["model":"gpt-6-luna", "owner":"child", "scope":"child_request"]],
            ["code":"source.harness_model_change", "value":["from":"gpt-6-astra", "to":"gpt-6-luna"]]
        ]])
        XCTAssertEqual(p.cell("S01", 1).state, .observed)
        XCTAssertEqual(p.cell("T05", 1).state, .observed)
        XCTAssertEqual(p.issueCount, 0)
        let conflict = try make(["facts":[["code":"source.harness_model_difference", "value":["requested":["gpt-6-astra"], "reported":["gpt-6-luna"]]]]])
        XCTAssertEqual(conflict.cell("S01", 1).state, .issue)
        XCTAssertTrue(conflict.cell("S01", 1).notes[0].text.contains("gpt-6-luna"))
    }
    func testL1MissingDataIsNotPassAndSupplierChangeIsNotModelConflict() throws {
        let p = try make(["facts": [["code": "source.provider_change"], ["code":"source.display_model", "value":"arbitrary"]], "unknowns": [["code":"source.unbound_model_claims"]]])
        XCTAssertEqual(p.cell("S01", 1).state, .limited)
        XCTAssertEqual(p.cell("T05", 1).state, .observed)
        XCTAssertEqual(p.issueCount, 0)
        XCTAssertEqual(p.observedCount(layer: 2), 0)
    }
    func testRecoveredFailureDoesNotBecomeCurrentFailureAndMismatchStillSurvives() throws {
        var input: [String: Any] = ["facts": [["code":"process.test_result", "value":"fail"]], "verification_history": ["groups": [["state":"recovered_checks", "last_result":"pass"]]]]
        let p = try make(input)
        XCTAssertEqual(p.cell("P03", 1).state, .observed)
        XCTAssertEqual(p.cell("P04", 1).state, .observed)
        input["facts"] = [["code":"process.test_result", "value":"pass"], ["code":"process.test_exit_mismatch", "value":true]]
        XCTAssertEqual(try make(input).cell("P03", 1).state, .issue)
    }
    func testConfirmedCurrentFailureAndUnverifiedClaimStayDifferent() throws {
        let p = try make(["facts": [["code":"process.unverified_completion_claim"]], "verification_history":["groups":[["last_result":"fail"]]]])
        XCTAssertEqual(p.cell("P03", 1).state, .issue)
        XCTAssertEqual(p.cell("Q01", 1).state, .limited)
    }
    func testImportedAnswersStayL1AndNewRequestsUseL2() throws {
        let sample: [String: Any] = ["task_id":"O07:A", "metadata":["completed":true], "extracted":["status":"completed", "features":["strategy":"dict", "distinct_presented_strategies":2]]]
        var result: [String: Any] = ["samples":[sample], "source_scope":"imported_answers", "attempted_requests":0]
        var p = try make(["workflow_mode":"l2", "result":result])
        XCTAssertEqual(p.cell("B01", 1).state, .observed)
        XCTAssertEqual(p.cell("B03", 1).state, .observed)
        XCTAssertEqual(p.cell("B01", 2).state, .notRun)
        result["source_scope"] = "new_live_requests"; result["attempted_requests"] = 2
        p = try make(["workflow_mode":"l2", "result":result])
        XCTAssertEqual(p.cell("B01", 2).state, .observed)
        XCTAssertEqual(p.observedCount(layer: 1), 0)
    }
    func testTruncatedSampleIsNotBehaviorObservationOrFailure() throws {
        let p = try make(["workflow_mode":"l2", "result":["source_scope":"new_live_requests", "samples":[["task_id":"N01:A", "metadata":["completed":false, "truncated":true], "extracted":["features":["selected_content":"盆地"]]]]]])
        XCTAssertEqual(p.cell("N01", 2).state, .limited)
        XCTAssertEqual(p.observedCount, 0)
        XCTAssertEqual(p.issueCount, 0)
    }
    func testNullOrUnclassifiedFeaturesAreNotMeasuredCoverage() throws {
        for feature: Any in [NSNull(), "UNKNOWN", "UNCLASSIFIED"] {
            let p = try make(["workflow_mode":"l2", "result":["source_scope":"new_live_requests", "samples":[["task_id":"O07:A", "metadata":["completed":true], "extracted":["features":["strategy":feature]]]]]])
            XCTAssertEqual(p.cell("B01", 2).state, .limited)
            XCTAssertEqual(p.observedCount, 0)
        }
    }
    func testHeavyPartialChecksDoNotBecomeFullPassAndTruncationOverridesFailure() throws {
        var result: [String: Any] = ["task_id":"H04", "source":["kind":"live_probe"], "checks":[["id":"xml", "status":"pass"], ["id":"spatial", "status":"unknown"]]]
        XCTAssertEqual(try make(["workflow_mode":"l3", "result":result]).cell("H04", 3).state, .limited)
        result["checks"] = [["id":"xml", "status":"fail"], ["id":"generation.complete", "status":"unknown"]]
        let p = try make(["workflow_mode":"l3", "result":result])
        XCTAssertEqual(p.cell("H04", 3).state, .limited)
        XCTAssertEqual(p.issueCount, 0)
    }
    func testArtifactChecksAndTargetToolEventsAreAssignedToTheirActualLayer() throws {
        let imported = try make(["workflow_mode":"l3", "result":["task_id":"H01", "source":["kind":"real_artifact"], "checks":[["id":"balance", "status":"fail"]]]])
        XCTAssertEqual(imported.cell("H01", 1).state, .issue)
        XCTAssertEqual(imported.cell("H01", 3).state, .notRun)
        let live = try make(["workflow_mode":"l3", "result":["task_id":"H03", "execution":["action_origin":"live_target"], "trajectory":["events":[["actor":"target", "action":"read_file"], ["actor":"evaluator", "action":"write_file"], ["actor":"simulated_target", "action":"run_checks"]]]]])
        XCTAssertEqual(live.cell("P01", 3).state, .observed)
        XCTAssertEqual(live.cell("P02", 3).state, .notRun)
        XCTAssertEqual(live.cell("P03", 3).state, .notRun)
    }
    func testDiagnosticsShowMechanismObservationsNotIdentityClaims() throws {
        let p = try make(["workflow_mode":"diagnostics", "result":["task_id":"diagnostics", "checks":[["id":"model_declaration:0", "status":"pass"], ["id":"usage:0", "status":"fail"]], "observations":[["type":"explicit_text_stage_comparison", "status":"observed"], ["type":"session_visible_field_change"]]]])
        XCTAssertEqual(p.cell("S01", 1).state, .aligned)
        XCTAssertEqual(p.cell("T02", 1).state, .issue)
        XCTAssertEqual(p.cell("T01", 1).state, .observed)
        XCTAssertEqual(p.cell("T05", 1).state, .observed)
        XCTAssertTrue(p.cell("T02", 1).notes.first!.pointer.hasPrefix("/result/checks/"))
    }
    func testMissingUsageAndUnknownModelIdentityNeverBecomeAnAllClear() throws {
        let p = try make(["facts":[["code":"resource.usage_consistency"]], "user_summary":["brief":["status":"insufficient_evidence", "title":"old", "summary":"No comparable reference"]]])
        XCTAssertEqual(p.cell("T02", 1).state, .limited)
        XCTAssertEqual(p.tone, .limited)
        XCTAssertEqual(p.summary, "No comparable reference")
        XCTAssertNotEqual(p.title, "old")
    }
    func testConflictingReferenceDirectionsRemainMixedAndSyntheticIsClearlyLabeled() throws {
        let mixed = try make(["user_summary":["brief":["status":"mixed_local_directions"]]])
        XCTAssertEqual(mixed.tone, .observed)
        let demo = try make(["scope":["synthetic":true], "user_summary":["brief":["status":"local_declared_alignment"]]])
        XCTAssertTrue(demo.isControlled)
        XCTAssertEqual(demo.tone, .observed)
        XCTAssertTrue(demo.title.contains("演示") || demo.title.contains("Demonstration"))
    }
    func testCombinedReportsPreserveLayerAndWarnOfMultipleSubjects() throws {
        let child: [String:Any] = ["facts":[["code":"source.model_claim_consistent"]]]
        let p = try make(["workflow_mode":"combined", "result":["components":[["report":child], ["report":child]]], "user_summary":["synthesis":["subjects":[["id":"a"], ["id":"b"]]]]])
        XCTAssertEqual(p.observedCount, 1)
        XCTAssertTrue(p.multipleSubjects)
        XCTAssertEqual(p.cell("S01", 1).notes.count, 2)
        XCTAssertTrue(p.cell("S01", 1).notes[0].pointer.hasPrefix("/result/components/0/report/"))
    }
}
#endif
