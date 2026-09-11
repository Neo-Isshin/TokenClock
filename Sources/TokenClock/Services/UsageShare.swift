import Foundation

struct UsageShareRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let emoji: String
    let tokens: Int
    let fraction: Double
}

struct UsageShareData: Sendable {
    let date: Date
    let dateKey: String
    let totalTokens: Int
    let messages: Int
    let averageCacheRate: Double
    let rows: [UsageShareRow]
    let quoteKey: String
}

enum UsageShareBuilder {
    private static let quoteKeys = [
        "share.quote1", "share.quote2", "share.quote3", "share.quote4", "share.quote5",
    ]

    static func load(date: Date, store: HistoryStore = .shared) -> UsageShareData {
        let day = Calendar.current.startOfDay(for: date)
        return make(
            date: day,
            overview: UsageOverviewBuilder.load(
                startDate: day, endDate: day, grouping: .tool, store: store
            )
        )
    }

    static func make(date: Date, overview: UsageOverviewData) -> UsageShareData {
        let total = max(0, overview.summary.tokens)
        let ranked = overview.rows.filter { $0.metrics.tokens > 0 }
        var rows = ranked.prefix(6).map { row in
            UsageShareRow(
                name: row.name, emoji: row.emoji, tokens: row.metrics.tokens,
                fraction: total > 0 ? Double(row.metrics.tokens) / Double(total) : 0
            )
        }
        if ranked.count > 6 {
            let remaining = ranked.dropFirst(6).reduce(0) { $0 + $1.metrics.tokens }
            if remaining > 0 {
                rows.append(UsageShareRow(
                    name: L10n.shared.tr("share.otherTools"), emoji: "✨", tokens: remaining,
                    fraction: total > 0 ? Double(remaining) / Double(total) : 0
                ))
            }
        }
        let dateKey = DateHelper.dateKey(from: date)
        let quoteIndex = dateKey.utf8.reduce(0) { ($0 + Int($1)) % quoteKeys.count }
        return UsageShareData(
            date: date, dateKey: dateKey, totalTokens: total,
            messages: max(0, overview.summary.messages),
            averageCacheRate: overview.summary.averageCacheRate,
            rows: rows, quoteKey: quoteKeys[quoteIndex]
        )
    }
}
