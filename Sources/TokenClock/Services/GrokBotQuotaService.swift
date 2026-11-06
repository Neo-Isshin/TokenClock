import Foundation
#if os(Windows) || os(Linux)
import CSQLite
#else
import SQLite3
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

/// Reads Grok Bot's separate weekly allowance from Cursor's Sand dashboard service.
///
/// Grok Bot is metered on the signed-in Cursor account. Cursor Agent CLI credentials are tried
/// first, followed by Cursor IDE, then a previously authorized standalone Grok Bot credential.
/// Automatic refresh never presents Keychain UI; native authorization is user-initiated.
final class GrokBotQuotaService: @unchecked Sendable {
    private static let source = "Cursor Grok Bot API"
    private static let endpoint =
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private enum CredentialOrigin {
        case cli
        case ide
        case grokBot

        var sourceLabel: String {
            switch self {
            case .cli: return "Cursor Agent CLI"
            case .ide: return "Cursor IDE"
            case .grokBot: return "Grok Bot"
            }
        }
    }

    private struct Credential {
        let token: String
        let userID: String
        let email: String?
        let machineID: String?
        let membershipType: String?
        let origin: CredentialOrigin
    }

    private let fileManager: FileManager
    private let stateDatabasePath: String
    private let environment: [String: String]
    private let homeDirectory: String
    struct HTTPResponse: Sendable {
        let statusCode: Int
        let data: Data
    }
    typealias Transport = @Sendable (ProviderHTTPRequest) -> HTTPResponse?
    private let transport: Transport?
    typealias CursorCredentialReader = @Sendable (Bool) -> GrokBotNativeCredentialStore.PasswordReadResult
    private let cursorCredentialReader: CursorCredentialReader
    private let cursorReaderInjected: Bool
    private let credentialLock = NSLock()
    private var authorizedCLIToken: String?
    private var authorizedCLIIdentityMetadata: Data?
    private let nativeCredentialStore: GrokBotNativeCredentialStore

    init(
        fileManager: FileManager = .default,
        stateDatabasePath: String = AppPaths.appSupport(
            "Cursor", "User", "globalStorage", "state.vscdb"
        ),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        nativeCredentialStore: GrokBotNativeCredentialStore = .shared,
        transport: Transport? = nil,
        cursorCredentialReader: CursorCredentialReader? = nil
    ) {
        self.fileManager = fileManager
        self.stateDatabasePath = stateDatabasePath
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.nativeCredentialStore = nativeCredentialStore
        self.transport = transport
        self.cursorReaderInjected = cursorCredentialReader != nil
        self.cursorCredentialReader = cursorCredentialReader ?? { GrokBotNativeCredentialStore.readCursorToken(allowInteraction: $0) }
    }

    func fetch() -> ProviderQuotaSnapshot {
        guard UserDefaults.standard.bool(for: .cursorCloudFetchEnabled, default: true) else {
            return failure("quota.grokBotCloudDisabled")
        }
        // Native secrets are a lazy fallback: a working Cursor login never
        // probes a second app's protected key, and a network failure is not a grant failure.
        let candidates = credentialCandidates()
        for credential in candidates.values {
            let response = request(credential: credential)
            if response?.statusCode == 401, credential.origin == .cli {
                credentialLock.withLock { if authorizedCLIToken == credential.token { authorizedCLIToken = nil; authorizedCLIIdentityMetadata = nil } }
            }
            guard nativeCredentialStore.acceptsCursorToken(credential.token) else { return failure("quota.grokBotAccountChanged") }
            if let result = snapshot(response, credential: credential) { return result }
            if let response, response.statusCode == 429 { return failure("quota.grokBotRateLimited") }
            if response == nil || (response?.statusCode ?? 0) >= 500 { return failure("quota.grokBotNetworkFailed") }
            if let response, response.statusCode == 200 {
                return failure(Self.hasNoIncludedAllowance(response.data) ? "quota.grokBotNoIncludedAllowance" : "quota.grokBotResponseInvalid")
            }
            if let status = response?.statusCode, ![401, 403, 404].contains(status) {
                return failure(status < 400 ? "quota.grokBotNetworkFailed" : "quota.grokBotResponseInvalid")
            }
        }
        if candidates.cursorAuthorizationRequired && !nativeCredentialStore.hasSignedInInstance {
            var result = failure("quota.grokBotCursorAuthorizationBody")
            result.requiresLocalAuthorization = true
            result.localAuthorizationSource = .cursorCLI
            return result
        }
        guard let native = nativeCredentialStore.currentCredential else {
            var result = failure(nativeCredentialStore.failureMessageKey ?? "quota.grokBotLoginUnavailable")
            result.requiresLocalAuthorization = nativeCredentialStore.accessState == .authorizationRequired
            if result.requiresLocalAuthorization { result.localAuthorizationSource = .grokBot }
            return result
        }
        let credential = Credential(token: native.accessToken, userID: native.userID,
            email: native.email, machineID: native.machineID, membershipType: nil, origin: .grokBot)
        let response = request(credential: credential)
        // An in-flight result from the previous App account must not become the
        // current account's quota after the user signs out or switches accounts.
        guard nativeCredentialStore.currentCredential?.userID == credential.userID else {
            return failure("quota.grokBotAccountChanged")
        }
        if let result = snapshot(response, credential: credential) { return result }
        if response?.statusCode == 429 { return failure("quota.grokBotRateLimited") }
        if [401, 403].contains(response?.statusCode ?? 0) { return failure("quota.grokBotLoginRejected") }
        if let response, response.statusCode == 200 {
            return failure(Self.hasNoIncludedAllowance(response.data) ? "quota.grokBotNoIncludedAllowance" : "quota.grokBotResponseInvalid")
        }
        return failure("quota.grokBotNetworkFailed")
    }

