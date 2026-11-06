import Foundation

struct StatusSummaryRecordedUsage: Sendable {
    var tokens = 0
    var cache: Int? = 0
    var cost = CostEstimate.zero

    mutating func add(_ tool: DaySnapshot.Tool) {
        tokens += tool.tokens
        cache = cache.flatMap { left in tool.cacheReadTokens.map { left + $0 } }
        cost.merge(tool.cost)
    }
    mutating func add(_ other: Self) {
        tokens += other.tokens
        cache = cache.flatMap { left in other.cache.map { left + $0 } }
        cost.merge(other.cost)
    }
}

struct StatusSummaryDelta: Equatable {
    let current: Double
    let previous: Double
    var percent: Double? { previous > 0 ? (current - previous) / previous * 100 : nil }
}

struct StatusSummaryComparison {
    let completedHours: Int
    var tokenDelta: StatusSummaryDelta?
    var costDelta: StatusSummaryDelta?
    var sourceCount = 0
    var isPartial = false
}

struct StatusSummaryComparisonData: Sendable {
    var day = ""
    var today: [String: [Int: StatusSummaryRecordedUsage]] = [:]
    var yesterday: [String: [Int: StatusSummaryRecordedUsage]] = [:]
    var yesterdayTotals: [String: StatusSummaryRecordedUsage] = [:]

    static func previousDay(_ day: String) -> String? {
        guard let date = BillingText.parseDate(day),
              let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) else { return nil }
        return BillingText.dateKey(previous)
    }

    static func build(day: String, today: [DaySnapshot], yesterday: [DaySnapshot], daily: [DaySnapshot]) -> Self {
        func hours(_ snapshots: [DaySnapshot], for day: String) -> [String: [Int: StatusSummaryRecordedUsage]] {
            var result: [String: [Int: StatusSummaryRecordedUsage]] = [:]
            for snapshot in snapshots where snapshot.date.count == 13 && snapshot.date.hasPrefix(day + "-") {
                guard let hour = Int(snapshot.date.suffix(2)), (0..<24).contains(hour) else { continue }
                for tool in snapshot.tools { result[tool.name, default: [:]][hour, default: .init()].add(tool) }
            }
            return result
        }
        let previous = previousDay(day) ?? ""
        var totals: [String: StatusSummaryRecordedUsage] = [:]
        for snapshot in daily where snapshot.date == previous {
            for tool in snapshot.tools { totals[tool.name, default: .init()].add(tool) }
        }
        return Self(day: day, today: hours(today, for: day), yesterday: hours(yesterday, for: previous), yesterdayTotals: totals)
    }

    /// Compare completed wall-clock hours only. A source is eligible only when
    /// its hourly receipts reconcile with both daily totals; missing rows are
    /// never silently treated as a known zero for an unverified source.
    func compare(to tools: [ToolUsage], includesCache: Bool, now: Date = Date(), calendar: Calendar = .current) -> StatusSummaryComparison {
        let end = calendar.component(.hour, from: now)
        var result = StatusSummaryComparison(completedHours: end)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard day == formatter.string(from: now), end > 0 else { return result }
        var currentTokens = 0, previousTokens = 0, currentCost = 0.0, previousCost = 0.0
        var costsExact = true, candidates = 0
        for tool in tools where tool.measurementUnit == .tokens && tool.measurementScope == .today {
            let previous = yesterdayTotals[tool.name]
            guard tool.todayTokens > 0 || tool.todayCacheReadTokens > 0 || (previous?.tokens ?? 0) > 0 || (previous?.cache ?? 0) > 0 else { continue }
            candidates += 1
            guard let previous else { continue }
            let currentHours = today[tool.name] ?? [:], previousHours = yesterday[tool.name] ?? [:]
            var currentTotal = StatusSummaryRecordedUsage(), previousTotal = StatusSummaryRecordedUsage()
            for usage in currentHours.values { currentTotal.add(usage) }
            for usage in previousHours.values { previousTotal.add(usage) }
            guard currentTotal.tokens == tool.todayTokens, previousTotal.tokens == previous.tokens else { continue }
            if includesCache {
                guard currentTotal.cache == tool.todayCacheReadTokens,
                      let cache = previous.cache, previousTotal.cache == cache else { continue }
            }
            var currentWindow = StatusSummaryRecordedUsage(), previousWindow = StatusSummaryRecordedUsage()
            for hour in 0..<end {
                if let usage = currentHours[hour] { currentWindow.add(usage) }
                if let usage = previousHours[hour] { previousWindow.add(usage) }
            }
            currentTokens += currentWindow.tokens + (includesCache ? (currentWindow.cache ?? 0) : 0)
            previousTokens += previousWindow.tokens + (includesCache ? (previousWindow.cache ?? 0) : 0)
            result.sourceCount += 1
            let costs = [tool.todayCost, previous.cost, currentTotal.cost, previousTotal.cost, currentWindow.cost, previousWindow.cost]
            if costs.allSatisfy({ $0.available && $0.complete && $0.value.isFinite })
                && abs(currentTotal.cost.value - tool.todayCost.value) < 0.005
                && abs(previousTotal.cost.value - previous.cost.value) < 0.005 {
                currentCost += currentWindow.cost.value; previousCost += previousWindow.cost.value
            } else { costsExact = false }
        }
        guard result.sourceCount > 0 else { return result }
        result.tokenDelta = StatusSummaryDelta(current: Double(currentTokens), previous: Double(previousTokens))
        if costsExact { result.costDelta = StatusSummaryDelta(current: currentCost, previous: previousCost) }
        result.isPartial = result.sourceCount < candidates
        return result
    }
}

