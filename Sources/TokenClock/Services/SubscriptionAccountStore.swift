import Foundation

enum SubscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, antigravity, cursor, grokBot, zhipu
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .grokBot: return "Grok Bot"
        case .zhipu: return "Z.ai"
        }
    }

    var emoji: String {
        switch self {
        case .codex: return "⚛️"
        case .claude: return "✳️"
        case .antigravity: return "🔃"
        case .cursor: return "💎"
        case .grokBot: return "😶"
        case .zhipu: return "🅉"
        }
    }
}

struct DialQuotaDetail: Equatable, Sendable {
    let labelKey: String
    let remainingPercent: Double
}

struct DialQuotaIndicator: Identifiable, Equatable, Sendable {
    let provider: SubscriptionProvider
    let outerRemainingPercent: Double
    let innerRemainingPercent: Double?
    let details: [DialQuotaDetail]
    var id: SubscriptionProvider { provider }
}

enum DialQuotaResolver {
    static func resolve(
        provider: SubscriptionProvider,
        groups: [ProviderQuotaGroup]
    ) -> DialQuotaIndicator? {
        switch provider {
        case .antigravity:
            if let indicator = antigravity(groups: groups) { return indicator }
        case .cursor:
            if let indicator = cursor(groups: groups) { return indicator }
        default:
            break
        }
        return standard(provider: provider, groups: groups)
    }

    private static func standard(
        provider: SubscriptionProvider,
        groups: [ProviderQuotaGroup]
    ) -> DialQuotaIndicator? {
        let buckets = groups.flatMap(\.buckets)
        guard let weekly = minimumRemaining(buckets.filter(isWeekly)) else { return nil }
        let fiveHour = minimumRemaining(buckets.filter(isFiveHour))
        var details = [DialQuotaDetail(labelKey: "quota.dial.weekly", remainingPercent: weekly)]
        if let fiveHour {
            details.append(DialQuotaDetail(labelKey: "quota.dial.fiveHour", remainingPercent: fiveHour))
        }
        return DialQuotaIndicator(
            provider: provider,
            outerRemainingPercent: weekly,
            innerRemainingPercent: fiveHour,
            details: details
        )
    }

    private static func antigravity(groups: [ProviderQuotaGroup]) -> DialQuotaIndicator? {
        let geminiBuckets = groups.filter { $0.name.lowercased().contains("gemini") }.flatMap(\.buckets)
        let otherBuckets = groups.filter {
            let name = $0.name.lowercased()
            return name.contains("claude") || name.contains("gpt")
        }.flatMap(\.buckets)
        guard let geminiWeekly = minimumRemaining(geminiBuckets.filter(isWeekly)) else { return nil }
        let otherWeekly = minimumRemaining(otherBuckets.filter(isWeekly))
        var details = [
            DialQuotaDetail(labelKey: "quota.dial.geminiWeekly", remainingPercent: geminiWeekly),
        ]
        if let value = minimumRemaining(geminiBuckets.filter(isFiveHour)) {
            details.append(DialQuotaDetail(labelKey: "quota.dial.geminiFiveHour", remainingPercent: value))
        }
        if let otherWeekly {
            details.append(DialQuotaDetail(labelKey: "quota.dial.claudeGPTWeekly", remainingPercent: otherWeekly))
        }
        if let value = minimumRemaining(otherBuckets.filter(isFiveHour)) {
            details.append(DialQuotaDetail(labelKey: "quota.dial.claudeGPTFiveHour", remainingPercent: value))
        }
        return DialQuotaIndicator(
            provider: .antigravity,
            outerRemainingPercent: geminiWeekly,
            innerRemainingPercent: otherWeekly,
            details: details
        )
    }

    private static func cursor(groups: [ProviderQuotaGroup]) -> DialQuotaIndicator? {
        let buckets = groups.flatMap(\.buckets)
        let cursorModels = minimumRemaining(buckets.filter { $0.name.lowercased().contains("cursor") })
        guard let otherModels = minimumRemaining(
            buckets.filter { $0.name.lowercased().contains("other") }
        ) else { return nil }
        var details: [DialQuotaDetail] = []
        if let cursorModels {
            details.append(DialQuotaDetail(
                labelKey: "quota.dial.cursorModels", remainingPercent: cursorModels
            ))
        }
        details.append(DialQuotaDetail(
            labelKey: "quota.dial.otherModels", remainingPercent: otherModels
        ))
        return DialQuotaIndicator(
            provider: .cursor,
            outerRemainingPercent: otherModels,
            innerRemainingPercent: cursorModels,
            details: details
        )
    }

    private static func minimumRemaining(_ buckets: [CodexQuotaBucket]) -> Double? {
        buckets.map(\.remainingPercent).filter(\.isFinite).min()
    }

    private static func isWeekly(_ bucket: CodexQuotaBucket) -> Bool {
        let name = bucket.name.lowercased()
        return bucket.windowMinutes == 10_080
            || abs(bucket.windowMinutes - 10_080) <= 1_440
            || name.contains("week")
            || name.contains("周")
            || name.contains("週")
    }

