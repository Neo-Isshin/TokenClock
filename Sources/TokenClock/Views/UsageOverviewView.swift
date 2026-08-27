#if os(macOS)
import SwiftUI

struct UsageOverviewView: View {
    private enum Period: String, CaseIterable, Identifiable {
        case week, month, custom
        var id: String { rawValue }
    }

    private enum ChartStyle: String, CaseIterable, Identifiable {
        case automatic, line, stacked
        var id: String { rawValue }

        var glyph: String {
            switch self {
            case .automatic: return "▦"
            case .line: return "📈"
            case .stacked: return "📊"
            }
        }
    }

    private struct MonthBoundary: Identifiable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    @State private var period: Period = .week
    @State private var grouping: UsageOverviewGrouping = .tool
    @State private var includesCacheRead = false
    @State private var hoveredDayKey: String?
    @State private var selectedDayKey: String?
    @State private var chartStyle: ChartStyle = .automatic
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var overview = UsageOverviewBuilder.load(
        startDate: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date(),
        endDate: Date(), grouping: .tool
    )
    @State private var modelOverview = UsageOverviewBuilder.load(
        startDate: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date(),
        endDate: Date(), grouping: .model
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if period == .custom { customRange }
            metricCards
            dailyChart
            if period != .month || chartStyle != .automatic { breakdown }
            notes
        }
        .padding(22)
        .frame(
            minWidth: 780, idealWidth: 840, maxWidth: .infinity,
            minHeight: 560, idealHeight: 640, maxHeight: .infinity,
            alignment: .topLeading
        )
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
            Divider()
                .frame(height: 22)
                .padding(.horizontal, 8)
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
                String(format: "%@%.2f%%", overview.summary.cacheIsExact ? "" : "≈", overview.summary.averageCacheRate * 100),
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
            if period == .month, chartStyle == .automatic {
                monthlySectionHeader
                monthlyHeatmap
            } else {
                HStack {
                    Text(L10n.shared.tr("overview.daily")).font(.headline)
                    Spacer()
                    chartStylePicker
                }
                chartForCurrentStyle
            }
        }
    }

    private var monthlySectionHeader: some View {
        HStack(spacing: 14) {
            Text(L10n.shared.tr("overview.daily"))
                .font(.headline)
                .frame(width: 246, alignment: .leading)
            Text(L10n.shared.tr("overview.breakdown"))
                .font(.headline)
            overviewButton
            Spacer()
            chartStylePicker
        }
    }

    private var overviewButton: some View {
        Button {
            selectedDayKey = nil
            hoveredDayKey = nil
        } label: {
            Text(L10n.shared.tr("overview.overview"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selectedDayKey == nil ? .white : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selectedDayKey == nil ? Color.accentColor : Color.secondary.opacity(0.13))
                )
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
    }

    private var chartStylePicker: some View {
        HStack(spacing: 2) {
            chartStyleButton(.automatic, "overview.chartDefault")
            chartStyleButton(.line, "overview.chartLine")
            chartStyleButton(.stacked, "overview.chartBars")
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.09)))
    }

    private func chartStyleButton(_ style: ChartStyle, _ key: String) -> some View {
        Button { chartStyle = style } label: {
            Text(style.glyph)
                .font(.system(size: 12, weight: chartStyle == style ? .semibold : .regular))
                .foregroundColor(chartStyle == style ? .white : .secondary)
                .frame(width: 30, height: 21)
                .background(
                    Capsule(style: .continuous)
                        .fill(chartStyle == style ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.shared.tr(key))
        .accessibilityLabel(Text(L10n.shared.tr(key)))
    }

    @ViewBuilder
    private var chartForCurrentStyle: some View {
        switch chartStyle {
        case .automatic: defaultBarChart
        case .line: lineChart
        case .stacked: stackedModelChart
        }
    }

    private var defaultBarChart: some View {
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
                        chartDateLabel(day.dateKey, at: index)
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
        .chartPanel()
    }

    private var lineChart: some View {
        let days = overview.days
        let boundaries = monthBoundaries(in: days)
        let activeDayKey = selectedDayKey ?? hoveredDayKey
        return VStack(spacing: 3) {
            GeometryReader { proxy in
                let values = days.map { displayedTokens($0.metrics) }
                let maxValue = max(1, values.max() ?? 1)
                let topInset: CGFloat = boundaries.isEmpty ? 4 : 16
                let plotHeight = max(1, proxy.size.height - topInset - 3)
                let step = days.isEmpty ? 0 : proxy.size.width / CGFloat(days.count)

                ZStack(alignment: .topLeading) {
                    ForEach(0..<4, id: \.self) { index in
                        Rectangle()
                            .fill(Color.primary.opacity(0.055))
                            .frame(height: 0.5)
                            .offset(y: topInset + plotHeight * CGFloat(index) / 3)
                    }
                    ForEach(boundaries) { boundary in
                        let x = CGFloat(boundary.index) * step
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        Text(boundary.label)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .position(x: min(proxy.size.width - 15, x + 15), y: 6)
                    }
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(
                                x: (CGFloat(index) + 0.5) * step,
                                y: topInset + plotHeight - CGFloat(value) / CGFloat(maxValue) * plotHeight
                            )
                            if index == 0 { path.move(to: point) }
                            else { path.addLine(to: point) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            if activeDayKey == days[index].dateKey {
                                Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.2).frame(width: 12, height: 12)
                            }
                        }
                            .frame(width: 16, height: 16)
                            .contentShape(Circle())
                            .position(
                                x: (CGFloat(index) + 0.5) * step,
                                y: topInset + plotHeight - CGFloat(value) / CGFloat(maxValue) * plotHeight
                            )
                            .onTapGesture { selectDay(days[index].dateKey) }
                            .onHover { handleDayHover($0, dateKey: days[index].dateKey) }
                            .help("\(days[index].dateKey) · \(TokenFormat.compact(value)) tokens")
                    }
                }
            }
            .frame(height: 82)
            compactDayLabels(days)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(height: 112)
        .chartPanel()
    }

    private var stackedModelChart: some View {
        let days = modelOverview.days
        let boundaries = monthBoundaries(in: days)
        let activeDayKey = selectedDayKey ?? hoveredDayKey
        let maxValue = max(1, days.map { displayedTokens($0.metrics) }.max() ?? 1)
        return VStack(spacing: 3) {
            HStack(spacing: 9) {
                ForEach(Array(modelOverview.rows.prefix(6))) { row in
                    HStack(spacing: 3) {
                        Circle().fill(modelColor(row.name)).frame(width: 6, height: 6)
                        Text(displayName(row.name)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 8.5))
            .foregroundColor(.secondary)

            GeometryReader { proxy in
                let step = days.isEmpty ? 0 : proxy.size.width / CGFloat(days.count)
                ZStack(alignment: .topLeading) {
                    ForEach(boundaries) { boundary in
                        let x = CGFloat(boundary.index) * step
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        Text(boundary.label)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .position(x: min(proxy.size.width - 15, x + 15), y: 6)
                    }

                    HStack(alignment: .bottom, spacing: days.count > 20 ? 3 : 7) {
                        ForEach(days) { day in
                            let total = displayedTokens(day.metrics)
                            let barHeight = max(total > 0 ? 2 : 0, CGFloat(total) / CGFloat(maxValue) * 58)
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if total > 0 {
                                    VStack(spacing: 0) {
                                        ForEach(day.rows) { row in
                                            let value = displayedTokens(row.metrics)
                                            Rectangle()
                                                .fill(modelColor(row.name))
                                                .frame(height: CGFloat(value) / CGFloat(max(1, total)) * barHeight)
                                                .help("\(day.dateKey) · \(displayName(row.name)) · \(TokenFormat.compact(value)) tokens")
                                        }
                                    }
                                    .frame(height: barHeight, alignment: .bottom)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(activeDayKey == day.dateKey ? Color.primary.opacity(0.75) : Color.clear, lineWidth: 1.2)
                                    )
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.08))
                                        .frame(height: 2)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectDay(day.dateKey) }
                            .onHover { handleDayHover($0, dateKey: day.dateKey) }
                        }
                    }
                    .padding(.top, boundaries.isEmpty ? 0 : 14)
                }
            }
            .frame(height: 72)
            compactDayLabels(days)
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .frame(height: 125)
        .chartPanel()
    }

    @ViewBuilder
    private func chartDateLabel(_ dateKey: String, at index: Int) -> some View {
        if shouldShowDate(at: index) {
            Text(shortDate(dateKey))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        } else {
            Text(" ").font(.system(size: 9))
        }
    }

    private func compactDayLabels(_ days: [UsageOverviewDay]) -> some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Text(dayNumber(day.dateKey))
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func modelColor(_ model: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .red]
        let index = modelOverview.rows.firstIndex(where: { $0.name == model }) ?? 0
        return palette[index % palette.count]
    }

    private func selectDay(_ dateKey: String) {
        selectedDayKey = dateKey
        hoveredDayKey = nil
    }

    private func handleDayHover(_ hovering: Bool, dateKey: String) {
        if hovering, selectedDayKey == nil {
            hoveredDayKey = dateKey
        } else if hoveredDayKey == dateKey {
            hoveredDayKey = nil
        }
    }

    private func monthBoundaries(in days: [UsageOverviewDay]) -> [MonthBoundary] {
        guard days.count > 1 else { return [] }
        return days.indices.dropFirst().compactMap { index in
            let previous = days[index - 1].dateKey.split(separator: "-")
            let current = days[index].dateKey.split(separator: "-")
            guard previous.count == 3, current.count == 3, previous[1] != current[1] else { return nil }
            return MonthBoundary(index: index, label: monthLabel(days[index].dateKey))
        }
    }

    private func monthLabel(_ dateKey: String) -> String {
        guard let date = date(from: dateKey) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private func dayNumber(_ dateKey: String) -> String {
        guard let value = dateKey.split(separator: "-").last, let day = Int(value) else { return dateKey }
        return "\(day)"
    }

    private var monthlyHeatmap: some View {
        let cellSize: CGFloat = 27
        let rowSpacing: CGFloat = 6
        let maxValue = max(1, overview.days.map { displayedTokens($0.metrics) }.max() ?? 1)
        let rows = Array(repeating: GridItem(.fixed(cellSize), spacing: rowSpacing), count: 7)
        let slots = heatmapSlots
        let activeDayKey = selectedDayKey ?? hoveredDayKey
        let activeDay = overview.days.first { $0.dateKey == activeDayKey }

        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 5) {
                    VStack(spacing: rowSpacing) {
                        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 16, height: cellSize)
                        }
                    }

                    LazyHGrid(rows: rows, alignment: .top, spacing: rowSpacing) {
                        ForEach(slots.indices, id: \.self) { index in
                            if let day = slots[index] {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(heatColor(for: day, maxValue: maxValue))
                                    .frame(width: cellSize, height: cellSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(
                                                activeDayKey == day.dateKey ? Color.primary.opacity(0.7) : Color.primary.opacity(0.05),
                                                lineWidth: activeDayKey == day.dateKey ? 1.2 : 0.5
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .onTapGesture { selectDay(day.dateKey) }
                                    .onHover { handleDayHover($0, dateKey: day.dateKey) }
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 5) {
                    Text(L10n.shared.tr("overview.hoverDay"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0 ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.16 + Double(level) * 0.19))
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .frame(width: 220, alignment: .leading)

            Divider().padding(.vertical, 2)

            if let activeDay { dayBreakdown(activeDay) }
            else { inlineBreakdown(L10n.shared.tr("overview.overview"), metrics: overview.summary, rows: overview.rows) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func dayBreakdown(_ day: UsageOverviewDay) -> some View {
        inlineBreakdown(day.dateKey, metrics: day.metrics, rows: day.rows)
    }

    private func inlineBreakdown(
        _ title: String,
        metrics: UsageOverviewMetrics,
        rows: [UsageOverviewRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(TokenFormat.compact(displayedTokens(metrics)))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            HStack(spacing: 10) {
                Text("\(integer(metrics.messages)) \(L10n.shared.tr("overview.messages"))")
                Text(CostFormat.estimate(metrics.cost))
                Text(String(format: "%@%.2f%%", metrics.cacheIsExact ? "" : "≈", metrics.averageCacheRate * 100))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            HStack(spacing: 0) {
                Text(L10n.shared.tr("overview.name")).frame(maxWidth: .infinity, alignment: .leading)
                inlineHeader(tokenColumnHeader, width: 82)
                inlineHeader(L10n.shared.tr("overview.messages"), width: 70)
                inlineHeader(L10n.shared.tr("overview.cost"), width: 100)
                inlineHeader(L10n.shared.tr("overview.averageCache"), width: 84)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)

            if rows.isEmpty {
                Text(L10n.shared.tr("overview.noData"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                HStack(spacing: 5) {
                                    Text(row.emoji)
                                    Text(displayName(row.name)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(TokenFormat.compact(displayedTokens(row.metrics)))
                                    .frame(width: 82, alignment: .trailing)
                                Text(integer(row.metrics.messages)).frame(width: 70, alignment: .trailing)
                                Text(CostFormat.estimate(row.metrics.cost)).frame(width: 100, alignment: .trailing)
                                Text(String(format: "%@%.2f%%", row.metrics.cacheIsExact ? "" : "≈", row.metrics.averageCacheRate * 100))
                                    .frame(width: 84, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .frame(height: 32)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inlineHeader(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: width, alignment: .trailing)
    }

    private var heatmapSlots: [UsageOverviewDay?] {
        guard let first = overview.days.first, let date = date(from: first.dateKey) else {
            return overview.days.map(Optional.some)
        }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: UsageOverviewDay?.none, count: leading) + overview.days.map(Optional.some)
    }

    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? []
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let start = max(0, min(6, Calendar.current.firstWeekday - 1))
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    private func heatColor(for day: UsageOverviewDay, maxValue: Int) -> Color {
        let value = displayedTokens(day.metrics)
        guard value > 0 else { return Color.secondary.opacity(0.08) }
        let intensity = log(Double(value) + 1) / log(Double(maxValue) + 1)
        return Color.accentColor.opacity(0.18 + intensity * 0.82)
    }

    private var breakdown: some View {
        let activeDayKey = selectedDayKey ?? hoveredDayKey
        let activeDay = overview.days.first { $0.dateKey == activeDayKey }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.shared.tr("overview.breakdown")).font(.headline)
                overviewButton
                Spacer()
            }
            Group {
                if let activeDay { inlineBreakdown(activeDay.dateKey, metrics: activeDay.metrics, rows: activeDay.rows) }
                else { inlineBreakdown(L10n.shared.tr("overview.overview"), metrics: overview.summary, rows: overview.rows) }
            }
            .padding(10)
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
        hoveredDayKey = nil
        if period != .month { selectedDayKey = nil }
        let next = UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: grouping,
            includingCacheRead: includesCacheRead
        )
        if let selectedDayKey, !next.days.contains(where: { $0.dateKey == selectedDayKey }) {
            self.selectedDayKey = nil
        }
        overview = next
        modelOverview = grouping == .model ? next : UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: .model,
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

    private func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
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

private extension View {
    func chartPanel() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
#endif
