import Foundation

enum UsageSharePeriod: Equatable, Sendable {
    case recent(days: Int, ending: Date)
    case month(containing: Date)
    case weekOfMonth(containing: Date, index: Int)

    var bounds: (start: Date, end: Date) {
        let calendar = Calendar.current
        switch self {
        case let .recent(days, ending):
            let end = calendar.startOfDay(for: min(ending, Date()))
            return (calendar.date(byAdding: .day, value: -max(0, min(days, 90) - 1), to: end) ?? end, end)
        case let .month(containing):
            return monthBounds(containing)
        case let .weekOfMonth(containing, index):
            let month = monthBounds(containing)
            let startWeekday = calendar.component(.weekday, from: month.start)
            let offset = (9 - startWeekday) % 7
            let daysToMonday = offset == 0 ? 7 : offset
            let weekStart: Date
            if index <= 1 {
                weekStart = month.start
            } else {
                weekStart = calendar.date(byAdding: .day, value: daysToMonday + (index - 2) * 7,
                                          to: month.start) ?? month.start
            }
            let nextMonday = calendar.date(byAdding: .day, value: index <= 1 ? daysToMonday : 7,
                                           to: weekStart) ?? weekStart
            let weekEnd = calendar.date(byAdding: .day, value: -1, to: nextMonday) ?? weekStart
            return (min(weekStart, month.end), min(weekEnd, month.end))
        }
    }

    var weekCount: Int {
        let month = monthBounds(anchor)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: month.start, to: month.end).day.map { $0 + 1 } ?? 30
        let firstWeekday = calendar.component(.weekday, from: month.start)
        let leading = (firstWeekday + 5) % 7
        return max(1, (leading + days + 6) / 7)
    }

    var anchor: Date {
        switch self {
        case .recent(_, let ending), .month(let ending), .weekOfMonth(let ending, _): return ending
        }
    }

    var kindKey: String {
        switch self {
        case .recent: return "share.period.recent"
        case .month: return "share.period.month"
        case .weekOfMonth: return "share.period.week"
        }
    }

    private func monthBounds(_ containing: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: min(containing, Date()))
        guard let month = calendar.dateInterval(of: .month, for: day) else { return (day, day) }
        let last = calendar.date(byAdding: .day, value: -1, to: month.end) ?? day
        return (month.start, min(last, calendar.startOfDay(for: Date())))
    }
}

enum UsageShareStyle: String, CaseIterable, Identifiable, Sendable {
    case ink, paper, cobalt
    var id: String { rawValue }
    var titleKey: String { "share.style.\(rawValue)" }
}

struct UsageShareRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let emoji: String
    let tokens: Int
    let fraction: Double
}

struct UsageShareData: Sendable {
    let period: UsageSharePeriod
    let dateKey: String
    let endDateKey: String
    let totalTokens: Int
    let messages: Int
    let averageCacheRate: Double
    let rows: [UsageShareRow]
    let quoteKey: String
    var startDate: Date { period.bounds.start }
    var endDate: Date { period.bounds.end }
}

enum UsageShareBuilder {
    private static let quoteKeys = [
        "share.quote1", "share.quote2", "share.quote3", "share.quote4", "share.quote5",
    ]

    static func load(period: UsageSharePeriod, store: HistoryStore = .shared) -> UsageShareData {
        let bounds = period.bounds
        return make(
            period: period,
            overview: UsageOverviewBuilder.load(
                startDate: bounds.start, endDate: bounds.end, grouping: .tool, store: store
            )
        )
    }

    static func load(date: Date, store: HistoryStore = .shared) -> UsageShareData {
        load(period: .recent(days: 1, ending: date), store: store)
    }

    static func make(date: Date, overview: UsageOverviewData) -> UsageShareData {
        make(period: .recent(days: 1, ending: date), overview: overview)
    }

    static func make(period: UsageSharePeriod, overview: UsageOverviewData) -> UsageShareData {
        let total = max(0, overview.summary.tokens)
        let ranked = overview.rows.filter { $0.metrics.tokens > 0 }
        var rows = ranked.prefix(6).map { row in
            UsageShareRow(
                name: row.name,
                emoji: row.emoji,
                tokens: row.metrics.tokens,
                fraction: total > 0 ? Double(row.metrics.tokens) / Double(total) : 0
            )
        }
        if ranked.count > 6 {
            let remaining = ranked.dropFirst(6).reduce(0) { $0 + $1.metrics.tokens }
            if remaining > 0 {
                rows.append(UsageShareRow(
                    name: L10n.shared.tr("share.otherTools"), emoji: "✦", tokens: remaining,
                    fraction: total > 0 ? Double(remaining) / Double(total) : 0
                ))
            }
        }
        let startKey = DateHelper.dateKey(from: period.bounds.start)
        let endKey = DateHelper.dateKey(from: period.bounds.end)
        let quoteIndex = (startKey + endKey).utf8.reduce(0) { ($0 + Int($1)) % quoteKeys.count }
        return UsageShareData(
            period: period,
            dateKey: startKey,
            endDateKey: endKey,
            totalTokens: total,
            messages: max(0, overview.summary.messages),
            averageCacheRate: overview.summary.averageCacheRate,
            rows: rows,
            quoteKey: quoteKeys[quoteIndex]
        )
    }
}
