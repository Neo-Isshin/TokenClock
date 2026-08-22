#if os(Windows)
import Foundation

enum ClaudeQuotaSource: String, Sendable { case oauthAPI }

struct ClaudeQuotaSnapshot: Equatable, Sendable {
    var status: CodexQuotaStatus
    var buckets: [CodexQuotaBucket]
    var planType: String?
    var refreshedAt: Date?
    var source: ClaudeQuotaSource?
    var message: String?
    static let idle = ClaudeQuotaSnapshot(
        status: .idle, buckets: [], planType: nil, refreshedAt: nil, source: nil, message: nil
    )
    static func loading(previous: ClaudeQuotaSnapshot) -> ClaudeQuotaSnapshot {
        var value = previous; value.status = .loading; value.message = nil; return value
    }
    static func unavailable(_ message: String) -> ClaudeQuotaSnapshot {
        var value = Self.idle; value.status = .unavailable; value.refreshedAt = Date()
        value.message = message; return value
    }
    var isStale: Bool {
        guard let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) >= AppConfig.Scan.claudeQuotaCacheSeconds
    }
}

final class ClaudeQuotaService: @unchecked Sendable {
    struct CredentialInfo: Equatable, Sendable { let accessToken: String; let subscriptionType: String? }
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String
    private let claudeHome: String
    init(
        claudeHome: String = PathConfig.claudeCodeHome(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(), fileManager: FileManager = .default
    ) {
        self.claudeHome = claudeHome; self.environment = environment
        self.homeDirectory = homeDirectory; self.fileManager = fileManager
    }

    func fetch() -> ClaudeQuotaSnapshot {
        guard let credential = loadCredential() else { return .unavailable("Claude Code OAuth login was not found.") }
        let headers = [
            "Accept": "application/json", "Authorization": "Bearer \(credential.accessToken)",
            "anthropic-beta": "oauth-2025-04-20", "User-Agent": "TokenClock quota widget",
        ]
        guard let response = try? WindowsNativeHTTP.request(
            url: "https://api.anthropic.com/api/oauth/usage", headers: headers,
            connectTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            sendTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            receiveTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            maximumResponseBytes: 1_048_576
        ), (200..<300).contains(response.statusCode) else {
            return .unavailable("Claude quota request failed.")
        }
        return Self.decodeUsageResponse(response.body, planType: credential.subscriptionType)
            ?? .unavailable("Claude quota response was not recognized.")
    }

    static func decodeCredentialPayload(_ data: Data) -> CredentialInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return CredentialInfo(accessToken: token, subscriptionType: oauth["subscriptionType"] as? String)
    }

    static func credentialCandidatePaths(
        environment: [String: String], homeDirectory: String, configuredClaudeHome: String
    ) -> [String] {
        var directories: [String] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty { directories.append(configured) }
        if !configuredClaudeHome.isEmpty { directories.append(configuredClaudeHome) }
        directories.append((homeDirectory as NSString).appendingPathComponent(".claude"))
        var seen = Set<String>()
        return directories.compactMap {
            let path = (((($0 as NSString).expandingTildeInPath) as NSString).appendingPathComponent(".credentials.json"))
            return seen.insert(path).inserted ? path : nil
        }
    }

    static func decodeUsageResponse(
        _ data: Data, planType: String? = nil, now: Date = Date()
    ) -> ClaudeQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let definitions: [(String, String, Int)] = [
            ("five_hour", "Claude", 300), ("seven_day", "Claude", 10_080),
            ("seven_day_opus", "Opus", 10_080), ("seven_day_sonnet", "Sonnet", 10_080),
            ("seven_day_oauth_apps", "Claude Apps", 10_080),
            ("seven_day_overage_included", "Extra Usage", 10_080),
        ]
        var buckets: [CodexQuotaBucket] = []
        for (key, name, minutes) in definitions {
            guard let value = root[key] as? [String: Any], let used = number(value["utilization"]) else { continue }
            buckets.append(CodexQuotaBucket(
                id: "claude:\(key)", name: name, usedPercent: used,
                windowMinutes: minutes, resetsAt: date(value["resets_at"])
            ))
        }
        guard !buckets.isEmpty else { return nil }
        return ClaudeQuotaSnapshot(
            status: .available, buckets: buckets, planType: planType,
            refreshedAt: now, source: .oauthAPI, message: nil
        )
    }

    private func loadCredential() -> CredentialInfo? {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return CredentialInfo(accessToken: token, subscriptionType: nil)
        }
        for path in Self.credentialCandidatePaths(
            environment: environment, homeDirectory: homeDirectory, configuredClaudeHome: claudeHome
        ) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
                  let data = fileManager.contents(atPath: path),
                  let credential = Self.decodeCredentialPayload(data) else { continue }
            return credential
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        if let text = value as? String { return DateHelper.parseISO8601(text) }
        return nil
    }
}
#endif
