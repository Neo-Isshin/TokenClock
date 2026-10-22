#if os(macOS)
import XCTest
import Foundation
@testable import TokenClock

/// Independent native state-machine challenges. Only a fake async service is
/// used; no Launcher, URLSession, NSWindow, credential store or user defaults.
@MainActor
final class ModelDetectNativeFlowTests: XCTestCase {
    private static let jobID = "job-" + String(repeating: "a", count: 32)

    private final class Service: ModelDetectNativeServing {
        struct Call { let route: String; let body: ModelDetectJSON? }
        var calls: [Call] = []
        var held = Set<String>()
        var waiting: [String: [CheckedContinuation<ModelDetectJSON, Error>]] = [:]
        var previewReply: ModelDetectJSON = .null
        var submitReply: ModelDetectJSON = .null
        var jobReply: ModelDetectJSON = .null
        var cancelReply: ModelDetectJSON = .null
        var reportReply: ModelDetectJSON = .null
        var profiles: [ModelDetectJSON] = []
        var historyRows: [ModelDetectJSON] = []
        var historyReply: ModelDetectJSON = .object([:])
        var infoReply: ModelDetectJSON = .object([:])
        var submitError: Error?
        var pollError: Error?

        func request(_ route: String, body: ModelDetectJSON?) async throws -> ModelDetectJSON {
            calls.append(Call(route: route, body: body))
            let key = (body == nil ? "GET " : "POST ") + route
            if held.contains(key) {
                return try await withCheckedThrowingContinuation { waiting[key, default: []].append($0) }
            }
            if route == "api/sessions" { return .object(["sessions": .array([])]) }
            if route == "api/connections" { return .object(["profiles": .array(profiles)]) }
            if route == "api/jobs", body == nil { return .object(["jobs": .array(historyRows)]) }
            if route == "api/history/compare" { return historyReply }
            if route == "api/info" { return infoReply }
            if route == "api/preview" { return previewReply }
            if route == "api/jobs" {
                if let submitError { throw submitError }
                return submitReply
            }
            if route.hasSuffix("/cancel") { return cancelReply }
            if route.hasPrefix("reports/") { return reportReply }
            if route.hasPrefix("api/jobs/") {
                if let pollError { throw pollError }
                return jobReply
            }
            throw ModelDetectNativeClientError.invalidRoute
        }
        func download(_ route: String) async throws -> Data { throw ModelDetectNativeClientError.invalidRoute }
        func count(_ route: String, post: Bool = true) -> Int {
            calls.filter { $0.route == route && ($0.body != nil) == post }.count
        }
        func release(_ key: String, value: ModelDetectJSON) {
            held.remove(key)
            let continuations = waiting.removeValue(forKey: key) ?? []
            continuations.forEach { $0.resume(returning: value) }
        }
        func cancelWaiting() {
            let continuations = waiting.values.flatMap { $0 }; waiting = [:]; held = []
            continuations.forEach { $0.resume(throwing: ModelDetectNativeClientError.cancelled) }
        }
    }

