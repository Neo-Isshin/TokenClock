#if os(macOS)
import Foundation
import CoreFoundation

struct ClaudeAppSession: Sendable {
    let key: String
    var organizationID: String?
    let connected: Bool
    var expectedIdentity: String? = nil

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8192 && key.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7f && $0 != ";" && $0 != "," && $0 != "\"" && $0 != "\\"
        }
    }
}

struct ClaudeWebOrganization: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
}

enum ClaudeAppQuotaError: Error, Sendable {
    case signIn, chooseOrganization([ClaudeWebOrganization]), noSubscription, network, rateLimited, blocked, malformed

    var messageKey: String {
        switch self {
        case .signIn: return "quota.claudeConnectRequired"
        case .chooseOrganization: return "quota.claudeChooseOrganization"
        case .noSubscription: return "quota.claudeNoSubscription"
        case .network: return "quota.claudeNetworkError"
        case .rateLimited: return "quota.claudeRateLimited"
        case .blocked: return "quota.claudeWebBlocked"
        case .malformed: return "quota.claudeInvalidResponse"
        }
    }

    var snapshot: ClaudeQuotaSnapshot {
        var value = ClaudeQuotaSnapshot.unavailable(L10n.shared.tr(messageKey))
        value.requiresConnection = true
        return value
    }
}