    /// Called only by the explicit local-access button when Cursor CLI is the
    /// existing credential source. "Allow once" is useful for this process too.
    func authorizeCursorCLI() -> Bool {
        let identity = cliIdentityMetadata()
        return credentialLock.withLock {
            if authorizedCLIToken != nil, authorizedCLIIdentityMetadata == identity { return true }
            let result = cursorCredentialReader(true)
            guard let token = result.password, CursorQuotaService.userID(from: token) != nil else { return false }
            authorizedCLIToken = token
            authorizedCLIIdentityMetadata = identity
            return true
        }
    }

    private func failure(_ key: String) -> ProviderQuotaSnapshot {
        .unavailable(L10n.shared.tr(key), source: Self.source)
    }

    private func snapshot(_ response: HTTPResponse?, credential: Credential) -> ProviderQuotaSnapshot? {
        guard let response, response.statusCode == 200,
              var result = Self.decodeResponse(response.data) else { return nil }
        result.account = SubscriptionAccountIdentity(id: credential.userID, email: credential.email)
        if XSubscriptionQuota.contains(result.groups) {
            result.source += " · \(credential.origin.sourceLabel)"
        } else {
            if result.planType == nil { result.planType = credential.membershipType }
            result.source = "\(Self.source) · \(credential.origin.sourceLabel)"
        }
        return result
    }