    private static func isFiveHour(_ bucket: CodexQuotaBucket) -> Bool {
        let name = bucket.name.lowercased()
        return bucket.windowMinutes == 300
            || name.contains("5-hour")
            || name.contains("five hour")
            || name.contains("5h")
            || name.contains("5 小时")
            || name.contains("5 小時")
    }
}

struct SubscriptionAccountIdentity: Equatable, Sendable {
    let id: String
    let email: String?

    static func opaqueID(namespace: String, secret: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in secret.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return namespace + ":" + String(hash, radix: 16)
    }
}

struct SubscriptionAccountRecord: Identifiable, Equatable, Codable, Sendable {
    let provider: SubscriptionProvider
    let accountID: String
    var email: String?
    var note: String
    var detectedPlan: String?
    var manualPlan: String?
    var groups: [ProviderQuotaGroup]
    var refreshedAt: Date?
    var source: String
    var creditBalance: String?
    var hasUnlimitedCredits: Bool
    var resetCreditCount: Int

    var id: String { "\(provider.rawValue)::\(accountID)" }

    var trimmedNote: String? {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var displayName: String {
        trimmedNote ?? email?.nonEmpty ?? "Account"
    }

    var revealsEmailOnDemand: Bool {
        trimmedNote != nil && email?.nonEmpty != nil
    }

    var effectivePlan: String? {
        manualPlan?.nonEmpty ?? detectedPlan?.nonEmpty
    }
}

/// Persists only display metadata and quota snapshots. Authentication material is
/// deliberately never accepted by this type, so switching accounts cannot leak tokens.
final class SubscriptionAccountStore: @unchecked Sendable {
    static let shared = SubscriptionAccountStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private var recordsByID: [String: SubscriptionAccountRecord]

    init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled,
           let raw = defaults.string(for: .subscriptionQuotaAccounts),
           let data = raw.data(using: .utf8),
           let records = try? JSONDecoder().decode([SubscriptionAccountRecord].self, from: data) {
            recordsByID = Self.restore(records)
        } else {
            recordsByID = [:]
        }
    }

    init(restoring records: [SubscriptionAccountRecord]) {
        defaults = .standard
        persistenceEnabled = false
        recordsByID = Self.restore(records)
    }

    private static func restore(
        _ records: [SubscriptionAccountRecord]
    ) -> [String: SubscriptionAccountRecord] {
        // Persisted data can contain duplicate IDs after a crash or migration. Prefer
        // the freshest quota snapshot while preserving user-entered display metadata.
        var restored: [String: SubscriptionAccountRecord] = [:]
        for record in records {
            guard let existing = restored[record.id] else {
                restored[record.id] = record
                continue
            }
            var preferred = (record.refreshedAt ?? .distantPast) >=
                (existing.refreshedAt ?? .distantPast) ? record : existing
            let fallback = preferred == record ? existing : record
            if preferred.trimmedNote == nil { preferred.note = fallback.note }
            if preferred.manualPlan?.nonEmpty == nil { preferred.manualPlan = fallback.manualPlan }
            if preferred.email?.nonEmpty == nil { preferred.email = fallback.email }
            restored[record.id] = preferred
        }
        return restored
    }

    @discardableResult
    func merge(_ incoming: SubscriptionAccountRecord) -> [SubscriptionAccountRecord] {
        lock.withLock {
            var value = incoming
            let sameEmail = incoming.email.flatMap { email in
                recordsByID.values.first {
                    $0.provider == incoming.provider
                        && $0.email?.caseInsensitiveCompare(email) == .orderedSame
                }
            }
            if let existing = recordsByID[incoming.id] ?? sameEmail {
                value.note = existing.note
                value.manualPlan = existing.manualPlan
                if value.email?.nonEmpty == nil { value.email = existing.email }
                if existing.id != incoming.id { recordsByID.removeValue(forKey: existing.id) }
            }
            recordsByID[value.id] = value
            trimProviderLocked(value.provider)
            persistLocked()
            return sortedLocked()
        }
    }

    func records() -> [SubscriptionAccountRecord] {
        lock.withLock { sortedLocked() }
    }

    func update(id: String, note: String, manualPlan: String?) -> [SubscriptionAccountRecord] {
        lock.withLock {
            guard var value = recordsByID[id] else { return sortedLocked() }
            value.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            value.manualPlan = manualPlan?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            recordsByID[id] = value
            persistLocked()
            return sortedLocked()
        }
    }

    private func trimProviderLocked(_ provider: SubscriptionProvider) {
        let matching = recordsByID.values.filter { $0.provider == provider }
            .sorted { ($0.refreshedAt ?? .distantPast) > ($1.refreshedAt ?? .distantPast) }
        for stale in matching.dropFirst(8) { recordsByID.removeValue(forKey: stale.id) }
    }

    private func sortedLocked() -> [SubscriptionAccountRecord] {
        recordsByID.values.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return ($0.refreshedAt ?? .distantPast) > ($1.refreshedAt ?? .distantPast)
        }
    }

    private func persistLocked() {
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(sortedLocked()),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.setString(raw, for: .subscriptionQuotaAccounts)
        defaults.synchronize()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
