import Foundation

enum SubscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, antigravity, cursor, grokBot, zhipu
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
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
    var thirdRemainingPercent: Double? = nil
    let details: [DialQuotaDetail]
    var accountName: String? = nil
    var subscriptionName: String? = nil
    var displayName: String { subscriptionName ?? provider.displayName }
    var id: SubscriptionProvider { provider }
}

enum DialQuotaResolver {
    /// A persisted percentage is only a snapshot. Never put an expired snapshot
    /// on the live clock face while the next provider request is still pending.
    static func freshGroups(
        _ groups: [ProviderQuotaGroup], refreshedAt: Date?,
        now: Date = Date(), maximumAge: TimeInterval = 15 * 60
    ) -> [ProviderQuotaGroup] {
        guard let refreshedAt,
              now.timeIntervalSince(refreshedAt) >= 0,
              now.timeIntervalSince(refreshedAt) <= maximumAge else { return [] }
        return groups.compactMap { group in
            let buckets = group.buckets.filter { $0.resetsAt.map { $0 > now } ?? true }
            guard !buckets.isEmpty else { return nil }
            return ProviderQuotaGroup(id: group.id, name: group.name, buckets: buckets)
        }
    }

    /// First-run default: surface the provider whose primary quota card has been consumed most.
    /// The caller supplies panel order so ties stay deterministic and match what the user sees.
    static func defaultProvider(
        from indicators: [DialQuotaIndicator],
        providerOrder: [SubscriptionProvider]
    ) -> SubscriptionProvider? {
        var positions: [SubscriptionProvider: Int] = [:]
        for (index, provider) in providerOrder.enumerated() where positions[provider] == nil {
            positions[provider] = index
        }
        return indicators.min {
            if $0.outerRemainingPercent != $1.outerRemainingPercent {
                return $0.outerRemainingPercent < $1.outerRemainingPercent
            }
            return (positions[$0.provider] ?? Int.max) < (positions[$1.provider] ?? Int.max)
        }?.provider
    }

