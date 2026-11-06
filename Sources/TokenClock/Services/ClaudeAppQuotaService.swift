#if os(macOS)
import Foundation

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
    case signIn, chooseOrganization([ClaudeWebOrganization]), noSubscription, network, rateLimited, blocked, malformed, permissionDenied
    case proxyRequired, proxyRequestFailed

    var messageKey: String {
        switch self {
        case .permissionDenied: return "quota.claudePermissionDenied"
        case .signIn: return "quota.claudeConnectRequired"
        case .chooseOrganization: return "quota.claudeChooseOrganization"
        case .noSubscription: return "quota.claudeNoSubscription"
        case .network: return "quota.claudeNetworkError"
        case .rateLimited: return "quota.claudeRateLimited"
        case .blocked: return "quota.claudeWebBlocked"
        case .malformed: return "quota.claudeInvalidResponse"
        case .proxyRequired: return "quota.claudeProxyRequired"
        case .proxyRequestFailed: return "quota.claudeProxyRequestFailed"
        }
    }

    var snapshot: ClaudeQuotaSnapshot {
        var value = ClaudeQuotaSnapshot.unavailable(L10n.shared.tr(messageKey))
        value.requiresConnection = ["quota.claudeConnectRequired", "quota.claudeChooseOrganization"].contains(messageKey)
        value.readFailure = ClaudeQuotaReadFailure.messageKey(messageKey)
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
        var networkFailure: ClaudeQuotaNetwork.Failure? = nil
    }
    typealias Transport = @Sendable (URLRequest) -> Response?
    private let transport: Transport

    init(transport: @escaping Transport = ClaudeQuotaHTTP.get) { self.transport = transport }

    func fetch(_ session: ClaudeAppSession, onVerifiedIdentity: ((ClaudeQuotaIdentity) -> Void)? = nil) -> Result<ClaudeQuotaSnapshot, ClaudeAppQuotaError> {
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
            if let failure = response.networkFailure {
                throw failure == .proxyRequired ? ClaudeAppQuotaError.proxyRequired : ClaudeAppQuotaError.proxyRequestFailed
            }
            if response.challenge { throw ClaudeAppQuotaError.blocked }
            if response.status == 429 { throw ClaudeAppQuotaError.rateLimited }
            if response.status == 401 { throw ClaudeAppQuotaError.signIn }
            if response.status == 403 { throw ClaudeAppQuotaError.permissionDenied }
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
            let verifiedOwner=ClaudeQuotaIdentity(accountID:identity,organizationID:org.id)
            onVerifiedIdentity?(verifiedOwner)
            let usage = try get("organizations/" + org.id + "/usage")
            var snapshot = try Self.decodeUsage(usage)
            snapshot.source = session.connected ? .connectedWeb : .desktopWeb
            snapshot.verifiedIdentity = verifiedOwner
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
        if let declared = root["limits"], !(declared is NSNull) {
            guard let limits = declared as? [[String: Any]] else { throw ClaudeAppQuotaError.malformed }
            var mapped: [String: Any] = [:]
            for limit in limits {
                let unscoped = limit["scope"] == nil || limit["scope"] is NSNull
                    || ((limit["scope"] as? [String: Any]).map { $0.values.allSatisfy { $0 is NSNull } } ?? false)
                guard unscoped, let kind = limit["kind"] as? String,
                      let value = limit["percent"] as? NSNumber, !JSONNumber.isBoolean(value),
                      value.doubleValue.isFinite, (0...100).contains(value.doubleValue) else { continue }
                let key: String
                if kind == "session" { key = "five_hour" }
                else if kind == "weekly_all" { key = "seven_day" }
                else { continue }
                var bucket: [String: Any] = ["utilization":value]
                if let reset = limit["resets_at"] as? String { bucket["resets_at"] = reset }
                if let existing = mapped[key] as? NSDictionary, !existing.isEqual(to: bucket) { throw ClaudeAppQuotaError.malformed }
                mapped[key] = bucket
            }
            root = mapped // The declared windows are authoritative; never mix old/new periods.
        }
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_overage_included"] {
            guard let bucket = root[key] as? [String: Any] else { root.removeValue(forKey: key); continue }
            guard let used = bucket["utilization"] as? NSNumber, !JSONNumber.isBoolean(used),
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

/// Both desktop-cookie and connected-Web quota reads use the same strict proxy transport.
private enum ClaudeQuotaHTTP {
    static func get(_ request: URLRequest) -> ClaudeAppQuotaService.Response? {
        switch ClaudeQuotaNetwork.get(request, claudeHome: PathConfig.claudeCodeHome()) {
        case .success(let result): return .init(status: result.status, data: result.data, challenge: result.challenge)
        case .failure(let failure): return .init(status: 0, data: Data(), networkFailure: failure)
        }
    }
}
#endif
