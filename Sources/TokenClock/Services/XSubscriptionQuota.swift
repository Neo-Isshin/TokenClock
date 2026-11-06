import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only server-confirmed merged subscriptions use this presentation marker.
/// It is not a fabricated server pool ID; deduplication also requires the same
/// authenticated Cursor user ID, never an email or a matching percentage.
enum XSubscriptionQuota {
    static let groupID = "x-subscription:shared-weekly"
    static let title = "X Subscription"
    static var weeklyTitle: String { BillingText.choose("Shared weekly quota", "共享周额度", "共享週額度") }
    static var scopeLabel: String {
        BillingText.choose("Shared by Cursor, Grok Bot and Grok", "Cursor、Grok Bot 与 Grok 共用", "Cursor、Grok Bot 與 Grok 共用")
    }

    enum PlanKind: Equatable { case unified, legacy, unknown }
    enum Discovery {
        case unified(ProviderQuotaSnapshot)
        case legacy, unknown, unavailable
    }

    static func contains(_ groups: [ProviderQuotaGroup]) -> Bool { groups.contains { $0.id == groupID } }

    static func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func planKind(_ data: Data?) -> PlanKind {
        guard let root = object(data) else { return .unknown }
        let plan = root["planInfo"] as? [String: Any] ?? [:]
        if flag(root["isMerged"]) == true { return .unified }
        if flag(root["isMerged"]) == false {
            // New single-account weekly plans can still require the explicit
            // Sand isUnified flag; false alone must not turn them into months.
            return plan["includedUsagePeriod"] as? String == "INCLUDED_USAGE_PERIOD_WEEKLY" ? .unknown : .legacy
        }
        let name = (plan["planName"] as? String ?? "").lowercased()
        if ["pro", "pro+", "pro plus", "pro_plus"].contains(name) { return .legacy }
        if plan["includedUsagePeriod"] as? String == "INCLUDED_USAGE_PERIOD_MONTHLY" { return .legacy }
        return .unknown
    }

    static func knownLegacySummary(_ data: Data) -> Bool {
        guard let root = object(data), flag(root["isUnified"]) != true, flag(root["isMerged"]) != true else { return false }
        let payload = (root["usageSummary"] as? [String: Any]) ?? (root["response"] as? [String: Any]) ?? root
        guard flag(payload["isUnified"]) != true, flag(payload["isMerged"]) != true else { return false }
        return ["pro", "pro_plus", "pro+", "team", "teams", "business", "enterprise", "start", "free", "hobby"]
            .contains((payload["membershipType"] as? String ?? "").lowercased())
    }

    /// A confirmed merged account must not fall back to legacy monthly usage
    /// if its weekly response is unavailable or malformed.
    static func discover(planData: Data?, usage: () -> Data?, sand: () -> Data?, now: Date = Date()) -> Discovery {
        switch planKind(planData) {
        case .legacy: return .legacy
        case .unified:
            if let snapshot = decodeCurrentPeriod(planData: planData, usageData: usage(), now: now) { return .unified(snapshot) }
            if var snapshot = decodeSand(sand(), now: now) {
                let plan = object(planData)?["planInfo"] as? [String: Any]
                snapshot.planType = nonEmpty(plan?["planName"] as? String) ?? snapshot.planType
                return .unified(snapshot)
            }
            return .unavailable
        case .unknown:
            let data = sand()
            if flag(object(data)?["isUnified"]) == true {
                return decodeSand(data, now: now).map(Discovery.unified) ?? .unavailable
            }
            return flag(object(data)?["isUnified"]) == false ? .legacy : .unknown
        }
    }

    static func decodeCurrentPeriod(planData: Data?, usageData: Data?, now: Date = Date()) -> ProviderQuotaSnapshot? {
        guard planKind(planData) == .unified,
              let plan = object(planData)?["planInfo"] as? [String: Any],
              plan["includedUsagePeriod"] as? String == "INCLUDED_USAGE_PERIOD_WEEKLY",
              let usage = object(usageData), let amounts = usage["planUsage"] as? [String: Any],
              let percent = number(amounts["totalPercentUsed"]),
              let start = milliseconds(usage["billingCycleStart"]),
              let reset = milliseconds(usage["billingCycleEnd"]) else { return nil }
        if let declaredReset = milliseconds(plan["includedUsageResetsAt"]),
           abs(declaredReset.timeIntervalSince(reset)) > 1 { return nil }
        return snapshot(percent: percent, start: start, reset: reset,
                        plan: nonEmpty(plan["planName"] as? String), now: now)
    }

    static func decodeSand(_ data: Data?, now: Date = Date()) -> ProviderQuotaSnapshot? {
        guard let root = object(data), flag(root["isUnified"]) == true,
              let percent = number(root["usagePercent"]),
              let start = isoDate(root["currentPeriodStart"]),
              let reset = isoDate(root["nextResetTimestampUtc"]) else { return nil }
        return snapshot(percent: percent, start: start, reset: reset,
                        plan: nonEmpty(root["cursorPlanName"] as? String), now: now)
    }