    static func resolve(
        provider: SubscriptionProvider,
        groups: [ProviderQuotaGroup]
    ) -> DialQuotaIndicator? {
        if XSubscriptionQuota.contains(groups) {
            guard let bucket = groups.first(where: { $0.id == XSubscriptionQuota.groupID })?.buckets.first,
                  bucket.usedPercent.isFinite, bucket.windowMinutes == 10_080 else { return nil }
            return DialQuotaIndicator(provider: provider, outerRemainingPercent: bucket.remainingPercent,
                innerRemainingPercent: nil,
                details: [DialQuotaDetail(labelKey: "quota.dial.weekly", remainingPercent: bucket.remainingPercent)],
                subscriptionName: XSubscriptionQuota.title)
        }
        switch provider {
        case .claude:
            // Overall subscription windows win over model-specific weekly
            // caps (Opus/Sonnet/OAuth apps/extra usage are separate buckets).
            let buckets = groups.flatMap(\.buckets)
            if let weekly = minimumRemaining(buckets.filter { $0.id == "claude:seven_day" }) {
                let short = minimumRemaining(buckets.filter { $0.id == "claude:five_hour" })
                var details = [DialQuotaDetail(labelKey: "quota.dial.weekly", remainingPercent: weekly)]
                if let short { details.append(DialQuotaDetail(labelKey: "quota.dial.fiveHour", remainingPercent: short)) }
                return DialQuotaIndicator(provider: provider, outerRemainingPercent: weekly, innerRemainingPercent: short, details: details)
            }
            // Retain legacy generic IDs, but never promote a known model cap
            // into the overall allowance when the aggregate window is absent.
            if buckets.contains(where: { isWeekly($0) && !$0.id.hasPrefix("claude:") }) { break }
            return nil
        case .grokBot:
            // The API's current billing/rate-limit period is not necessarily a
            // week. Display its real remaining quota without relabeling it.
            let buckets = groups.flatMap(\.buckets).filter { $0.usedPercent.isFinite }
            guard let remaining = minimumRemaining(buckets) else { return nil }
            return DialQuotaIndicator(provider: provider, outerRemainingPercent: remaining,
                innerRemainingPercent: nil,
                details: [DialQuotaDetail(labelKey: "quota.dial.currentPeriod", remainingPercent: remaining)])
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
        let families: [(AntigravityQuotaFamilies.Family, String, String)] = [
            (.gemini, "quota.dial.geminiWeekly", "quota.dial.geminiFiveHour"),
            (.claudeGPT, "quota.dial.claudeGPTWeekly", "quota.dial.claudeGPTFiveHour"),
            (.argon, "quota.dial.geminiArgonWeekly", "quota.dial.geminiArgonFiveHour"),
        ]
        var weeklies: [Double] = [], details: [DialQuotaDetail] = []
        for (family, weeklyKey, shortKey) in families {
            let buckets = groups.flatMap { group in
                group.buckets.filter { $0.usedPercent.isFinite && AntigravityQuotaFamilies.matches(family, group: group.name, bucket: $0) }
            }
            if let weekly = minimumRemaining(buckets.filter(isWeekly)) {
                weeklies.append(weekly)
                details.append(DialQuotaDetail(labelKey: weeklyKey, remainingPercent: weekly))
            }
            if let short = minimumRemaining(buckets.filter(isFiveHour)) {
                details.append(DialQuotaDetail(labelKey: shortKey, remainingPercent: short))
            }
        }
        guard let primary = weeklies.first else { return nil }
        return DialQuotaIndicator(
            provider: .antigravity, outerRemainingPercent: primary,
            innerRemainingPercent: weeklies.count > 1 ? weeklies[1] : nil,
            thirdRemainingPercent: weeklies.count > 2 ? weeklies[2] : nil,
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

    var detectedBilling: SubscriptionBillingInfo? = nil
    var manualBilling: SubscriptionBillingInfo? = nil
    var billingReminders: BillingReminderSettings? = nil
    var isUnifiedSubscription: Bool { XSubscriptionQuota.contains(groups) }
    var effectiveBilling: SubscriptionBillingInfo? { manualBilling ?? (isUnifiedSubscription ? nil : detectedBilling) }

    var id: String { "\(provider.rawValue)::\(accountID)" }

    /// Legacy anonymous Codex log snapshots are not authenticated accounts.
    var hasVerifiedIdentity: Bool {
        provider != .codex || (!["", "active", "codex-active"].contains(accountID.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

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
            if preferred.manualBilling == nil { preferred.manualBilling = fallback.manualBilling }
            if preferred.detectedBilling == nil { preferred.detectedBilling = fallback.detectedBilling }
            if preferred.billingReminders == nil { preferred.billingReminders = fallback.billingReminders }
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
            guard incoming.hasVerifiedIdentity else { return visibleLocked() }
            var value = incoming
            let sameEmail = incoming.email.flatMap { email in
                recordsByID.values.first {
                    $0.provider == incoming.provider
                        && $0.email?.caseInsensitiveCompare(email) == .orderedSame
                        && ($0.accountID.caseInsensitiveCompare(email) == .orderedSame
                            || incoming.accountID.caseInsensitiveCompare(email) == .orderedSame)
                }
            }
            if let existing = recordsByID[incoming.id] ?? sameEmail {
                value.detectedBilling = incoming.isUnifiedSubscription ? nil : (incoming.detectedBilling ?? existing.detectedBilling)
                value.manualBilling = existing.manualBilling
                value.billingReminders = existing.billingReminders
                value.note = existing.note
                value.manualPlan = existing.manualPlan
                if value.email?.nonEmpty == nil { value.email = existing.email }
                if existing.id != incoming.id {
                    if persistenceEnabled, DialQuotaAccountSelection.selectedID(for: incoming.provider, defaults: defaults) == existing.id {
                        DialQuotaAccountSelection.select(incoming.id, for: incoming.provider, defaults: defaults)
                    }
                    if persistenceEnabled { BillingReminderStore.migrate(from: existing.id, to: incoming.id, defaults: defaults) }
                    recordsByID.removeValue(forKey: existing.id)
                }
            }
            recordsByID[value.id] = value
            trimProviderLocked(value.provider)
            persistLocked()
            return visibleLocked()
        }
    }

    func records() -> [SubscriptionAccountRecord] {
        lock.withLock { visibleLocked() }
    }

    func update(id: String, note: String, manualPlan: String?) -> [SubscriptionAccountRecord] {
        lock.withLock {
            guard var value = recordsByID[id] else { return visibleLocked() }
            value.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            value.manualPlan = manualPlan?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            recordsByID[id] = value
            persistLocked()
            return visibleLocked()
        }
    }

    @discardableResult
    func updateBilling(id: String, edit: SubscriptionBillingEdit) -> [SubscriptionAccountRecord] {
        lock.withLock {
            guard var value = recordsByID[id] else { return visibleLocked() }
            value.manualBilling = edit.manual
            value.billingReminders = BillingReminderSettings(enabled: edit.reminders.enabled, days: edit.reminders.safeDays)
            recordsByID[id] = value
            persistLocked()
            return visibleLocked()
        }
    }

    @discardableResult
    func updateDetectedBilling(provider: SubscriptionProvider, identity: SubscriptionAccountIdentity?,
                               info: SubscriptionBillingInfo?) -> [SubscriptionAccountRecord] {
        lock.withLock {
            guard let identity, let info,
                  var value = recordsByID[provider.rawValue + "::" + identity.id],
                  value.hasVerifiedIdentity, !value.isUnifiedSubscription else { return visibleLocked() }
            if value.detectedBilling != info {
                value.detectedBilling = info
                recordsByID[value.id] = value
                persistLocked()
            }
            return visibleLocked()
        }
    }

    private func trimProviderLocked(_ provider: SubscriptionProvider) {
        let matching = recordsByID.values.filter { $0.provider == provider }
            .sorted { ($0.refreshedAt ?? .distantPast) > ($1.refreshedAt ?? .distantPast) }
        for stale in matching.dropFirst(8) { recordsByID.removeValue(forKey: stale.id) }
    }

    private func visibleLocked() -> [SubscriptionAccountRecord] {
        sortedLocked().filter(\.hasVerifiedIdentity)
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


enum QuotaAccountLabels {
    static var showOnDial: String { L10n.shared.language == .en ? "Show this account on dial" : "在表盘显示此账户" }
    static var unavailable: String { L10n.shared.language == .en ? "No fresh quota for this account; ring hidden" : "此账户暂无实时额度，圆环暂不显示" }
    static var unverified: String { L10n.shared.language == .en ? "Account identity unavailable (session log only)" : "无法确认账户身份（仅有会话日志）" }
}

enum DialQuotaAccountSelection {
    static let defaultsKey = "TC_dialQuotaAccountIDs"
    static func selectedID(for provider: SubscriptionProvider, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String])?[provider.rawValue]
    }
    static func select(_ id: String?, for provider: SubscriptionProvider, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        values[provider.rawValue] = id
        defaults.set(values, forKey: defaultsKey)
        defaults.synchronize()
    }
    /// A pinned account must never silently borrow the currently logged-in account's quota.
    static func indicator(provider: SubscriptionProvider, selectedID: String?, activeID: String?,
                          records: [SubscriptionAccountRecord], liveGroups: [ProviderQuotaGroup],
                          now: Date = Date()) -> DialQuotaIndicator? {
        guard provider != .codex || activeID != nil else { return nil }
        let targetID = selectedID ?? activeID
        if let selectedID, selectedID != activeID { return nil }
        let record = records.first { $0.provider == provider && $0.id == targetID && $0.hasVerifiedIdentity }
        if selectedID != nil && record == nil { return nil }
        // Live callers already check snapshot freshness. Also validate pinned record age.
        if let selectedID, record?.id == selectedID,
           DialQuotaResolver.freshGroups(record?.groups ?? [], refreshedAt: record?.refreshedAt, now: now).isEmpty { return nil }
        guard var indicator = DialQuotaResolver.resolve(provider: provider, groups: liveGroups) else { return nil }
        indicator.accountName = record?.displayName
        return indicator
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
