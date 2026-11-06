import Foundation
@testable import TokenClock

/// Actual quota services with synthetic credentials and explicit fake proxies.
@main struct ClaudeQuotaProxyIntegrationSmoke {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { precondition(condition(), "Service assertion \(assertions + 1) failed", file: file, line: line); assertions += 1 }
        for failure in [ClaudeQuotaNetwork.Failure.proxyRequired, .requestFailed] {
            let service = ClaudeAppQuotaService(transport: { _ in .init(status:0,data:Data(),networkFailure:failure) })
            for connected in [false,true] {
                let result = service.fetch(.init(key:"SYNTHETIC-SESSION",organizationID:nil,connected:connected))
                guard case .failure(let error) = result else { fatalError("Proxy failure was accepted as quota") }
                check(error.snapshot.status == .unavailable)
                check(error.snapshot.buckets.isEmpty)
                check(!error.snapshot.requiresConnection)
                check(error.messageKey == failure.rawValue)
            }
        }
        // The OAuth path receives only a synthetic credential in a private empty home.
        // An explicitly invalid proxy prevents dispatch before any network operation.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tc-proxy-service-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let environment = ["CLAUDE_CODE_OAUTH_TOKEN":"SYNTHETIC-OAUTH", "HTTPS_PROXY":"invalid-proxy"]
        let service = ClaudeQuotaService(claudeHome:home.path,environment:environment,homeDirectory:home.path)
        let snapshot = service.fetch(connectedSession:nil,connectionSelected:false)
        check(snapshot.status == .unavailable)
        check(snapshot.buckets.isEmpty)
        check(!snapshot.requiresConnection)
        check(snapshot.message == L10n.shared.tr("quota.claudeProxyRequired"))
        // Existing read-only successful fixture remains unchanged.
        let organization = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let success = ClaudeAppQuotaService(transport: { request in
            let text: String
            switch request.url!.lastPathComponent {
            case "account": text = #"{"uuid":"fixture-account","email_address":"fixture@example.invalid"}"#
            case "organizations": text = "[{\"uuid\":\""+organization+"\",\"name\":\"Fixture\"}]"
            default: text = #"{"five_hour":{"utilization":25,"resets_at":"2026-11-01T00:00:00Z"}}"#
            }
            return .init(status:200,data:Data(text.utf8))
        })
        let completed = try success.fetch(.init(key:"SYNTHETIC-SESSION",organizationID:organization,connected:true)).get()
        check(completed.status == .available)
        check(completed.buckets.first?.remainingPercent == 75)
        print("{\"service_assertions\":\(assertions),\"model_calls\":0,\"real_credentials_used\":false}")
    }
}