    private func role(_ name: String) -> ModelDetectJSON {
        .object(["role": .string(name), "enabled": .bool(true), "budget_usd": .string("1"),
                 "sends": .array([.string(name == "target" ? "本次原题" : "本次回答")])])
    }
    private func preview(local: Bool, judge: Bool = false) -> ModelDetectJSON {
        .object(["valid": .bool(true), "local_only": .bool(local),
                 "roles": .array(local ? [] : judge ? [role("target"), role("judge")] : [role("target")]),
                 "total_budget_usd": .string(local ? "0" : judge ? "2" : "1"),
                 "total_upper_usd": .string(local ? "0" : "0.1"), "errors": .array([]), "warnings": .array([])])
    }
    private func job(_ status: String = "running", costs: Bool = false) -> ModelDetectJSON {
        var value: [String: ModelDetectJSON] = ["id": .string(Self.jobID), "status": .string(status),
            "input_name": .string("controlled.jsonl"), "progress": .object(["message": .string("Controlled progress"), "fraction": .number(0.4)])]
        if costs { value["probe_billing"] = .object(["totals": .object([
            "reported_actual_cost_usd": .string("0.20"), "estimated_only_cost_usd": .string("0.03"), "pending_reserved_cost_usd": .string("0.15")])]) }
        return .object(value)
    }
    private func report(recommendation: Bool = false) -> ModelDetectJSON {
        var user: [String: ModelDetectJSON] = ["brief": .object([
            "schema": .string("tokenclock-result-brief/v1"), "status": .string("insufficient_evidence"),
            "title": .string("暂时还不能下结论"), "summary": .string("Controlled limited observation"),
            "reasons": .array([.string("可见记录不完整")]), "caveat": .string("没有判断不等于正常。"),
            "next_action": .object(recommendation ? ["kind": .string("recommendation"), "id": .string("next-N01-A"), "label": .string("配置下一步检测")] : ["kind": .string("none")])])]
        if recommendation {
            user["recommendation"] = .object(["schema": .string("tokenclock-next-detection/v1"), "status": .string("recommended"),
                "automatic_dispatch": .bool(false), "remaining_budget_usd": .string("0.4"),
                "target_binding": .object(["endpoint": .string("https://example.invalid/v1/chat/completions"), "api_format": .string("chat_completions"), "model": .string("gpt-5.5")]),
                "actions": .array([.object(["id": .string("next-N01-A"), "title":.string("复查回答"), "reason":.string("确认差别是否重复出现"), "request_count":.number(2), "estimated_reserve_usd":.string("0.123456"), "configuration_patch": .object([
                    "workflow_mode": .string("l2"), "transport_mode": .string("live"), "family": .string("openai"),
                    "task_ids": .array([.string("N01:A")]), "provider": .object(["max_cost_usd": .string("0.4")])])])])])
        }
        return .object(["schema": .string("tokenclock-product-report/v1"), "user_summary": .object(user)])
    }
    private func source() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("controlled.jsonl"); try Data("{}\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
    }
    private func makeModel(pollInterval: UInt64 = 60_000_000_000) -> (ModelDetectNativeModel, Service) {
        let service = Service(); service.previewReply = preview(local: true)
        service.submitReply = job(); service.jobReply = job(); service.cancelReply = job("cancelling", costs: true); service.reportReply = report()
        let model = ModelDetectNativeModel(service: service, starter: { _ in XCTFail("Injected service must not start a real worker") },
            serviceFactory: { _ in throw ModelDetectNativeClientError.invalidReadyURL }, pollInterval: pollInterval)
        addTeardownBlock { await MainActor.run {
            service.cancelWaiting()
            // Test-only cleanup of the owned polling Task, never backend cancel.
            model.phase = .result; model.newDetection()
        } }
        return (model, service)
    }
    private func configureAPI(_ model: ModelDetectNativeModel, judge: Bool = false) {
        if judge { model.l2Method = "behavior" }
        model.mode = .api; model.endpoint = "https://example.invalid/v1/chat/completions"; model.modelID = "gpt-5.5"
        model.apiFormat = "chat_completions"; model.inputPrice = "1"; model.outputPrice = "2"; model.budget = "1"
        model.apiKey = "synthetic-native-flow-key"; model.assessmentEnabled = judge; model.reuseTargetForAssessment = true
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Bounded async flow condition not reached")
    }

    func testConnectAndSourcePrefillNeverRunAnalysis() async throws {
        let (model, service) = makeModel(); await model.connectNow()
        let url = try source(); model.prefillSource(url)
        XCTAssertEqual(model.sourceURL, url); XCTAssertEqual(model.phase, .input)
        XCTAssertEqual(service.count("api/preview"), 0); XCTAssertEqual(service.count("api/jobs"), 0)
    }

