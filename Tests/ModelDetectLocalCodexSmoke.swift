// Standalone offline native-state check for hosts without Xcode's XCTest framework.
import Foundation
@testable import TokenClock

@MainActor private final class FakeLocalService: ModelDetectNativeServing {
    var calls: [(String, ModelDetectJSON?)] = []
    var previewCount = 3
    let id = "job-" + String(repeating: "a", count: 32)
    func request(_ route: String, body: ModelDetectJSON?) async throws -> ModelDetectJSON {
        calls.append((route, body))
        switch route {
        case "api/local-codex":
            return .object(["schema": .string("tokenclock-codex-local/v1"), "binding": .string("fixture-account"),
                "selected_model": .string("test-model"), "models": .array([.object(["id": .string("test-model")])])])
        case "api/preview":
            return .object(["valid": .bool(true), "billing_mode": .string("codex_account"), "local_only": .bool(false),
                "roles": .array([.object(["role": .string("target")])]), "limits": .object(["requests": .number(Double(previewCount))])])
        case "api/jobs": return body == nil ? .object(["jobs": .array([])]) : .object(["id": .string(id), "status": .string("running")])
        default: return .object(["id": .string(id), "status": .string("running")])
        }
    }
    func download(_ route: String) async throws -> Data { Data() }
    var submits: [ModelDetectJSON] { calls.filter { $0.0 == "api/jobs" }.compactMap(\.1) }
}

@main struct LocalCodexSmoke {
    @MainActor static func main() async throws {
        let service = FakeLocalService()
        let model = ModelDetectNativeModel(service: service, starter: { _ in fatalError("No real worker allowed") })
        model.mode = .codex
        precondition(!model.canPrepare)
        await model.refreshLocalCodexNow()
        precondition(service.submits.isEmpty)
        precondition(model.localCodexModel == "test-model")
        precondition(model.canPrepare)
        let config = try model.configuration(secrets: true, authorized: true)
        precondition(config["workflow_mode"].string == "codex")
        precondition(config["provider"]["api_key"].string == nil)
        precondition(config["codex"]["binding"].string == "fixture-account")
        model.localCodexModel = "not-in-catalog"
        precondition(!model.canPrepare)
        model.localCodexModel = "test-model"
        service.previewCount = 9
        await model.prepareNow()
        precondition(service.submits.isEmpty)
        precondition(model.errorMessage != nil)
        service.previewCount = 3
        await model.prepareNow()
        precondition(service.submits.count == 1)
        precondition(service.submits[0]["allow_external"].bool == true)
        precondition(service.submits[0]["source_path"].string == nil)
        precondition(service.submits[0]["semantic_config"]["codex"]["model"].string == "test-model")
        precondition(model.phase == .running)
        await model.prepareNow()
        precondition(service.submits.count == 1)
        model.phase = .result; model.newDetection()
        let report: ModelDetectJSON = .object(["workflow_mode": .string("codex"), "result": .object([:]),
            "user_summary": .object(["brief": .object(["status": .string("insufficient_evidence"),
                "title": .string("暂不能确认型号"), "summary": .string("已保存本机回答。"),
                "display": .object(["schema": .string("tokenclock-human-result/v1"), "title": .string("暂不能确认型号"), "tone": .string("limited")])])])])
        let presentation = ModelDetectResultPresentation(report: report)
        precondition(presentation.title == "暂不能确认型号")
        precondition(presentation.tone == .limited)
        print("Native Codex smoke: 18 assertions passed; no model calls or real credentials.")
    }
}
