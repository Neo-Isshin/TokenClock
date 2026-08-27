import Foundation

/// Generates completed daily/weekly/monthly reports from the shared history store.
/// The native Windows shell can surface the returned notifications while sharing the
/// same date boundaries and Historical Usage routes as macOS and Linux.
enum UsageReportScheduler {
    static func generatePendingReports(
        through completedDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    ) -> [TokenClockNotification] {
        let completed = Calendar.current.startOfDay(for: completedDate)
        return generatePendingDailyReports(through: completed)
            + generatePendingWeeklyReports(through: completed)
            + generatePendingMonthlyReports(through: completed)
    }

    private static func generatePendingDailyReports(through completedDate: Date) -> [TokenClockNotification] {
        let calendar = Calendar.current
        let lastKey = UserDefaults.standard.string(for: .lastDailyReportDateKey)
        var cursor = lastKey.flatMap(date(from:)).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? completedDate
        var reports: [TokenClockNotification] = []
        var count = 0
        while cursor <= completedDate, count < 400 {
            let key = DateHelper.dateKey(from: cursor)
            if let report = report(kind: .dailyReport, titleKey: "notification.dailyReportTitle", startDateKey: key, endDateKey: key, route: .last30Days(selectedDateKey: key)) { reports.append(report) }
            UserDefaults.standard.setString(key, for: .lastDailyReportDateKey)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            count += 1
        }
        return reports
    }

    private static func generatePendingWeeklyReports(through completedDate: Date) -> [TokenClockNotification] {
        let calendar = Calendar.current
        let lastKey = UserDefaults.standard.string(for: .lastWeeklyReportEndDateKey)
        var weekEnd: Date
        if let last = lastKey.flatMap(date(from:)), let next = calendar.date(byAdding: .day, value: 7, to: last) { weekEnd = next }
        else {
            let weekday = calendar.component(.weekday, from: completedDate)
            weekEnd = calendar.date(byAdding: .day, value: -(weekday - 1), to: completedDate) ?? completedDate
        }
        var reports: [TokenClockNotification] = []
        var count = 0
        while weekEnd <= completedDate, count < 60 {
            let start = calendar.date(byAdding: .day, value: -6, to: weekEnd) ?? weekEnd
            let startKey = DateHelper.dateKey(from: start)
            let endKey = DateHelper.dateKey(from: weekEnd)
            if let report = report(kind: .weeklyReport, titleKey: "notification.weeklyReportTitle", startDateKey: startKey, endDateKey: endKey, route: .custom(startDateKey: startKey, endDateKey: endKey)) { reports.append(report) }
            UserDefaults.standard.setString(endKey, for: .lastWeeklyReportEndDateKey)
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekEnd) else { break }
            weekEnd = next
            count += 1
        }
        return reports
    }

    private static func generatePendingMonthlyReports(through completedDate: Date) -> [TokenClockNotification] {
        let calendar = Calendar.current
        let lastKey = UserDefaults.standard.string(for: .lastMonthlyReportEndDateKey)
        var monthEnd: Date
        if let last = lastKey.flatMap(date(from:)), let firstOfNext = calendar.date(byAdding: .day, value: 1, to: last), let firstOfFollowing = calendar.date(byAdding: .month, value: 1, to: firstOfNext), let nextEnd = calendar.date(byAdding: .day, value: -1, to: firstOfFollowing) { monthEnd = nextEnd }
        else {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: completedDate) ?? completedDate
            if calendar.component(.month, from: nextDay) != calendar.component(.month, from: completedDate) { monthEnd = completedDate }
            else {
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: completedDate)) ?? completedDate
                monthEnd = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? completedDate
            }
        }
        var reports: [TokenClockNotification] = []
        var count = 0
        while monthEnd <= completedDate, count < 24 {
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthEnd)) ?? monthEnd
            let startKey = DateHelper.dateKey(from: monthStart)
            let endKey = DateHelper.dateKey(from: monthEnd)
            if let report = report(kind: .monthlyReport, titleKey: "notification.monthlyReportTitle", startDateKey: startKey, endDateKey: endKey, route: .custom(startDateKey: startKey, endDateKey: endKey)) { reports.append(report) }
            UserDefaults.standard.setString(endKey, for: .lastMonthlyReportEndDateKey)
            guard let firstOfNext = calendar.date(byAdding: .day, value: 1, to: monthEnd), let firstOfFollowing = calendar.date(byAdding: .month, value: 1, to: firstOfNext), let nextEnd = calendar.date(byAdding: .day, value: -1, to: firstOfFollowing) else { break }
            monthEnd = nextEnd
            count += 1
        }
        return reports
    }

    private static func report(kind: TokenClockNotification.Kind, titleKey: String, startDateKey: String, endDateKey: String, route: UsageOverviewRoute) -> TokenClockNotification? {
        let snapshots = HistoryStore.shared.query(from: startDateKey, through: endDateKey)
        guard !snapshots.isEmpty else { return nil }
        let tokens = snapshots.reduce(0) { $0 + $1.totalTokens }
        let messages = snapshots.reduce(0) { $0 + $1.totalMessages }
        let label = startDateKey == endDateKey ? startDateKey : "\(startDateKey) – \(endDateKey)"
        return TokenClockNotification(kind: kind, title: L10n.shared.tr(titleKey), message: L10n.shared.tr("notification.dailyReportMessage", label, TokenFormat.compact(tokens), messages), route: route)
    }

    private static func date(from key: String) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}