    private static func snapshot(percent: Double, start: Date, reset: Date, plan: String?, now: Date) -> ProviderQuotaSnapshot? {
        guard percent.isFinite, abs(reset.timeIntervalSince(start) - 7 * 86400) <= 60 else { return nil }
        let bucket = CodexQuotaBucket(id: groupID, name: weeklyTitle,
            usedPercent: min(100, max(0, percent)), windowMinutes: 10_080, resetsAt: reset)
        // No renewal date, money balance, or third-party allowance is inferred.
        return ProviderQuotaSnapshot(status: .available,
            groups: [ProviderQuotaGroup(id: groupID, name: "Subscription", buckets: [bucket])],
            planType: plan, refreshedAt: now, source: "X Subscription · Cursor API", message: nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return (value as? String).flatMap(Double.init)
    }
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let value = number(value), value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
    private static func isoDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func accountKey(_ account: SubscriptionAccountRecord) -> String? {
        guard [.cursor, .grokBot].contains(account.provider), contains(account.groups),
              !["", "active"].contains(account.accountID), !account.accountID.contains("@"),
              let bucket = account.groups.first(where: { $0.id == groupID })?.buckets.first,
              bucket.windowMinutes == 10_080, let reset = bucket.resetsAt else { return nil }
        // Same authenticated account AND the same observed weekly window. Do
        // not collapse different periods/workspace contexts merely by user ID.
        return account.accountID + "|weekly-reset:" + String(Int64((reset.timeIntervalSince1970 * 1000).rounded()))
    }

    /// Hide aliases only in the presentation. Persisted notes, manual settings,
    /// and old subscriptions remain intact and can reappear after an account switch.
    static func visibleAccounts(_ records: [SubscriptionAccountRecord],
        activeIDs: [SubscriptionProvider: String], selected: [SubscriptionProvider], now: Date = Date()) -> [SubscriptionAccountRecord] {
        var representatives: [String: SubscriptionAccountRecord] = [:]
        func rank(_ record: SubscriptionAccountRecord) -> Int {
            let active = activeIDs[record.provider] == record.id
            let fresh = !DialQuotaResolver.freshGroups(record.groups, refreshedAt: record.refreshedAt, now: now).isEmpty
            if active && fresh { return selected.contains(record.provider) ? 0 : 1 }
            return active ? 2 : (fresh ? 3 : 4)
        }
        for record in records {
            guard let key = accountKey(record) else { continue }
            if let previous = representatives[key] {
                let lhs = rank(record), rhs = rank(previous)
                if lhs > rhs { continue }
                if lhs == rhs {
                    if selected.contains(record.provider), selected.contains(previous.provider) {
                        if (selected.firstIndex(of: record.provider) ?? 99) >= (selected.firstIndex(of: previous.provider) ?? 99) { continue }
                    } else if previous.provider == .cursor { continue }
                    else if record.provider != .cursor && (record.refreshedAt ?? .distantPast) <= (previous.refreshedAt ?? .distantPast) { continue }
                }
            }
            representatives[key] = record
        }
        return records.filter { record in
            guard let key = accountKey(record) else { return true }
            return representatives[key]?.id == record.id
        }
    }

    static func dialProviders(_ providers: [SubscriptionProvider], records: [SubscriptionAccountRecord],
        activeIDs: [SubscriptionProvider: String], selectedIDs: [SubscriptionProvider: String], now: Date = Date()) -> [SubscriptionProvider] {
        var keys = Set<String>()
        return providers.filter { provider in
            guard let activeID = activeIDs[provider],
                  selectedIDs[provider] == nil || selectedIDs[provider] == activeID,
                  let record = records.first(where: { $0.id == activeID }),
                  !DialQuotaResolver.freshGroups(record.groups, refreshedAt: record.refreshedAt, now: now).isEmpty,
                  let key = accountKey(record) else { return true }
            return keys.insert(key).inserted
        }
    }
}

/// Uses only the existing Cursor credential against its own read-only dashboard RPCs.
enum CursorDashboardRPC {
    static func read(_ method: String, token: String, machineID: String?, body: Data = Data("{}".utf8)) -> Data? {
        guard ["GetPlanInfo", "GetCurrentPeriodUsage", "GetSandUsageStatus"].contains(method),
              let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + method) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        if let machineID {
            request.setValue(GrokBotQuotaService.cursorChecksum(machineID: machineID), forHTTPHeaderField: "x-cursor-checksum")
            request.setValue("sand-desktop", forHTTPHeaderField: "x-cursor-client-source")
            request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
            request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
        } else { request.setValue("cli", forHTTPHeaderField: "x-cursor-client-type") }
        let box = ResultBox(), semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.store(data) }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 16) == .success else { return nil }
        return box.load()
    }
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func store(_ value: Data?) { lock.withLock { data = value } }
        func load() -> Data? { lock.withLock { data } }
    }
}
