import Foundation
#if os(macOS)
import CryptoKit
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

enum ClaudeQuotaSource: String, Sendable {
    case oauthAPI
}

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
        var value = previous
        value.status = .loading
        value.message = nil
        return value
    }

    static func unavailable(_ message: String) -> ClaudeQuotaSnapshot {
        var value = Self.idle
        value.status = .unavailable
        value.refreshedAt = Date()
        value.message = message
        return value
    }

    var isStale: Bool {
        guard let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) >= AppConfig.Scan.claudeQuotaCacheSeconds
    }
}

/// Reads Claude.ai subscription windows on demand using Claude Code's existing OAuth login.
/// Credentials are kept in memory only, never logged or persisted by TokenClock. macOS uses the
/// same Keychain item as Claude Code; Windows/Linux use Claude Code's secure-storage fallback.
final class ClaudeQuotaService: @unchecked Sendable {
    struct CredentialInfo: Equatable, Sendable {
        let accessToken: String
        let subscriptionType: String?
    }

    private struct HTTPResponse: Sendable {
        let statusCode: Int
        let body: Data
    }

    #if !os(Windows)
    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HTTPResponse?

        func store(data: Data?, response: URLResponse?) {
            lock.lock()
            defer { lock.unlock() }
            guard let data, let http = response as? HTTPURLResponse else { return }
            value = HTTPResponse(statusCode: http.statusCode, body: data)
        }

        func load() -> HTTPResponse? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
    #endif

    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String
    private let claudeHome: String

