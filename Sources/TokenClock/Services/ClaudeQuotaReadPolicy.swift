#if os(macOS)
import Foundation

struct ClaudeQuotaIdentity: Equatable, Sendable {
    let accountID: String
    let organizationID: String
    var key: String { "claude-web:" + accountID.lowercased() + ":" + organizationID.lowercased() }
    init(accountID: String, organizationID: String) {
        self.accountID=accountID.lowercased();self.organizationID=organizationID.lowercased()
    }
    init?(key: String?) {
        guard let key, key.hasPrefix("claude-web:") else { return nil }
        let parts=key.dropFirst("claude-web:".count).split(separator:":",omittingEmptySubsequences:false)
        guard parts.count==2,!parts[0].isEmpty,UUID(uuidString:String(parts[1])) != nil else { return nil }
        self.init(accountID:String(parts[0]),organizationID:String(parts[1]))
    }
    static func legacySnapshotIDs(in records: [SubscriptionAccountRecord]) -> Set<String> {
        let accounts=Set(records.filter{$0.provider == .claude}.compactMap{ClaudeQuotaIdentity(key:$0.accountID)?.accountID})
        return Set(records.filter { $0.provider == .claude && UUID(uuidString:$0.accountID) != nil && accounts.contains($0.accountID.lowercased()) }.map(\.id))
    }

}

enum ClaudeQuotaReadFailure: Equatable, Sendable {
    case noCredential, authentication, localAuthorization, permission, network, blocked, rateLimited, malformed, identityUnknown, wrongAccount
    static func messageKey(_ key: String) -> Self {
        switch key {
        case "quota.claudeConnectRequired": return .authentication
        case "quota.claudePermissionDenied": return .permission
        case "quota.claudeWebBlocked": return .blocked
        case "quota.claudeRateLimited": return .rateLimited
        case "quota.claudeInvalidResponse": return .malformed
        default: return .network
        }
    }
}

/// Read-only candidates. Account/organization checks apply before a fallback
/// reaches the UI; a rate limit never cascades into more authenticated requests.
enum ClaudeQuotaReadPolicy {
    static func resolve(selectedWeb: Bool, expected: ClaudeQuotaIdentity?, previous: ClaudeQuotaSnapshot?,
                        connected: () -> ClaudeQuotaSnapshot, desktop: () -> ClaudeQuotaSnapshot,
                        oauth: () -> ClaudeQuotaSnapshot, cache: () -> ClaudeQuotaSnapshot?, now: Date? = nil) -> ClaudeQuotaSnapshot {
        var failures: [ClaudeQuotaSnapshot]=[]
        var owner=expected
        func accept(_ value: ClaudeQuotaSnapshot, constrained: Bool) -> ClaudeQuotaSnapshot? {
            guard value.status == .available,!value.buckets.isEmpty else {return nil}
            if constrained, let owner, (value.verifiedIdentity ?? ClaudeQuotaIdentity(key:value.account?.id)) != owner {return nil}
            if constrained && selectedWeb && owner == nil {return nil}
            return value
        }
        func cachedResult(_ fallback: ClaudeQuotaSnapshot) -> ClaudeQuotaSnapshot {
            let current = now ?? Date()
            if var value=previous, value.status == .available,!value.buckets.isEmpty,
               let date=value.refreshedAt,date<=current,current.timeIntervalSince(date)<=600,
               owner == nil || (value.verifiedIdentity ?? ClaudeQuotaIdentity(key:value.account?.id)) == owner {
                value.isCachedFallback=true
                value.message=L10n.shared.tr("quota.claudeKeepingSnapshot")
                value.requiresConnection=false
                return value
            }
            if let value=cache(), let date=value.refreshedAt, date<=current,current.timeIntervalSince(date)<=600,
               value.status == .available, !value.buckets.isEmpty, owner == nil || (value.verifiedIdentity ?? ClaudeQuotaIdentity(key:value.account?.id)) == owner {
                return value
            }
            return fallback
        }
        if selectedWeb {
            let value=connected()
            if owner == nil { owner=value.verifiedIdentity }
            if let result=accept(value,constrained:true) {return result}
            failures.append(value)
            if value.readFailure == .rateLimited {return cachedResult(value)}
            // Corrupt/missing pinned ownership cannot authorize another account.
            guard owner != nil else {return cachedResult(value)}
        }
        let app=desktop()
        if let result=accept(app,constrained:selectedWeb) {return result}
        failures.append(app)
        let sameOAuthSource = !selectedWeb && app.readFailure == .noCredential && previous?.source == .oauthAPI
        if !selectedWeb {
            owner = app.verifiedIdentity ?? (sameOAuthSource ? nil : previous?.verifiedIdentity ?? ClaudeQuotaIdentity(key:previous?.account?.id))
        }
        if app.readFailure == .rateLimited {return cachedResult(app)}
        let cli=oauth()
        if let result=accept(cli,constrained:owner != nil || selectedWeb) {return result}
        failures.append(cli)
        if sameOAuthSource { owner = previous?.verifiedIdentity ?? ClaudeQuotaIdentity(key:previous?.account?.id) }
        let meaningful=failures.first { $0.readFailure != .noCredential && $0.readFailure != nil }
        var result=meaningful ?? cli
        if cli.status == .available {result = cli.verifiedIdentity == nil ? failure(.identityUnknown,key:"quota.claudeIdentityUnknown") : failure(.wrongAccount,key:"quota.claudeAccountMismatch")}
        // Network/WAF/scope failures are not evidence that the user must log in.
        result.requiresConnection=failures.allSatisfy { $0.readFailure == .noCredential || $0.readFailure == .authentication }
        return cachedResult(result)
    }
    static func failure(_ reason: ClaudeQuotaReadFailure, key: String, source: ClaudeQuotaSource? = nil) -> ClaudeQuotaSnapshot {
        var value=ClaudeQuotaSnapshot.unavailable(L10n.shared.tr(key))
        value.readFailure=reason;value.source=source
        value.requiresConnection=[.noCredential,.authentication].contains(reason)
        return value
    }
}
#endif
