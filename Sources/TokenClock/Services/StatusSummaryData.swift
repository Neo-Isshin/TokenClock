import Foundation
#if canImport(Combine)
import Combine
#endif

struct StatusSummaryHour: Identifiable, Equatable, Sendable {
    let hour: Int
    var tokens = 0
    var cacheReadTokens = 0
    var hasRecords = false
    var cacheIsExact = true
    var id: Int { hour }
    func displayedTokens(includingCache: Bool) -> Int { tokens + (includingCache ? cacheReadTokens : 0) }
}

struct StatusSummaryHourlyData: Equatable, Sendable {
    let day: String
    var hours: [StatusSummaryHour]

    static func empty(day: String) -> Self {
        Self(day: day, hours: (0..<24).map { StatusSummaryHour(hour: $0) })
    }

    static func build(_ snapshots: [DaySnapshot], day: String, tools: Set<String>) -> Self {
        var result = empty(day: day)
        for snapshot in snapshots {
            guard snapshot.date.count == 13, snapshot.date.hasPrefix(day + "-"),
                  let hour = Int(snapshot.date.suffix(2)), (0..<24).contains(hour) else { continue }
            for tool in snapshot.tools where tools.contains(tool.name) {
                result.hours[hour].tokens += tool.tokens
                result.hours[hour].cacheReadTokens += tool.cacheReadTokens ?? 0
                result.hours[hour].hasRecords = true
                if tool.cacheReadTokens == nil && (tool.tokens > 0 || tool.messages > 0) {
                    result.hours[hour].cacheIsExact = false
                }
            }
        }
        return result
    }
}

#if canImport(Combine)
@MainActor
final class StatusSummaryHistory: ObservableObject {
    @Published private(set) var data = StatusSummaryHourlyData.empty(day: "")
    private var task: Task<Void, Never>?

    func reload(day: String, tools: Set<String>) {
        task?.cancel()
        if data.day != day { data = .empty(day: day) }
        task = Task { [weak self] in
            let next = await Task.detached(priority: .utility) {
                StatusSummaryHourlyData.build(HourlyHistoryStore.shared.query(day: day), day: day, tools: tools)
            }.value
            guard !Task.isCancelled else { return }
            self?.data = next
        }
    }

    func cancel() { task?.cancel(); task = nil }
}
#endif

struct StatusSummaryQuotaSchedule {
    private var lastRefresh: Date?
    mutating func shouldRefresh(now: Date) -> Bool {
        if let lastRefresh, now >= lastRefresh, now.timeIntervalSince(lastRefresh) < 180 { return false }
        lastRefresh = now
        return true
    }
}

struct StatusSummaryQuota: Identifiable, Equatable {
    let indicator: DialQuotaIndicator
    let isShared: Bool
    var id: SubscriptionProvider { indicator.id }
    var provider: SubscriptionProvider { indicator.provider }
    var subscriptionName: String? { isShared ? "X Subscription" : nil }
    var displayName: String { subscriptionName ?? provider.displayName }
    var accountName: String? { indicator.accountName }
    var details: [DialQuotaDetail] { indicator.details }
}

enum StatusSummaryQuotas {
    // Existing recorded shared-pool metadata. Presentation does not discover
    // new subscription endpoints or infer a shared pool from email/percentages.
    static let sharedGroupID = "x-subscription:shared-weekly"

    /// Fresh groups are supplied by the existing quota layer. Current accounts
    /// only; deduplicate shared subscriptions using account AND reset identity.
    static func indicators(records: [SubscriptionAccountRecord], activeIDs: [SubscriptionProvider: String],
                           freshGroups: [SubscriptionProvider: [ProviderQuotaGroup]], now: Date = Date()) -> [StatusSummaryQuota] {
        var shared = Set<String>()
        return SubscriptionProvider.allCases.compactMap { provider in
            let groups = freshGroups[provider] ?? []
            let record = records.first { $0.provider == provider && $0.id == activeIDs[provider] }
            let sharedGroup = [.cursor, .grokBot].contains(provider) ? groups.first { $0.id == sharedGroupID } : nil
            let indicator: DialQuotaIndicator
            if let sharedGroup {
                guard let bucket = sharedGroup.buckets.first, bucket.windowMinutes == 10_080,
                      bucket.usedPercent.isFinite else { return nil }
                indicator = DialQuotaIndicator(provider: provider, outerRemainingPercent: bucket.remainingPercent,
                    innerRemainingPercent: nil,
                    details: [DialQuotaDetail(labelKey: "quota.dial.weekly", remainingPercent: bucket.remainingPercent)],
                    accountName: record?.displayName)
                if let accountID = record?.accountID, !["", "active"].contains(accountID), !accountID.contains("@"),
                   let reset = bucket.resetsAt {
                    let key = accountID + "|weekly-reset:" + String(Int64((reset.timeIntervalSince1970 * 1000).rounded()))
                    if !shared.insert(key).inserted { return nil }
                }
            } else {
                guard let resolved = DialQuotaAccountSelection.indicator(provider: provider, selectedID: nil,
                    activeID: activeIDs[provider], records: records, liveGroups: groups, now: now) else { return nil }
                indicator = resolved
            }
            return StatusSummaryQuota(indicator: indicator, isShared: sharedGroup != nil)
        }
    }
}

enum StatusSummaryQuotaCredentials {
    /// A summary opening must never invoke the CLI's potentially interactive
    /// security subprocess. A silent read of the same item may supply its token.
    static func environment(_ original: [String: String], readToken: () -> String?) -> [String: String] {
        var result = original
        result["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN"] = "1"
        if result["CURSOR_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let token = readToken(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["CURSOR_AUTH_TOKEN"] = token
        }
        return result
    }
}