    init(
        claudeHome: String = PathConfig.claudeCodeHome(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.claudeHome = claudeHome
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func fetch() -> ClaudeQuotaSnapshot {
        guard let credential = loadCredential() else {
            return .unavailable("Claude Code OAuth login was not found.")
        }
        guard let response = requestUsage(accessToken: credential.accessToken) else {
            return .unavailable("Claude quota request failed.")
        }
        guard (200..<300).contains(response.statusCode) else {
            return .unavailable("Claude quota request returned HTTP \(response.statusCode).")
        }
        return Self.decodeUsageResponse(
            response.body,
            planType: credential.subscriptionType
        ) ?? .unavailable("Claude quota response was not recognized.")
    }

    static func decodeCredentialPayload(_ data: Data) -> CredentialInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CredentialInfo(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    static func credentialCandidatePaths(
        environment: [String: String],
        homeDirectory: String,
        configuredClaudeHome: String
    ) -> [String] {
        var directories: [String] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            directories.append(configured)
        }
        if !configuredClaudeHome.isEmpty { directories.append(configuredClaudeHome) }
        directories.append((homeDirectory as NSString).appendingPathComponent(".claude"))

        var seen = Set<String>()
        return directories.compactMap { directory in
            let expanded = (directory as NSString).expandingTildeInPath
            let path = (expanded as NSString).appendingPathComponent(".credentials.json")
            return seen.insert(path).inserted ? path : nil
        }
    }

    #if os(macOS)
    /// Claude Code 2.1.x stores production OAuth credentials under
    /// `Claude Code-credentials` and the current macOS user account. Custom config directories
    /// add the same eight-character SHA-256 suffix used by Claude Code secure storage.
    static func macOSKeychainServices(
        environment: [String: String], configuredClaudeHome: String
    ) -> [String] {
        let oauthSuffix = environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"]?.isEmpty == false
            ? "-custom-oauth" : ""
        let base = "Claude Code\(oauthSuffix)-credentials"
        var services: [String] = []

        let secureOverridePresent = environment.keys.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        let secureOverride = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? ""
        let configOverride = environment["CLAUDE_CONFIG_DIR"]
        let omitsHash = secureOverridePresent ? secureOverride.isEmpty : configOverride == nil
        if !omitsHash {
            let raw = secureOverridePresent ? secureOverride : (configOverride ?? configuredClaudeHome)
            let normalized = (raw as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
            let digest = SHA256.hash(data: Data(normalized.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            services.append("\(base)-\(suffix)")
        }
        services.append(base)
        // Compatibility with Claude Code versions that predate the `-credentials` suffix.
        services.append("Claude Code")
        return services.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    static func macOSKeychainAccounts(environment: [String: String]) -> [String] {
        let allowed = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
        let candidates: [String?] = [environment["USER"], NSUserName(), "claude-code-user"]
        let valid: [String] = candidates.compactMap { candidate -> String? in
            guard let candidate, !candidate.isEmpty else { return nil }
            let range = NSRange(candidate.startIndex..., in: candidate)
            return allowed.firstMatch(in: candidate, range: range) == nil ? nil : candidate
        }
        return valid.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }
    #endif

    static func decodeUsageResponse(
        _ data: Data,
        planType: String? = nil,
        now: Date = Date()
    ) -> ClaudeQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let definitions: [(key: String, name: String, minutes: Int)] = [
            ("five_hour", "Claude", 300),
            ("seven_day", "Claude", 10_080),
            ("seven_day_opus", "Opus", 10_080),
            ("seven_day_sonnet", "Sonnet", 10_080),
            ("seven_day_oauth_apps", "Claude Apps", 10_080),
            ("seven_day_overage_included", "Extra Usage", 10_080),
        ]

        var buckets: [CodexQuotaBucket] = []
        for definition in definitions {
            guard let value = root[definition.key] as? [String: Any],
                  let used = number(value["utilization"]) else { continue }
            buckets.append(CodexQuotaBucket(
                id: "claude:\(definition.key)",
                name: definition.name,
                usedPercent: used,
                windowMinutes: definition.minutes,
                resetsAt: date(value["resets_at"])
            ))
        }
        guard !buckets.isEmpty else { return nil }
        let order = Dictionary(uniqueKeysWithValues: definitions.enumerated().map { ($0.element.key, $0.offset) })
        buckets.sort {
            let lhs = String($0.id.dropFirst("claude:".count))
            let rhs = String($1.id.dropFirst("claude:".count))
            return (order[lhs] ?? Int.max) < (order[rhs] ?? Int.max)
        }
        return ClaudeQuotaSnapshot(
            status: .available,
            buckets: buckets,
            planType: planType,
            refreshedAt: now,
            source: .oauthAPI,
            message: nil
        )
    }

    private func loadCredential() -> CredentialInfo? {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return CredentialInfo(accessToken: token, subscriptionType: nil)
        }
        for path in Self.credentialCandidatePaths(
            environment: environment,
            homeDirectory: homeDirectory,
            configuredClaudeHome: claudeHome
        ) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= 1_048_576,
                  let data = fileManager.contents(atPath: path),
                  let credential = Self.decodeCredentialPayload(data) else { continue }
            return credential
        }
        #if os(macOS)
        return loadMacOSKeychainCredential()
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private func loadMacOSKeychainCredential() -> CredentialInfo? {
        let deadline = Date().addingTimeInterval(AppConfig.Scan.claudeQuotaTimeoutSeconds)
        for service in Self.macOSKeychainServices(
            environment: environment, configuredClaudeHome: claudeHome
        ) {
            for account in Self.macOSKeychainAccounts(environment: environment) {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                if let credential = readMacOSKeychainCredential(
                    service: service, account: account, timeout: min(2, remaining)
                ) {
                    return credential
                }
            }
        }
        return nil
    }

    private func readMacOSKeychainCredential(
        service: String, account: String, timeout: TimeInterval
    ) -> CredentialInfo? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", service, "-a", account, "-w",
        ]
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Self.decodeCredentialPayload(data)
    }
    #endif

    private func requestUsage(accessToken: String) -> HTTPResponse? {
        let url = "https://api.anthropic.com/api/oauth/usage"
        let headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "TokenClock quota widget",
        ]
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(
            url: url,
            headers: headers,
            connectTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            sendTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            receiveTimeout: AppConfig.Scan.claudeQuotaTimeoutSeconds,
            maximumResponseBytes: 1_048_576
        ) else { return nil }
        return HTTPResponse(statusCode: response.statusCode, body: response.body)
        #else
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = AppConfig.Scan.claudeQuotaTimeoutSeconds
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let box = HTTPResultBox()
        let completed = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response)
            completed.signal()
        }
        task.resume()
        if completed.wait(timeout: .now() + AppConfig.Scan.claudeQuotaTimeoutSeconds) == .timedOut {
            task.cancel()
            return nil
        }
        return box.load()
        #endif
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
