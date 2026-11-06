import Foundation
#if os(macOS)
import CryptoKit
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

enum ClaudeQuotaSource: String, Sendable {
    case oauthAPI
    case desktopCache
    case desktopResponseCache
    case desktopWeb
    case connectedWeb
}

struct ClaudeQuotaSnapshot: Equatable, Sendable {
    var status: CodexQuotaStatus
    var buckets: [CodexQuotaBucket]
    var planType: String?
    var refreshedAt: Date?
    var source: ClaudeQuotaSource?
    var message: String?
    var account: SubscriptionAccountIdentity? = nil
    var requiresConnection = false
#if os(macOS)
    var verifiedIdentity: ClaudeQuotaIdentity? = nil
    var readFailure: ClaudeQuotaReadFailure? = nil
    var isCachedFallback = false
    var localAuthorizationRequired = false
#endif
    var sourceDescription: String {
#if os(macOS)
        if isCachedFallback { return L10n.shared.tr("quota.claudeSavedSource") }
        if readFailure == .identityUnknown { return L10n.shared.tr("quota.claudeUnverifiedSource") }
#endif
        switch source {
        case .desktopCache: return L10n.shared.tr("quota.claudeCacheSource")
        case .desktopResponseCache: return L10n.shared.tr("quota.claudeResponseCacheSource")
        case .desktopWeb: return L10n.shared.tr("quota.claudeAppSource")
        case .connectedWeb: return L10n.shared.tr("quota.claudeConnectedSource")
        default: return "Claude OAuth API"
        }
    }

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

/// Reads subscription windows without requiring a CLI installation. Imported App/Code
/// credentials are memory-only and silent; an explicitly connected web login is managed
/// in an isolated WebKit profile. No cloud token estimates are produced.
final class ClaudeQuotaService: @unchecked Sendable {
    struct CredentialInfo: Equatable, Sendable {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    struct AccountProfile: Equatable, Sendable {
        let id: String
        let email: String?
        let rateLimitTier: String?
    }

    struct HTTPResponse: Sendable {
        let statusCode: Int
        let body: Data
        var networkFailureKey: String? = nil
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

    typealias OAuthTransport = @Sendable (ProviderHTTPRequest) -> HTTPResponse?
    #if os(macOS)
    private let appPasswordCache = ClaudeAppPasswordCache()
    #endif
    private let oauthTransport: OAuthTransport?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String
    private let overrideHome: String?
    private var claudeHome: String { overrideHome ?? PathConfig.claudeCodeHome() }
    private let desktopHomes: [String]