    static func decodeResponse(_ data: Data, now: Date = Date()) -> ProviderQuotaSnapshot? {
        if XSubscriptionQuota.flag(XSubscriptionQuota.object(data)?["isUnified"]) == true {
            return XSubscriptionQuota.decodeSand(data, now: now)
        }
        guard !hasNoIncludedAllowance(data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usedPercent = number(root["usagePercent"]) else { return nil }
        let reset = date(root["nextResetTimestampUtc"])
        let start = date(root["currentPeriodStart"])
        let minutes = start.flatMap { start in
            reset.map { max(0, Int($0.timeIntervalSince(start) / 60)) }
        } ?? 10_080
        let bucket = CodexQuotaBucket(
            id: "grok-bot:weekly",
            name: "Grok Bot",
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: minutes,
            resetsAt: reset
        )
        return ProviderQuotaSnapshot(
            status: .available,
            groups: [ProviderQuotaGroup(
                id: "grok-bot:plan", name: "Subscription", buckets: [bucket]
            )],
            planType: informativePlan(root["grokPlanLabel"] as? String),
            refreshedAt: now,
            source: source,
            message: nil
        )
    }

    private static func hasNoIncludedAllowance(_ data: Data) -> Bool {
        guard let root = XSubscriptionQuota.object(data), XSubscriptionQuota.flag(root["isUnified"]) != true else { return false }
        return XSubscriptionQuota.flag(root["hasNonZeroIncludedLimit"]) == false
            && XSubscriptionQuota.flag(root["hasAvailableUsage"]) == false
            && number(root["usagePercent"]) == 0
    }

    /// Reproduces the checksum generated by Grok Bot's current Sand client.
    /// The prefix is time-bounded; the stable machine identifier is read from
    /// Cursor's ordinary state database rather than any protected keychain item.
    static func cursorChecksum(machineID: String, now: Date = Date()) -> String {
        let tick = UInt64(max(0, floor(now.timeIntervalSince1970 / 1_000)))
        var bytes = stride(from: 5, through: 0, by: -1).map {
            UInt8(truncatingIfNeeded: tick >> UInt64($0 * 8))
        }
        var seed: UInt8 = 165
        for index in bytes.indices {
            let transformed = UInt16(bytes[index] ^ seed) + UInt16(index)
            bytes[index] = UInt8(truncatingIfNeeded: transformed)
            seed = bytes[index]
        }
        let prefix = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + machineID
    }

    private func credentialCandidates() -> (values: [Credential], cursorAuthorizationRequired: Bool) {
        var values: [Credential] = []
        var cursorAuthorizationRequired = false
        if environment["TOKENCLOCK_DISABLE_CURSOR_CREDENTIALS"] != "1" {
            if let cli = credentialFromCLI(onDenied: { cursorAuthorizationRequired = $0 }), nativeCredentialStore.acceptsCursorToken(cli.token) { values.append(cli) }
            if let ide = credentialFromIDE(), nativeCredentialStore.acceptsCursorToken(ide.token),
               !values.contains(where: { $0.token == ide.token }) {
                values.append(ide)
            }
        }
        return (values, cursorAuthorizationRequired)
    }

    private func credentialFromCLI(onDenied: (Bool) -> Void) -> Credential? {
        var token = Self.nonEmpty(environment["CURSOR_AUTH_TOKEN"]) ?? cliAccessTokenFromFile()
        if token == nil {
            let identity = cliIdentityMetadata()
            let read = macOSCLIKeychainAccessToken()
            token = credentialLock.withLock {
                if let value = read.password {
                    authorizedCLIToken = value; authorizedCLIIdentityMetadata = identity
                    return value
                }
                if read.authorizationRequired, authorizedCLIIdentityMetadata == identity { return authorizedCLIToken }
                authorizedCLIToken = nil; authorizedCLIIdentityMetadata = nil // Removed/unavailable source, never a stale-account fallback.
                return nil
            }
            onDenied(token == nil && read.authorizationRequired)
        }
        guard let token, let userID = CursorQuotaService.userID(from: token) else { return nil }
        let metadata = cliMetadata()
        return Credential(
            token: token,
            userID: userID,
            email: metadata.email,
            machineID: nil,
            membershipType: metadata.membershipType,
            origin: .cli
        )
    }

    private func credentialFromIDE() -> Credential? {
        guard fileManager.fileExists(atPath: stateDatabasePath) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(stateDatabasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(database) }
        guard let token = itemValue(database: database, key: "cursorAuth/accessToken"),
              let userID = CursorQuotaService.userID(from: token),
              let machineID = itemValue(database: database, key: "storage.serviceMachineId") else {
            return nil
        }
        return Credential(
            token: token,
            userID: userID,
            email: itemValue(database: database, key: "cursorAuth/cachedEmail"),
            machineID: machineID,
            membershipType: itemValue(database: database, key: "cursorAuth/stripeMembershipType"),
            origin: .ide
        )
    }

    static func decodeCLIAuthFile(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmpty((root["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cliAccessTokenFromFile() -> String? {
        let path: String
        #if os(Windows)
        let appData = environment["APPDATA"] ?? homeDirectory + "\\AppData\\Roaming"
        path = appData + "\\Cursor\\auth.json"
        #elseif os(macOS)
        path = homeDirectory + "/.cursor/auth.json"
        #else
        let config = environment["XDG_CONFIG_HOME"] ?? homeDirectory + "/.config"
        path = config + "/cursor/auth.json"
        #endif
        guard let data = boundedContents(at: path, maximumBytes: 1_048_576) else { return nil }
        return Self.decodeCLIAuthFile(data)
    }

    private func cliIdentityMetadata() -> Data? {
        guard let root = jsonObject(at: homeDirectory + "/.cursor/cli-config.json", maximumBytes: 2_097_152),
              let identity = root["authInfo"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
    }

    private func cliMetadata() -> (email: String?, membershipType: String?) {
        let cliRoot = homeDirectory + "/.cursor"
        var email: String?
        if let root = jsonObject(at: cliRoot + "/cli-config.json", maximumBytes: 2_097_152),
           let auth = root["authInfo"] as? [String: Any] {
            email = Self.nonEmpty(
                (auth["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        var membership: String?
        if let root = jsonObject(at: cliRoot + "/statsig-cache.json", maximumBytes: 8_388_608),
           let raw = root["data"] as? String,
           let data = raw.data(using: .utf8),
           let bootstrap = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let user = bootstrap["user"] as? [String: Any],
           let custom = user["custom"] as? [String: Any] {
            membership = Self.nonEmpty(
                (custom["stripeMembershipStatus"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (email, membership)
    }

    private func jsonObject(at path: String, maximumBytes: Int) -> [String: Any]? {
        guard let data = boundedContents(at: path, maximumBytes: maximumBytes) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func boundedContents(at path: String, maximumBytes: Int) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes else { return nil }
        return fileManager.contents(atPath: path)
    }

    private func macOSCLIKeychainAccessToken() -> GrokBotNativeCredentialStore.PasswordReadResult {
        #if os(macOS)
        guard environment["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN"] != "1",
              cursorReaderInjected || fileManager.fileExists(atPath: homeDirectory + "/.cursor/cli-config.json") else {
            return .init(password: nil)
        }
        return cursorCredentialReader(false)
        #else
        return .init(password: nil)
        #endif
    }

    private func itemValue(database: OpaquePointer?, key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ItemTable WHERE key=?1 LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else { return nil }
        return Self.nonEmpty(
            String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func request(credential: Credential) -> HTTPResponse? {
        for attempt in 0..<2 {
            if let response = requestOnce(credential: credential) {
                if response.statusCode < 500 || attempt == 1 { return response }
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.25) }
        }
        return nil
    }

    private func requestOnce(credential: Credential) -> HTTPResponse? {
        var headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(credential.token)",
            "Content-Type": "application/json",
            "x-ghost-mode": "true",
        ]
        switch credential.origin {
        case .cli:
            headers["x-cursor-client-type"] = "cli"
        case .ide, .grokBot:
            guard let machineID = credential.machineID else { return nil }
            headers["x-cursor-checksum"] = Self.cursorChecksum(machineID: machineID)
            headers["x-cursor-client-source"] = "sand-desktop"
            headers["x-cursor-client-type"] = "sand"
            headers["x-sand-box-namespace"] = "prod"
        }
        let body = Data("{}".utf8)
        guard let endpoint = URL(string: Self.endpoint) else { return nil }
        var request = ProviderHTTPRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 15
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let transport { return transport(request) }
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(
            url: Self.endpoint,
            method: "POST",
            headers: headers,
            body: body,
            connectTimeout: 8,
            sendTimeout: 8,
            receiveTimeout: 15
        ) else { return nil }
        return HTTPResponse(statusCode: response.statusCode, data: response.body)
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        let box = HTTPResultBox()
        session.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response)
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 16) == .success,
              let response = box.load(), response.data.count <= 1_048_576 else { return nil }
        return HTTPResponse(statusCode: response.statusCode, data: response.data)
        #endif
    }

    #if !os(Windows)
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: ProviderHTTPRequest,
                        completionHandler: @escaping @Sendable (ProviderHTTPRequest?) -> Void) { completionHandler(nil) }
    }
    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (data: Data, statusCode: Int)?
        func store(data: Data?, response: URLResponse?) {
            guard let data, let response = response as? HTTPURLResponse else { return }
            lock.withLock { result = (data, response.statusCode) }
        }
        func load() -> (data: Data, statusCode: Int)? { lock.withLock { result } }
    }
    #endif

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? NSNumber {
            let seconds = value.doubleValue > 10_000_000_000
                ? value.doubleValue / 1_000 : value.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = value as? String else { return nil }
        if let milliseconds = Double(value), milliseconds > 10_000_000_000 {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        let plain = ISO8601DateFormatter()
        if let parsed = plain.date(from: value) { return parsed }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func informativePlan(_ value: String?) -> String? {
        guard let value = nonEmpty(value?.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.caseInsensitiveCompare("Grok Bot Plan") != .orderedSame else { return nil }
        return value
    }
}
