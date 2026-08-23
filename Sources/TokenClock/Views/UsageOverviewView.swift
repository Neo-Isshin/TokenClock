#if os(macOS)
import SwiftUI

struct UsageOverviewView: View {
    private enum Period: String, CaseIterable, Identifiable {
        case week, month, custom
        var id: String { rawValue }
    }

    @State private var period: Period = .week
    @State private var grouping: UsageOverviewGrouping = .tool
    @State private var includesCacheRead = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var overview = UsageOverviewBuilder.load(
        startDate: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date(),
        endDate: Date(), grouping: .tool
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if period == .custom { customRange }
            metricCards
            dailyChart
            breakdown
            notes
        }
        .padding(22)
        .frame(minWidth: 780, idealWidth: 840, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: period) { _ in reload() }
        .onChange(of: grouping) { _ in reload() }
        .onChange(of: includesCacheRead) { _ in reload() }
        .onChange(of: customStart) { _ in if period == .custom { reload() } }
        .onChange(of: customEnd) { _ in if period == .custom { reload() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.shared.tr("overview.title"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(dateRangeLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $period) {
                Text(L10n.shared.tr("overview.last7Days")).tag(Period.week)
                Text(L10n.shared.tr("overview.last30Days")).tag(Period.month)
                Text(L10n.shared.tr("overview.custom")).tag(Period.custom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 270)
            Picker("", selection: $grouping) {
                Text(L10n.shared.tr("overview.byTool")).tag(UsageOverviewGrouping.tool)
                Text(L10n.shared.tr("overview.byModel")).tag(UsageOverviewGrouping.model)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            Button { includesCacheRead.toggle() } label: {
                Label(
                    L10n.shared.tr("overview.includeCache"),
                    systemImage: includesCacheRead ? "bolt.horizontal.fill" : "bolt.horizontal"
                )
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(includesCacheRead ? .orange : .accentColor)
        }
    }

    private var customRange: some View {
        HStack(spacing: 12) {
            Spacer()
            Text(L10n.shared.tr("overview.from")).foregroundColor(.secondary)
            DatePicker("", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                .labelsHidden()
            Text(L10n.shared.tr("overview.to")).foregroundColor(.secondary)
            DatePicker("", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                .labelsHidden()
        }
        .font(.caption)
    }

    private var metricCards: some View {
        HStack(spacing: 12) {
            metricCard(tokenColumnTitle, TokenFormat.compact(displayedTokens(overview.summary)), "number.circle.fill", .blue)
            metricCard(L10n.shared.tr("overview.messages"), integer(overview.summary.messages), "bubble.left.and.bubble.right.fill", .purple)
            metricCard(L10n.shared.tr("overview.cost"), CostFormat.estimate(overview.summary.cost), "dollarsign.circle.fill", .green)
            metricCard(
                L10n.shared.tr("overview.averageCache"),
                String(format: "%@%.1f%%", overview.summary.cacheIsExact ? "" : "≈", overview.summary.averageCacheRate * 100),
                "bolt.horizontal.circle.fill", .orange
            )
        }
    }

    private func metricCard(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.shared.tr("overview.daily")).font(.headline)
            GeometryReader { proxy in
                let maxValue = max(1, overview.days.map { displayedTokens($0.metrics) }.max() ?? 1)
                HStack(alignment: .bottom, spacing: overview.days.count > 20 ? 3 : 7) {
                    ForEach(Array(overview.days.enumerated()), id: \.element.id) { index, day in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [.accentColor.opacity(0.55), .accentColor],
                                        startPoint: .bottom, endPoint: .top
                                    )
                                )
                                .frame(height: max(2, CGFloat(displayedTokens(day.metrics)) / CGFloat(maxValue) * 82))
                            if shouldShowDate(at: index) {
                                Text(shortDate(day.dateKey))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(" ").font(.system(size: 9))
                            }
                        }
                        .help("\(day.dateKey) · \(TokenFormat.compact(displayedTokens(day.metrics))) tokens")
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 112)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.shared.tr("overview.breakdown")).font(.headline)
            HStack {
                Text(L10n.shared.tr("overview.name")).frame(maxWidth: .infinity, alignment: .leading)
                column(tokenColumnHeader)
                column(L10n.shared.tr("overview.messages"))
                column(L10n.shared.tr("overview.cost"))
                column(L10n.shared.tr("overview.averageCache"))
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if overview.rows.isEmpty {
                        Text(L10n.shared.tr("overview.noData"))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 70)
                    }
                    ForEach(overview.rows) { row in
                        HStack {
                            HStack(spacing: 7) {
                                Text(row.emoji)
                                Text(displayName(row.name)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            column(TokenFormat.compact(displayedTokens(row.metrics)))
                            column(integer(row.metrics.messages))
                            column(CostFormat.estimate(row.metrics.cost))
                            column(String(format: "%@%.1f%%", row.metrics.cacheIsExact ? "" : "≈", row.metrics.averageCacheRate * 100))
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 110)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
        }
    }

    private var notes: some View {
        HStack(spacing: 12) {
            if overview.summary.cost.available { note(L10n.shared.tr("overview.apiEquivalentCost")) }
            if overview.containsLegacyCacheEstimate { note(L10n.shared.tr("overview.estimatedCache")) }
            if overview.containsUnavailableCost { note(L10n.shared.tr("overview.partialCost")) }
            if overview.containsUnknownModel { note(L10n.shared.tr("overview.unknownModel")) }
            Spacer()
        }
        .frame(minHeight: 14)
    }

    private func note(_ value: String) -> some View {
        Label(value, systemImage: "info.circle")
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    private func column<V: View>(_ value: V) -> some View {
        value.frame(width: 90, alignment: .trailing)
    }

    private func column(_ value: String) -> some View {
        Text(value).frame(width: 90, alignment: .trailing)
    }

    private var dates: (Date, Date) {
        let end = Calendar.current.startOfDay(for: period == .custom ? customEnd : Date())
        let offset = period == .month ? -29 : -6
        let start = period == .custom
            ? Calendar.current.startOfDay(for: customStart)
            : (Calendar.current.date(byAdding: .day, value: offset, to: end) ?? end)
        return (min(start, end), max(start, end))
    }

    private var dateRangeLabel: String {
        "\(mediumDate(dates.0)) – \(mediumDate(dates.1))"
    }

    private func reload() {
        overview = UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: grouping,
            includingCacheRead: includesCacheRead
        )
    }

    private var tokenColumnTitle: String {
        L10n.shared.tr(includesCacheRead ? "overview.tokensWithCache" : "overview.tokens")
    }

    private var tokenColumnHeader: String {
        L10n.shared.tr(includesCacheRead ? "overview.tokensWithCacheShort" : "overview.tokens")
    }

    private func displayedTokens(_ metrics: UsageOverviewMetrics) -> Int {
        metrics.displayedTokens(includingCacheRead: includesCacheRead)
    }

    private func shouldShowDate(at index: Int) -> Bool {
        let count = overview.days.count
        guard count > 1 else { return true }
        let stride = count > 20 ? 7 : max(1, count / 6)
        return index == 0 || index == count - 1 || index % stride == 0
    }

    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(parts[1])/\(parts[2])"
    }

    private func mediumDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func displayName(_ value: String) -> String {
        value == "Unknown" ? L10n.shared.tr("detail.unknownModel") : value
    }
}
#endif