    init(
        claudeHome: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        oauthTransport: OAuthTransport? = nil
    ) {
        self.oauthTransport = oauthTransport
        self.overrideHome = claudeHome
        self.desktopHomes = ClaudeDesktopData.homes(home: homeDirectory, environment: environment)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func fetch(now: Date = Date()) -> ClaudeQuotaSnapshot {
#if os(macOS)
        return fetch(connectedSession: nil, connectionSelected: false, now: now)
#else
        let desktop = ClaudeDesktopData.quota(in: desktopHomes, fileManager: fileManager, now: now)
        if let desktop { return desktop }
        // A fresh Desktop receipt is usable without probing another app's
        // Keychain ACL. File/env OAuth is still preferred when present.
        guard let credential = loadCredential(allowKeychain: desktop == nil) else {
            if let desktop { return desktop }
            return .unavailable("Claude Code OAuth login was not found.")
        }
        guard let response = requestUsage(accessToken: credential.accessToken) else {
            if let desktop { return desktop }
            return .unavailable("Claude quota request failed.")
        }
        if let messageKey = response.networkFailureKey { return .unavailable(L10n.shared.tr(messageKey)) }
        guard (200..<300).contains(response.statusCode) else {
            if let desktop { return desktop }
            return .unavailable("Claude quota request returned HTTP \(response.statusCode).")
        }
        var snapshot = Self.decodeUsageResponse(
            response.body,
            planType: Self.detailedPlan(
                subscriptionType: credential.subscriptionType,
                rateLimitTier: credential.rateLimitTier
            )
        ) ?? .unavailable("Claude quota response was not recognized.")
        if snapshot.status != .available, let desktop { return desktop }
        if snapshot.status == .available {
            let profile = loadAccountProfile()
            snapshot.account = SubscriptionAccountIdentity(
                id: profile?.id ?? profile?.email?.lowercased()
                    ?? SubscriptionAccountIdentity.opaqueID(namespace: "claude", secret: credential.accessToken),
                email: profile?.email
            )
            if snapshot.planType?.isEmpty != false,
               let tier = profile?.rateLimitTier {
                snapshot.planType = Self.detailedPlan(subscriptionType: nil, rateLimitTier: tier)
            }
        }
        return snapshot
#endif
    }

    #if os(macOS)
    func fetch(connectedSession: ClaudeAppSession?, connectionSelected: Bool,
               expectedIdentity: String? = nil, previous: ClaudeQuotaSnapshot? = nil,
               userInitiatedCredentialAccess: Bool = false, now: Date = Date()) -> ClaudeQuotaSnapshot {
        var cached = ClaudeDesktopData.quota(in: desktopHomes, fileManager: fileManager, now: now)
        let owner = ClaudeQuotaIdentity(key: expectedIdentity ?? connectedSession?.expectedIdentity)
        let mayUseUnpinnedAppCache = !connectionSelected && owner == nil && previous?.verifiedIdentity == nil
            && (previous?.buckets.isEmpty != false || previous?.source == .desktopCache || previous?.source == .desktopResponseCache)
        if mayUseUnpinnedAppCache, let cached { return cached }
        var needsVerifiedFallback = owner != nil || previous?.verifiedIdentity != nil
        var fallbackOwner = owner ?? previous?.verifiedIdentity ?? ClaudeQuotaIdentity(key:previous?.account?.id)
        var authorizationRequired = false, cancelled = false, usedCachedAppKey = false
        let readLocal: (String,String) -> Data? = { service, account in
            guard !cancelled else { return nil }
            let value: ClaudeLocalCredentialAccess.Result
            if service == "Claude Safe Storage", account == "Claude Key" {
                let cached = self.appPasswordCache.read {
                    ClaudeLocalCredentialAccess.read(service:service,account:account,userInitiated:userInitiatedCredentialAccess)
                }
                value = cached.result; usedCachedAppKey = usedCachedAppKey || cached.cached
            } else {
                value = ClaudeLocalCredentialAccess.read(service:service,account:account,userInitiated:userInitiatedCredentialAccess)
            }
            authorizationRequired = authorizationRequired || value.authorizationRequired
            cancelled = cancelled || value.cancelled
            return value.data
        }
        var result = ClaudeQuotaReadPolicy.resolve(selectedWeb: connectionSelected, expected: owner, previous: previous,
            connected: {
                guard let session = connectedSession else {return ClaudeQuotaReadPolicy.failure(.noCredential,key:"quota.claudePassiveUnavailable",source:.connectedWeb)}
                let result = self.appQuota(session)
                if owner == nil, let verified = result.verifiedIdentity { fallbackOwner = verified }
                return result
            }, desktop: {
                let readApp = { ClaudeAppCookieReader.read(homes: self.desktopHomes,password: {readLocal("Claude Safe Storage","Claude Key").flatMap {String(data:$0,encoding:.utf8)}}) }
                var appSession = readApp()
                if appSession == nil && usedCachedAppKey {
                    self.appPasswordCache.invalidate(); usedCachedAppKey = false
                    appSession = readApp() // One fresh read handles a rotated App encryption key.
                }
                guard var session = appSession else {
                    if !connectionSelected && previous?.source == .oauthAPI { fallbackOwner = nil }
                    return ClaudeQuotaReadPolicy.failure(authorizationRequired ? .localAuthorization : .noCredential,key:authorizationRequired ? "quota.claudeLocalAuthorizationRequired":"quota.claudePassiveUnavailable",source:.desktopWeb)
                }
                if let organization = session.organizationID {
                    let selectedCache = ClaudeDesktopData.quota(in: self.desktopHomes, fileManager: self.fileManager, now: now, organizationID: organization)
                    if let selectedCache, (cached?.refreshedAt ?? .distantPast) < (selectedCache.refreshedAt ?? .distantPast) { cached = selectedCache }
                    if mayUseUnpinnedAppCache, let selectedCache { return selectedCache }
                }
                if connectionSelected { session.expectedIdentity = fallbackOwner?.key }
                let result = self.appQuota(session)
                if let verified = result.verifiedIdentity, result.status != .available {
                    needsVerifiedFallback = true; fallbackOwner = verified
                }
                return result
            }, oauth: {
                return self.oauthQuota(previous: previous, allowKeychain: cached == nil || needsVerifiedFallback, expected: fallbackOwner,
                                       keychainReader:readLocal,authorizationRequired:{authorizationRequired})
            }, cache: { cached }, now: now)
        result.localAuthorizationRequired = authorizationRequired && (result.status == .unavailable || result.isCachedFallback)
        if result.localAuthorizationRequired {
            if result.readFailure == .noCredential || result.readFailure == .localAuthorization {
                result.message=L10n.shared.tr("quota.claudeLocalAuthorizationRequired")
                result.requiresConnection=false
            }
        }
        return result
    }

    private func appQuota(_ session: ClaudeAppSession) -> ClaudeQuotaSnapshot {
        var verified: ClaudeQuotaIdentity?
        switch ClaudeAppQuotaService().fetch(session, onVerifiedIdentity: { verified = $0 }) {
        case .success(let snapshot): return snapshot
        case .failure(let error):
            var value = error.snapshot; value.verifiedIdentity = verified
            return value
        }
    }

    private func oauthQuota(previous: ClaudeQuotaSnapshot?, allowKeychain: Bool, expected: ClaudeQuotaIdentity?,
                            keychainReader: @escaping (String,String) -> Data?, authorizationRequired: () -> Bool) -> ClaudeQuotaSnapshot {
        guard let credential = loadCredential(allowKeychain: allowKeychain,keychainReader:keychainReader) else {
            return ClaudeQuotaReadPolicy.failure(authorizationRequired() ? .localAuthorization:.noCredential,
                                                key:authorizationRequired() ? "quota.claudeLocalAuthorizationRequired":"quota.claudePassiveUnavailable",source:.oauthAPI)
        }
        let profileReply = requestOAuth(path: "profile", accessToken: credential.accessToken)
        if profileReply?.statusCode == 429 {return ClaudeQuotaReadPolicy.failure(.rateLimited,key:"quota.claudeRateLimited",source:.oauthAPI)}
        if profileReply?.statusCode == 401 {return ClaudeQuotaReadPolicy.failure(.authentication,key:"quota.claudePassiveUnavailable",source:.oauthAPI)}
        if let key=profileReply?.networkFailureKey {return ClaudeQuotaReadPolicy.failure(.network,key:key,source:.oauthAPI)}
        let profile = profileReply.flatMap { $0.statusCode == 200 ? Self.decodeOAuthProfile($0.body) : nil }
        if let expected {
            guard let profile else {return ClaudeQuotaReadPolicy.failure(.identityUnknown,key:"quota.claudeIdentityUnknown",source:.oauthAPI)}
            guard profile.identity == expected else {return ClaudeQuotaReadPolicy.failure(.wrongAccount,key:"quota.claudeAccountMismatch",source:.oauthAPI)}
        }
        guard let response = requestUsage(accessToken: credential.accessToken) else {
            return ClaudeQuotaReadPolicy.failure(.network,key:"quota.claudeNetworkError",source:.oauthAPI)
        }
        if let key = response.networkFailureKey {return ClaudeQuotaReadPolicy.failure(.network,key:key,source:.oauthAPI)}
        if response.statusCode == 429 {return ClaudeQuotaReadPolicy.failure(.rateLimited,key:"quota.claudeRateLimited",source:.oauthAPI)}
        if response.statusCode == 401 {return ClaudeQuotaReadPolicy.failure(.authentication,key:"quota.claudePassiveUnavailable",source:.oauthAPI)}
        if response.statusCode == 403 {return ClaudeQuotaReadPolicy.failure(.permission,key:"quota.claudePermissionDenied",source:.oauthAPI)}
        guard (200..<300).contains(response.statusCode),response.body.count<=1_048_576,
              var snapshot = Self.decodeUsageResponse(response.body,planType:Self.detailedPlan(subscriptionType:credential.subscriptionType,rateLimitTier:credential.rateLimitTier)),
              snapshot.status == .available else {
            return ClaudeQuotaReadPolicy.failure(.malformed,key:"quota.claudeInvalidResponse",source:.oauthAPI)
        }
        // Use the server profile rather than a possibly stale local account file.
        if let parsed = profile {
            snapshot.verifiedIdentity=parsed.identity
            snapshot.account=SubscriptionAccountIdentity(id:parsed.identity.key,email:parsed.email)
            if let plan=parsed.planType {snapshot.planType=plan}
            if let previous,previous.verifiedIdentity == parsed.identity,let account=previous.account {
                snapshot.account=SubscriptionAccountIdentity(id:account.id,email:parsed.email ?? account.email)
            }
        } else {
            // A usage-only result is real, but must not be attributed to a
            // different saved account using unverified local profile metadata.
            snapshot.account=SubscriptionAccountIdentity(id:SubscriptionAccountIdentity.opaqueID(namespace:"claude-oauth",secret:credential.accessToken),email:nil)
            snapshot.message=L10n.shared.tr("quota.claudeIdentityUnknown")
            snapshot.readFailure = .identityUnknown
        }
        return snapshot
    }

    struct OAuthProfile: Equatable, Sendable {
        let identity: ClaudeQuotaIdentity
        let email: String?
        let planType: String?
    }
    static func decodeOAuthProfile(_ data: Data) -> OAuthProfile? {
        guard data.count<=1_048_576,let root=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let account=root["account"] as? [String:Any],let org=root["organization"] as? [String:Any],
              let accountID=account["uuid"] as? String,UUID(uuidString:accountID) != nil,
              let orgID=org["uuid"] as? String,UUID(uuidString:orgID) != nil else {return nil}
        let rawEmail=(account["email"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines)
        let type=(org["organization_type"] as? String)?.replacingOccurrences(of:"claude_",with:"")
        return OAuthProfile(identity: .init(accountID:accountID,organizationID:orgID),email:rawEmail?.isEmpty == false ? rawEmail:nil,
                            planType:detailedPlan(subscriptionType:type,rateLimitTier:org["rate_limit_tier"] as? String))
    }
    #endif

    static func decodeCredentialPayload(_ data: Data) -> CredentialInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CredentialInfo(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    static func detailedPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("max_20x") || tier.contains("max-20x") { return "max_20x" }
        if tier.contains("max_5x") || tier.contains("max-5x") { return "max_5x" }
        return subscriptionType
    }

    static func decodeAccountProfile(_ data: Data) -> AccountProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        let email = (account["emailAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawID = (account["accountUuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = rawID?.isEmpty == false ? rawID! : (email?.lowercased() ?? "claude-active")
        return AccountProfile(
            id: id,
            email: email?.isEmpty == false ? email : nil,
            rateLimitTier: account["userRateLimitTier"] as? String
                ?? account["organizationRateLimitTier"] as? String
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
        environment: [String: String], configuredClaudeHome: String,
        defaultClaudeHome: String = NSHomeDirectory() + "/.claude"
    ) -> [String] {
        let oauthSuffix = environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"]?.isEmpty == false
            ? "-custom-oauth" : ""
        let base = "Claude Code\(oauthSuffix)-credentials"
        var services: [String] = []

        let secureOverridePresent = environment.keys.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        let secureOverride = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? ""
        let configOverride = environment["CLAUDE_CONFIG_DIR"]
        let normalize: (String) -> String = { ($0 as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping }
        let customConfiguredHome = normalize(configuredClaudeHome) != normalize(defaultClaudeHome)
        let omitsHash = secureOverridePresent ? secureOverride.isEmpty : (configOverride == nil && !customConfiguredHome)
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

    private func loadCredential(allowKeychain: Bool = true, keychainReader: ((String,String) -> Data?)? = nil) -> CredentialInfo? {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return CredentialInfo(accessToken: token, subscriptionType: nil, rateLimitTier: nil)
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
        return allowKeychain ? loadMacOSKeychainCredential(reader:keychainReader) : nil
        #else
        return nil
        #endif
    }

    private func loadAccountProfile() -> AccountProfile? {
        let candidates = [
            (homeDirectory as NSString).appendingPathComponent(".claude.json"),
            claudeHome + ".json",
        ]
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            guard let data = fileManager.contents(atPath: path),
                  let profile = Self.decodeAccountProfile(data) else { continue }
            return profile
        }
        return nil
    }

    #if os(macOS)
    private func loadMacOSKeychainCredential(reader: ((String,String) -> Data?)? = nil) -> CredentialInfo? {
        let deadline = Date().addingTimeInterval(AppConfig.Scan.claudeQuotaTimeoutSeconds)
        for service in Self.macOSKeychainServices(
            environment: environment, configuredClaudeHome: claudeHome
        ) {
            for account in Self.macOSKeychainAccounts(environment: environment) {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                if let credential = readMacOSKeychainCredential(
                    service: service, account: account, timeout: min(2, remaining), reader: reader
                ) {
                    return credential
                }
            }
        }
        return nil
    }

    private func readMacOSKeychainCredential(
        service: String, account: String, timeout: TimeInterval, reader: ((String,String) -> Data?)? = nil
    ) -> CredentialInfo? {
        let bytes = reader.map { $0(service,account) } ?? ClaudeSilentKeychain.read(service:service,account:account)
        guard let data = bytes else { return nil }
        return Self.decodeCredentialPayload(data)
    }
    #endif

    private func requestUsage(accessToken: String) -> HTTPResponse? {
        requestOAuth(path: "usage", accessToken: accessToken)
    }

    private func requestOAuth(path: String, accessToken: String) -> HTTPResponse? {
        guard ["usage", "profile"].contains(path) else {return nil}
        let url = "https://api.anthropic.com/api/oauth/" + path
        let headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "TokenClock quota widget",
        ]
        if let oauthTransport,let endpoint=URL(string:url) {
            var request=ProviderHTTPRequest(url:endpoint);request.httpMethod="GET"
            request.httpShouldHandleCookies=false
            for (name,value) in headers {request.setValue(value,forHTTPHeaderField:name)}
            return oauthTransport(request)
        }
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
        #elseif os(macOS)
        guard let endpoint = URL(string: url) else { return nil }
        var request = ProviderHTTPRequest(url: endpoint)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = AppConfig.Scan.claudeQuotaTimeoutSeconds
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        switch ClaudeQuotaNetwork.get(request, claudeHome: claudeHome, environment: environment) {
        case .success(let result): return HTTPResponse(statusCode: result.status, body: result.data)
        case .failure(let failure): return HTTPResponse(statusCode: 0, body: Data(), networkFailureKey: failure.rawValue)
        }
        #else
        guard let endpoint = URL(string: url) else { return nil }
        var request = ProviderHTTPRequest(url: endpoint)
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
