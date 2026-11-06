import Foundation

struct StatusSummaryQuotaReset: Identifiable, Equatable, Sendable {
    let labelKey: String
    let windowMinutes: Int
    let resetsAt: Date?
    let source: String
    var id: String { labelKey + "|" + String(windowMinutes) + "|" + (resetsAt.map { String($0.timeIntervalSince1970) } ?? "unknown") }

    var title: String {
        if labelKey == "quota.dial.geminiArgonWeekly" { return L10n.shared.tr("status.resetArgonWeekly") }
        if labelKey == "quota.dial.geminiArgonFiveHour" { return "Argon 5h" }
        guard labelKey == "quota.dial.currentPeriod" else { return L10n.shared.tr(labelKey) }
        if windowMinutes == 10_080 { return L10n.shared.tr("quota.dial.weekly") }
        if windowMinutes > 0 {
            if windowMinutes.isMultiple(of: 1_440) { return "\(windowMinutes / 1_440)d" }
            if windowMinutes.isMultiple(of: 60) { return "\(windowMinutes / 60)h" }
            return "\(windowMinutes)m"
        }
        return L10n.shared.tr("status.quotaPeriod")
    }
}

enum StatusSummaryQuotaResets {
    private struct Entry {
        let group: String
        let bucket: CodexQuotaBucket
    }

    /// Map each displayed quota detail back to the same limiting bucket(s).
    /// Never take the earliest reset from an unrelated model or period.
    static func rows(for indicator: DialQuotaIndicator, groups: [ProviderQuotaGroup], now: Date = Date()) -> [StatusSummaryQuotaReset] {
        let all = groups.flatMap { group in group.buckets.map { Entry(group: group.name, bucket: $0) } }
            .filter { $0.bucket.usedPercent.isFinite }
        return indicator.details.flatMap { detail -> [StatusSummaryQuotaReset] in
            let matches = candidates(for: detail.labelKey, provider: indicator.provider, all: all)
                .filter { abs($0.bucket.remainingPercent - detail.remainingPercent) < 0.000001 }
            guard !matches.isEmpty else {
                return [.init(labelKey: detail.labelKey, windowMinutes: 0, resetsAt: nil, source: "")]
            }
            var seen = Set<String>()
            return matches.sorted { ($0.bucket.resetsAt ?? .distantFuture) < ($1.bucket.resetsAt ?? .distantFuture) }
                .compactMap { entry in
                    let date = entry.bucket.resetsAt.flatMap { $0 > now ? $0 : nil }
                    let row = StatusSummaryQuotaReset(labelKey: detail.labelKey, windowMinutes: entry.bucket.windowMinutes,
                        resetsAt: date, source: entry.group + " · " + entry.bucket.name)
                    return seen.insert(row.id).inserted ? row : nil
                }
        }
    }

    private static func candidates(for key: String, provider: SubscriptionProvider, all: [Entry]) -> [Entry] {
        switch key {
        case "quota.dial.weekly", "quota.dial.fiveHour":
            let weekly = key == "quota.dial.weekly"
            if provider == .claude {
                let id = weekly ? "claude:seven_day" : "claude:five_hour"
                let overall = all.filter { $0.bucket.id == id }
                if !overall.isEmpty { return overall }
            }
            return all.filter { weekly ? isWeekly($0.bucket) : isFiveHour($0.bucket) }
        case "quota.dial.geminiWeekly", "quota.dial.geminiFiveHour":
            return all.filter { AntigravityQuotaFamilies.matches(.gemini, group: $0.group, bucket: $0.bucket)
                && (key == "quota.dial.geminiWeekly" ? isWeekly($0.bucket) : isFiveHour($0.bucket)) }
        case "quota.dial.claudeGPTWeekly", "quota.dial.claudeGPTFiveHour":
            return all.filter { AntigravityQuotaFamilies.matches(.claudeGPT, group: $0.group, bucket: $0.bucket)
                && (key == "quota.dial.claudeGPTWeekly" ? isWeekly($0.bucket) : isFiveHour($0.bucket)) }
        case "quota.dial.geminiArgonWeekly", "quota.dial.geminiArgonFiveHour":
            return all.filter { AntigravityQuotaFamilies.matches(.argon, group: $0.group, bucket: $0.bucket)
                && (key == "quota.dial.geminiArgonWeekly" ? isWeekly($0.bucket) : isFiveHour($0.bucket)) }
        case "quota.dial.cursorModels": return all.filter { $0.bucket.name.lowercased().contains("cursor") }
        case "quota.dial.otherModels": return all.filter { $0.bucket.name.lowercased().contains("other") }
        case "quota.dial.currentPeriod": return all
        default: return []
        }
    }

    private static func isWeekly(_ bucket: CodexQuotaBucket) -> Bool {
        let name = bucket.name.lowercased()
        return (8_640...11_520).contains(bucket.windowMinutes) || name.contains("week") || name.contains("周") || name.contains("週")
    }
    private static func isFiveHour(_ bucket: CodexQuotaBucket) -> Bool {
        let name = bucket.name.lowercased()
        return bucket.windowMinutes == 300 || name.contains("5-hour") || name.contains("five hour")
            || name.contains("5h") || name.contains("5 小时") || name.contains("5 小時")
    }
}
