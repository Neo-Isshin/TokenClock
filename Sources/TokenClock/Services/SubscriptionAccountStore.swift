import Foundation

enum SubscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, antigravity, cursor, zhipu
    var id: String { rawValue }
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