/// Subscription percentages only. Never submits prompts, reads cloud transcripts,
/// estimates tokens, or sends a session to anything except the fixed Claude host.
final class ClaudeAppQuotaService: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let data: Data
        var challenge = false
    }
    typealias Transport = @Sendable (URLRequest) -> Response?
    private let transport: Transport

    init(transport: @escaping Transport = ClaudeQuotaHTTP.get) { self.transport = transport }

    func fetch(_ session: ClaudeAppSession) -> Result<ClaudeQuotaSnapshot, ClaudeAppQuotaError> {
        guard ClaudeAppSession.validKey(session.key) else { return .failure(.signIn) }
        let deadline = Date().addingTimeInterval(8)
        func get(_ path: String) throws -> Data {
            guard deadline > Date(), let url = URL(string: "https://claude.ai/api/" + path) else {
                throw ClaudeAppQuotaError.network
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = max(0.1, deadline.timeIntervalSinceNow)
            request.setValue("sessionKey=" + session.key, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let response = transport(request) else { throw ClaudeAppQuotaError.network }
            if response.challenge { throw ClaudeAppQuotaError.blocked }
            if response.status == 429 { throw ClaudeAppQuotaError.rateLimited }
            if response.status == 401 || response.status == 403 { throw ClaudeAppQuotaError.signIn }
            guard response.status == 200 else { throw ClaudeAppQuotaError.network }
            guard response.data.count <= 1_048_576 else { throw ClaudeAppQuotaError.malformed }
            return response.data
        }
        do {
            // Resolve ownership with this exact cookie, never a CLI profile or
            // another browser's email. A selected org must belong to this session.
            let accountData = try get("account")
            guard let account = try JSONSerialization.jsonObject(with: accountData) as? [String: Any] else {
                throw ClaudeAppQuotaError.malformed
            }
            let accountID = (account["uuid"] as? String) ?? (account["account_uuid"] as? String)
            let email = (account["email_address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let identity = accountID ?? email, !identity.isEmpty else { throw ClaudeAppQuotaError.malformed }
            let organizations = try Self.organizations(try get("organizations"))
            let org = try Self.selectOrganization(organizations, preferred: session.organizationID)
            let verifiedID = "claude-web:" + identity.lowercased() + ":" + org.id
            if let expected = session.expectedIdentity, expected != verifiedID { throw ClaudeAppQuotaError.signIn }
            let usage = try get("organizations/" + org.id + "/usage")
            var snapshot = try Self.decodeUsage(usage)
            snapshot.source = session.connected ? .connectedWeb : .desktopWeb
            // Same account in two organizations may have different limits.
            snapshot.account = SubscriptionAccountIdentity(id: verifiedID,
                                                         email: email?.isEmpty == false ? email : nil)
            let memberships = account["memberships"] as? [[String: Any]] ?? []
            if let member = memberships.first(where: { ($0["organization"] as? [String: Any])?["uuid"] as? String == org.id }) {
                let organization = member["organization"] as? [String: Any]
                snapshot.planType = ClaudeQuotaService.detailedPlan(subscriptionType: nil,
                    rateLimitTier: organization?["rate_limit_tier"] as? String)
            }
            return .success(snapshot)
        } catch let error as ClaudeAppQuotaError { return .failure(error) }
        catch { return .failure(.malformed) }
    }

    static func organizations(_ data: Data) throws -> [ClaudeWebOrganization] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 200 else {
            throw ClaudeAppQuotaError.malformed
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["uuid"] as? String, UUID(uuidString: id) != nil else { return nil }
            let capabilities = (row["capabilities"] as? [String] ?? []).map { $0.lowercased() }
            guard capabilities.isEmpty || capabilities.contains("chat"), seen.insert(id).inserted else { return nil }
            return ClaudeWebOrganization(id: id.lowercased(), name: String(((row["name"] as? String) ?? id).prefix(120)))
        }
    }

    static func selectOrganization(_ organizations: [ClaudeWebOrganization], preferred: String?) throws -> ClaudeWebOrganization {
        guard !organizations.isEmpty else { throw ClaudeAppQuotaError.noSubscription }
        if let preferred, !preferred.isEmpty {
            guard let org = organizations.first(where: { $0.id == preferred.lowercased() }) else { throw ClaudeAppQuotaError.signIn }
            return org
        }
        guard organizations.count == 1, let only = organizations.first else {
            throw ClaudeAppQuotaError.chooseOrganization(organizations)
        }
        return only
    }

    static func decodeUsage(_ data: Data) throws -> ClaudeQuotaSnapshot {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeAppQuotaError.malformed }
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_overage_included"] {
            guard let bucket = root[key] as? [String: Any] else { root.removeValue(forKey: key); continue }
            guard let used = bucket["utilization"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
                  used.doubleValue.isFinite, (0...100).contains(used.doubleValue) else {
                root.removeValue(forKey: key); continue
            }
        }
        guard let snapshot = ClaudeQuotaService.decodeUsageResponse(try JSONSerialization.data(withJSONObject: root)) else {
            throw ClaudeAppQuotaError.malformed
        }
        return snapshot
    }
}

/// Ephemeral, bounded, GET-only transport. Refuse redirects rather than forwarding
/// a credential to an authentication/SSO/CDN host. No shared browser cookie jar.
private final class ClaudeQuotaHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var body = Data()
    private var response: HTTPURLResponse?
    private var failed = false

    static func get(_ request: URLRequest) -> ClaudeAppQuotaService.Response? {
        guard request.url?.scheme == "https", request.url?.host == "claude.ai", request.httpMethod == "GET" else { return nil }
        let delegate = ClaudeQuotaHTTP()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard delegate.completed.wait(timeout: .now() + request.timeoutInterval) == .success else { return nil }
        return delegate.lock.withLock {
            guard !delegate.failed, let response = delegate.response else { return nil }
            let challenge = response.value(forHTTPHeaderField: "cf-mitigated") == "challenge"
                || (response.statusCode == 403 && String(decoding: delegate.body.prefix(4096), as: UTF8.self).contains("Just a moment"))
            return .init(status: response.statusCode, data: delegate.body, challenge: challenge)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response = response as? HTTPURLResponse }
        completionHandler(response.expectedContentLength > 1_048_576 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock {
            if body.count + data.count > 1_048_576 { failed = true; return true }
            body.append(data); return false
        }
        if cancel { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { if error != nil { failed = true } }
        completed.signal()
    }
}
#endif
