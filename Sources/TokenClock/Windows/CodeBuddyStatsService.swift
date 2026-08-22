#if os(Windows)
import Foundation
import Win32Shim

/// Safe probe for CodeBuddy Code's documented public statistics endpoints.
///
/// The decoder accepts only the versioned response fields confirmed in CodeBuddy's official
/// package. It never guesses token, credit, request or cost values.
final class CodeBuddyStatsService: @unchecked Sendable {
    static let maximumResponseBytes = 1_048_576

    struct UsageSnapshot: Equatable {
        let tokens: Int
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        let modelTokens: [String: Int]
    }

    struct ProbeResult: Equatable {
        let historicalEnvelopeReadable: Bool
        let sessionStatisticsReadable: Bool
        var contractReadable: Bool { historicalEnvelopeReadable && sessionStatisticsReadable }
    }

    private enum Route: Int32 {
        case historical = 0
        case currentSession = 1
    }

    private let port: UInt16?

    init(endpoint: String) {
        port = Self.validatedLoopbackBaseURL(endpoint).map { UInt16($0.port ?? 80) }
    }

    /// Only literal IPv4 loopback is accepted. Hostnames, LAN addresses, userinfo, query strings
    /// and HTTPS are rejected before the native Winsock client sees the port.
    static func validatedLoopbackBaseURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              components.host == "127.0.0.1",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.path = ""
        return components.url
    }

    static func hasDocumentedDataEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("data"), !(object["data"] is NSNull) else { return false }
        return true
    }

    /// Strict decoder for the public SessionStatsResult shipped in the official npm artifact
    /// `@tencent-ai/codebuddy-code@2.133.1` (SHA-256
    /// `7f17fb2c253645c248500dd6c5e4e4afe152ee72435f0c25024631c96d77f13a`).
    /// The flat four fields are explicitly defined by the bundled OpenAPI schema. The same
    /// artifact's CostService implementation and the Windows runtime emit the equivalent
    /// `tokenUsageByModel` shape, so that exact shape is accepted as a versioned compatibility
    /// branch. TokenClock does not use historical `totalTokens` as today's usage, because that
    /// endpoint has lifetime scope.
    static func decodeCurrentSessionUsage(_ data: Data) -> UsageSnapshot? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = envelope["data"] as? [String: Any] else { return nil }

        if let usageByModel = body["tokenUsageByModel"] as? [String: Any] {
            var totals = (input: 0, output: 0, cacheRead: 0, cacheCreation: 0)
            var modelTokens: [String: Int] = [:]
            for (model, rawUsage) in usageByModel {
                guard !model.isEmpty, let usage = rawUsage as? [String: Any],
                      let input = nonnegativeInteger(usage["inputTokens"] as Any),
                      let output = nonnegativeInteger(usage["outputTokens"] as Any),
                      let cacheRead = nonnegativeInteger(usage["cachedReadTokens"] as Any),
                      let cacheCreation = nonnegativeInteger(usage["cachedWriteTokens"] as Any),
                      let modelTotal = checkedSum([input, cacheCreation, output]) else { return nil }
                guard let nextInput = checkedSum([totals.input, input]),
                      let nextOutput = checkedSum([totals.output, output]),
                      let nextRead = checkedSum([totals.cacheRead, cacheRead]),
                      let nextCreation = checkedSum([totals.cacheCreation, cacheCreation]) else { return nil }
                totals = (nextInput, nextOutput, nextRead, nextCreation)
                modelTokens[model] = modelTotal
            }
            guard let total = checkedSum([totals.input, totals.cacheCreation, totals.output]) else { return nil }
            return UsageSnapshot(tokens: total, input: totals.input, output: totals.output,
                                 cacheRead: totals.cacheRead, cacheCreation: totals.cacheCreation,
                                 modelTokens: modelTokens)
        }

        guard let tokenUsage = body["tokenUsage"] as? [String: Any],
              let input = nonnegativeInteger(tokenUsage["input"] as Any),
              let output = nonnegativeInteger(tokenUsage["output"] as Any),
              let cacheRead = nonnegativeInteger(tokenUsage["cacheRead"] as Any),
              let cacheCreation = nonnegativeInteger(tokenUsage["cacheCreation"] as Any) else { return nil }
        guard let total = checkedSum([input, cacheCreation, output]) else { return nil }
        return UsageSnapshot(tokens: total, input: input, output: output,
                             cacheRead: cacheRead, cacheCreation: cacheCreation, modelTokens: [:])
    }

    func probe() -> ProbeResult {
        guard port != nil else { return ProbeResult(historicalEnvelopeReadable: false, sessionStatisticsReadable: false) }
        return ProbeResult(
            historicalEnvelopeReadable: fetch(.historical).map(Self.hasDocumentedDataEnvelope) ?? false,
            sessionStatisticsReadable: fetch(.currentSession).flatMap(Self.decodeCurrentSessionUsage) != nil
        )
    }

    func currentSessionUsage() -> UsageSnapshot? {
        guard let data = fetch(.currentSession) else { return nil }
        return Self.decodeCurrentSessionUsage(data)
    }

    private func fetch(_ route: Route) -> Data? {
        guard let port else { return nil }
        var bytes = [UInt8](repeating: 0, count: Self.maximumResponseBytes)
        let length = bytes.withUnsafeMutableBufferPointer { buffer in
            win_codebuddy_http_get(
                port,
                route.rawValue,
                buffer.baseAddress,
                Int32(buffer.count),
                800
            )
        }
        guard length >= 0 else { return nil }
        return Data(bytes.prefix(Int(length)))
    }

    private static func nonnegativeInteger(_ raw: Any) -> Int? {
        if raw is Bool { return nil }
        guard let number = raw as? NSNumber else { return nil }
        guard let value = Int(number.stringValue), value >= 0 else { return nil }
        return value
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}
#endif