    func testLocalOneClickPreviewsThenSubmitsWithoutExternalAuthority() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source()
        await model.prepareNow()
        XCTAssertEqual(service.count("api/preview"), 1); XCTAssertEqual(service.count("api/jobs"), 1)
        let submitted = try XCTUnwrap(service.calls.first { $0.route == "api/jobs" && $0.body != nil }?.body)
        XCTAssertEqual(submitted["allow_external"].bool, false)
        XCTAssertEqual(submitted["semantic_config"]["mode"].string, "local")
        XCTAssertEqual(submitted["source_path"].string, model.sourceURL?.path)
    }

    func testPaidRolesEachRequireConfirmation() async throws {
        let (model, service) = makeModel(); configureAPI(model, judge: true); service.previewReply = preview(local: false, judge: true)
        await model.prepareNow(); XCTAssertEqual(service.count("api/jobs"), 0); XCTAssertFalse(model.canStart)
        model.targetConsent = true; await model.confirmStartNow(); XCTAssertEqual(service.count("api/jobs"), 0)
        model.judgeConsent = true; XCTAssertTrue(model.canStart); await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 1)
        let payload = try XCTUnwrap(service.calls.first { $0.route == "api/jobs" && $0.body != nil }?.body)
        XCTAssertEqual(payload["allow_external"].bool, true)
        XCTAssertEqual(payload["semantic_config"]["allow_live"].bool, true)
        XCTAssertEqual(payload["semantic_config"]["assessment"]["allow_live"].bool, true)
    }

    func testConfigurationEditClearsPreparedConfirmation() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: false)
        await model.prepareNow(); model.targetConsent = true; XCTAssertTrue(model.canStart)
        model.budget = "0.5"
        XCTAssertNil(model.preview); XCTAssertFalse(model.targetConsent); XCTAssertFalse(model.canStart)
        await model.confirmStartNow(); XCTAssertEqual(service.count("api/jobs"), 0)
    }

    func testQuickConfirmationSubmitsBothDisclosedRolesOnceAndNothingBeforeClick() async throws {
        let (model, service) = makeModel(); configureAPI(model, judge: true)
        service.previewReply = preview(local: false, judge: true)
        await model.prepareNow()
        XCTAssertTrue(model.canConfirmReviewed)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(service.count("api/jobs"), 0)
        model.confirmReviewedStart(); model.confirmReviewedStart()
        try await wait { service.count("api/jobs") == 1 }
        XCTAssertEqual(service.count("api/jobs"), 1)
        XCTAssertFalse(model.canConfirmReviewed)
    }

    func testQuickConfirmationCannotReuseChangedScopeOrMissingExternalRoles() async throws {
        let (model, service) = makeModel(); configureAPI(model)
        service.previewReply = preview(local: false)
        await model.prepareNow(); model.modelID = "gpt-6-astra"
        XCTAssertFalse(model.canConfirmReviewed); model.confirmReviewedStart()
        await Task.yield(); XCTAssertEqual(service.count("api/jobs"), 0)
        service.previewReply = preview(local: true)
        await model.prepareNow(); XCTAssertFalse(model.canConfirmReviewed)
        model.confirmReviewedStart(); await Task.yield()
        XCTAssertEqual(service.count("api/jobs"), 0)
    }

    func testSessionModelPrefillIsComparedWithoutStartingOrReplacingRecordedClaims() async throws {
        let (model, service) = makeModel(); let url = try source()
        model.recentSessions = [.init(id: url.path, title: "Astra session", url: url, model: "gpt-6-astra")]
        model.selectSession(id: url.path)
        XCTAssertEqual(model.comparisonModel, "gpt-6-astra")
        XCTAssertEqual(service.count("api/jobs"), 0)
        await model.prepareNow()
        let request = try XCTUnwrap(service.calls.first { $0.route == "api/jobs" && $0.body != nil }?.body)
        XCTAssertEqual(request["comparison_model"].string, "gpt-6-astra")
        XCTAssertNil(request["semantic_config"]["provider"]["model"].string)
    }

    func testChoosingANewFileClearsPreviousExpectedModel() throws {
        let (model, _) = makeModel()
        model.prefillSource(try source(), expectedModel: "gpt-6-astra")
        model.prefillSource(try source())
        XCTAssertEqual(model.comparisonModel, "")
    }

    func testLateLocalPreviewCannotSubmitChangedInput() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source(); service.held.insert("POST api/preview")
        let task = Task { await model.prepareNow() }
        try await wait { service.count("api/preview") == 1 }
        model.sourceURL = try source()
        service.release("POST api/preview", value: preview(local: true)); await task.value
        XCTAssertEqual(service.count("api/jobs"), 0); XCTAssertNil(model.preview); XCTAssertFalse(model.canStart)
    }

    func testConcurrentLocalPrepareHasOnePreviewAndOneSubmit() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source(); service.held.insert("POST api/preview")
        let first = Task { await model.prepareNow() }; try await wait { service.count("api/preview") == 1 }
        let second = Task { await model.prepareNow() }; await second.value
        XCTAssertEqual(service.count("api/preview"), 1)
        service.release("POST api/preview", value: preview(local: true)); await first.value
        XCTAssertEqual(service.count("api/jobs"), 1)
    }

    func testConcurrentConfirmHasOneSubmission() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: false)
        await model.prepareNow(); model.targetConsent = true; service.held.insert("POST api/jobs")
        let first = Task { await model.confirmStartNow() }; try await wait { service.count("api/jobs") == 1 }
        let second = Task { await model.confirmStartNow() }; await second.value
        XCTAssertEqual(service.count("api/jobs"), 1)
        service.release("POST api/jobs", value: job()); await first.value
    }

    func testUncertainSubmitOutcomeCannotReuseSamePreviewApproval() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: false)
        await model.prepareNow(); model.targetConsent = true; service.submitError = ModelDetectNativeClientError.transportUnavailable
        await model.confirmStartNow(); await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 1, "Unknown POST outcome must not be retried under the same approval")
        XCTAssertFalse(model.canStart)
    }

    func testPaidConfigurationCannotAutoRunUnderMislabelledLocalPreview() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: true)
        await model.prepareNow(); await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 0)
        XCTAssertFalse(model.canStart, "A preview that omits the configured external role is not an admissible confirmation")
    }

    func testInvalidPreviewNeverSubmits() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source()
        service.previewReply = .object(["valid": .bool(false), "local_only": .bool(true), "errors": .array([.string("controlled invalid input")])])
        await model.prepareNow(); await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 0); XCTAssertFalse(model.canStart)
    }

    func testChangedEndpointCannotForwardPreviouslyTypedCredential() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: false)
        model.endpoint = "https://other.example.invalid/v1/chat/completions"
        XCTAssertEqual(model.inputPrice, "", "A new channel cannot inherit the prior channel's quotation")
        XCTAssertEqual(model.outputPrice, "")
        model.inputPrice = "1.5"; model.outputPrice = "3"
        XCTAssertEqual(model.apiKey, "synthetic-native-flow-key")
        await model.prepareNow(); model.targetConsent = true; await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 0); XCTAssertFalse(model.canStart)
        model.apiKey = "synthetic-explicitly-reentered-key"
        await model.prepareNow(); model.targetConsent = true; await model.confirmStartNow()
        XCTAssertEqual(service.count("api/jobs"), 1)
    }

    func testCancellationAndFailureRetainKnownAndPendingFees() async throws {
        let (model, service) = makeModel(pollInterval: 1_000_000); model.sourceURL = try source()
        service.submitReply = job(costs: true); service.jobReply = job(costs: true)
        await model.prepareNow(); await model.cancelNow()
        XCTAssertEqual(service.count("api/jobs/" + Self.jobID + "/cancel"), 1)
        XCTAssertTrue(model.costSummary.contains("0.20")); XCTAssertTrue(model.costSummary.contains("0.15"))
        service.jobReply = job("failed", costs: true); try await wait { model.phase == .result }
        XCTAssertTrue(model.costSummary.contains("0.20")); XCTAssertTrue(model.costSummary.contains("0.03")); XCTAssertTrue(model.costSummary.contains("0.15"))
        XCTAssertEqual(model.currentJobID, Self.jobID); XCTAssertEqual(service.count("api/jobs"), 1)
    }

    func testRunningTaskCannotBeReplacedByPrefillOrNewDetection() async throws {
        let (model, service) = makeModel(); let firstURL = try source(); model.sourceURL = firstURL
        await model.prepareNow(); model.prefillSource(try source()); model.newDetection()
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(model.sourceURL, firstURL); XCTAssertEqual(model.currentJobID, Self.jobID)
        XCTAssertEqual(service.count("api/jobs"), 1); XCTAssertEqual(service.count("api/jobs/" + Self.jobID + "/cancel"), 0)
    }

    func testCompletionDisplaysSuppliedSingleBriefWithoutRegrading() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source(); service.jobReply = job("completed")
        await model.prepareNow(); try await wait { model.phase == .result }
        XCTAssertEqual(model.brief?.title, ModelDetectNativeText.text("资料不足，无法判定型号", "資料不足，無法判定型號", "Insufficient evidence to identify the model"))
        XCTAssertEqual(model.brief?.reasons, ["可见记录不完整"]); XCTAssertNil(model.brief?.primaryActionTitle)
        XCTAssertEqual(service.count("api/jobs"), 1)
    }

    func testMissingBriefIsNotInventedAsNormalOrGivenAnInertRetry() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source(); service.jobReply = job("completed"); service.reportReply = .object(["result":.object(["status":.string("completed")])])
        await model.prepareNow(); try await wait { model.phase == .result }
        XCTAssertNotEqual(model.brief?.title, "型号正常")
        XCTAssertEqual(model.brief?.primaryActionTitle, "重新读取结果")
        let route = "reports/" + Self.jobID + "/report.json"
        let reads = service.count(route, post: false)
        model.performPrimaryAction()
        try await wait { service.count(route, post: false) > reads }
        XCTAssertEqual(service.count("api/jobs"), 1, "Reloading cannot submit a second job")
    }

    func testRecommendationRetainsRemainingBudgetAndLineageBeforeNewConfirmation() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local: false)
        service.jobReply = job("completed"); service.reportReply = report(recommendation: true)
        await model.prepareNow(); model.targetConsent = true; await model.confirmStartNow(); try await wait { model.phase == .result }
        model.performPrimaryAction()
        XCTAssertEqual(model.budget, "0.4"); XCTAssertEqual(model.taskIDs, "N01:A"); XCTAssertFalse(model.targetConsent); XCTAssertFalse(model.canStart)
        XCTAssertEqual(service.count("api/jobs"), 1)
        await model.prepareNow(); model.targetConsent = true; await model.confirmStartNow()
        let body = try XCTUnwrap(service.calls.last { $0.route == "api/jobs" && $0.body != nil }?.body)
        XCTAssertEqual(body["recommendation_origin_job_id"].string, Self.jobID); XCTAssertEqual(body["recommendation_action_id"].string, "next-N01-A")
        XCTAssertEqual(body["semantic_config"]["provider"]["max_cost_usd"].string, "0.4")
    }

    func testMalformedPriceDoesNotSilentlyParseAsFreeNumericPrefix() async throws {
        for bad in ["0,5", "1junk", "0garbage"] {
            let (model, service) = makeModel(); configureAPI(model); model.inputPrice = bad; service.previewReply = preview(local: false)
            await model.prepareNow()
            XCTAssertEqual(service.count("api/preview"), 0, "Reject the malformed full value instead of quoting a parsed prefix")
            XCTAssertFalse(model.canStart)
        }
    }

    func testReferencePreviewAppearsBeforeAnyPaidSubmission() async throws {
        let (model, service) = makeModel(); configureAPI(model)
        model.l2Method = "behavior"
        var value = preview(local: false).object
        value["reference_readiness"] = .object(["title":.string("部分题目有可对照的参考"),"summary":.string("3道题中2道有参考")])
        service.previewReply = .object(value)
        await model.prepareNow()
        XCTAssertEqual(model.preview?.referenceTitle,"部分题目有可对照的参考")
        XCTAssertEqual(service.count("api/jobs"),0)
        model.modelID = "unknown-model"
        XCTAssertTrue(model.needsReferenceChoice)
        XCTAssertNil(model.preview)
    }

    func testNumericDefaultUsesLocalScoringAndNoFamilyRequirement() async throws {
        let (model, service) = makeModel(); configureAPI(model)
        XCTAssertEqual(model.l2Method, "numeric")
        model.modelID = "gemini-3.8-flash"
        model.inputPrice = "1"; model.outputPrice = "2"
        let config = try model.configuration(secrets: false, authorized: false)
        XCTAssertEqual(config["l2_method"].string, "numeric")
        XCTAssertEqual(config["provider"]["reasoning_effort"].string, "low")
        XCTAssertEqual(config["family"], .null)
        XCTAssertEqual(config["assessment"], .null)
        XCTAssertFalse(model.needsReferenceChoice)
        XCTAssertTrue(model.planSummary.contains("3 次"))
        XCTAssertEqual(service.count("api/jobs"), 0)
    }

    func testReferenceValidationOverviewIsReadOnlyAndRejectsMissingVerification() async throws {
        let (model, service) = makeModel()
        service.infoReply = .object(["references":.object(["schema":.string("tokenclock-reference-overview/v1"),"status":.string("verified"),"title":.string("参考资料已校验"),"candidate_formal_enabled":.bool(false)])])
        model.refreshReferenceOverview(); try await wait { !model.referenceLoading }
        XCTAssertEqual(model.referenceOverview["status"].string,"verified")
        XCTAssertEqual(model.referenceOverview["candidate_formal_enabled"].bool,false)
        XCTAssertEqual(service.count("api/jobs"),0);XCTAssertEqual(service.count("api/info",post:false),1)
        service.infoReply = .object([:]);model.refreshReferenceOverview();try await wait { !model.referenceLoading }
        XCTAssertEqual(model.referenceOverview,.null);XCTAssertNotNil(model.referenceError)
        XCTAssertEqual(service.count("api/jobs"),0)
    }

    func testHistoryComparisonIsLocalAndLateResultCannotReplaceNewSelection() async throws {
        let (model, service) = makeModel(); model.sourceURL = try source(); service.jobReply = job("completed")
        let earlier = "job-" + String(repeating:"b",count:32)
        service.historyRows = [.object(["id":.string(earlier),"status":.string("completed"),"input_name":.string("earlier")])]
        await model.prepareNow(); try await wait { model.phase == .result && model.history.count == 1 }
        service.held.insert("POST api/history/compare")
        model.compareHistory(with: earlier)
        try await wait { service.waiting["POST api/history/compare"] != nil }
        XCTAssertEqual(service.count("api/jobs"),1)
        model.newDetection()
        service.release("POST api/history/compare", value: .object(["title":.string("stale history")]))
        await Task.yield()
        XCTAssertEqual(model.historyComparison,.null)
        XCTAssertFalse(model.comparingHistory)
    }

    func testFollowUpPreviewCarriesParentBudgetButDoesNotDispatchItself() async throws {
        let (model, service) = makeModel(); configureAPI(model); service.previewReply = preview(local:false)
        service.jobReply = job("completed"); service.reportReply = report(recommendation:true)
        await model.prepareNow(); model.targetConsent=true; await model.confirmStartNow(); try await wait { model.phase == .result }
        let previews = service.count("api/preview")
        model.performPrimaryAction()
        try await wait { service.count("api/preview") > previews && !model.isBusy }
        let payload = try XCTUnwrap(service.calls.last { $0.route == "api/preview" }?.body)
        XCTAssertEqual(payload["recommendation_origin_job_id"].string,Self.jobID)
        XCTAssertEqual(payload["semantic_config"]["provider"]["max_cost_usd"].string,"0.4")
        XCTAssertEqual(service.count("api/jobs"),1)
        XCTAssertFalse(model.targetConsent)
        XCTAssertEqual(model.followUps.first?.reserve,"$0.13")
        XCTAssertTrue(model.canReturnToResult)
        model.returnToResult()
        try await wait { model.phase == .result }
        XCTAssertEqual(service.count("api/jobs"),1)
    }
}
#endif