struct StatusSummaryTimelineEvent: Identifiable {
    enum Kind: String { case reset, renewal, expiry, date }
    let id: String
    let provider: SubscriptionProvider
    let name: String
    let accountName: String
    let date: Date
    let kind: Kind
    let dateOnly: Bool
    let detail: String
    var titleKey: String { "status.timeline." + kind.rawValue }
}

enum StatusSummaryTimeline {
    static func events(quotas: [StatusSummaryQuota], records: [SubscriptionAccountRecord],
                       activeIDs: [SubscriptionProvider: String], now: Date = Date(), calendar: Calendar = .current) -> [StatusSummaryTimelineEvent] {
        var result: [StatusSummaryTimelineEvent] = [], seen = Set<String>()
        for quota in quotas {
            guard let record = records.first(where: { $0.provider == quota.provider && $0.id == activeIDs[quota.provider] }) else { continue }
            let buckets = DialQuotaResolver.freshGroups(record.groups, refreshedAt: record.refreshedAt, now: now).flatMap(\.buckets)
            let resets = Dictionary(grouping: buckets.filter { $0.resetsAt != nil }, by: { $0.resetsAt! })
            for (date, buckets) in resets {
                let id = record.id + "|reset|" + String(date.timeIntervalSince1970)
                result.append(.init(id: id, provider: quota.provider, name: quota.displayName,
                    accountName: record.displayName, date: date, kind: .reset, dateOnly: false,
                    detail: buckets.map(\.name).sorted().joined(separator: " · ")))
            }
        }
        for record in records where record.hasVerifiedIdentity {
            let shared = record.groups.first { $0.id == StatusSummaryQuotas.sharedGroupID }
            // A legacy detected billing date must not be carried into a merged subscription.
            guard let billing = record.manualBilling ?? (shared == nil ? record.detectedBilling : nil),
                  let date = billing.nextDate(now: now, calendar: calendar),
                  date >= now || (billing.isManual && calendar.isDate(date, inSameDayAs: now)) else { continue }
            let kind: StatusSummaryTimelineEvent.Kind
            if let renews = billing.autoRenews { kind = renews ? .renewal : .expiry }
            else if billing.isManual { kind = .date }
            else { continue }
            var identity = record.id
            if let bucket = shared?.buckets.first, bucket.windowMinutes == 10_080,
               let reset = bucket.resetsAt, !["", "active"].contains(record.accountID), !record.accountID.contains("@") {
                identity = record.accountID + "|shared|" + String(Int64((reset.timeIntervalSince1970 * 1000).rounded()))
            }
            let id = identity + "|" + kind.rawValue + "|" + String(date.timeIntervalSince1970)
            guard seen.insert(id).inserted else { continue }
            result.append(.init(id: id, provider: record.provider, name: shared == nil ? record.provider.displayName : "X Subscription",
                accountName: record.displayName, date: date, kind: kind, dateOnly: billing.isManual, detail: billing.source))
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
