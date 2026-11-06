import SwiftUI
import AppKit

/// A menu-bar overview of existing usage snapshots.
struct StatusSummarySnapshot {
    let tools: [ToolUsage]
    let includesCache: Bool

    var rankedTools: [ToolUsage] {
        tools.filter {
            $0.measurementUnit == .tokens && $0.measurementScope == .today
                && (tokens(for: $0) > 0 || $0.todayMessages > 0)
        }.sorted {
            let left = tokens(for: $0), right = tokens(for: $1)
            return left == right ? $0.name < $1.name : left > right
        }
    }

    var totalTokens: Int { UsageAggregator.totalTokens(tools, includingCacheRead: includesCache) }
    var totalMessages: Int { UsageAggregator.totalMessages(tools) }
    var cacheReadTokens: Int {
        tools.filter { $0.measurementUnit == .tokens && $0.measurementScope == .today }
            .reduce(0) { $0 + $1.todayCacheReadTokens }
    }
    var cacheShare: Double? {
        let fresh = UsageAggregator.totalTokens(tools)
        guard fresh > 0 || cacheReadTokens > 0 else { return nil }
        return TokenAccounting.cacheReadShare(freshTokens: fresh, cacheRead: cacheReadTokens)
    }
    func tokens(for tool: ToolUsage) -> Int {
        tool.todayTokens + (includesCache ? tool.todayCacheReadTokens : 0)
    }
}

@MainActor
struct StatusSummaryView: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject private var speedStore = GenerationSpeedStore.shared
    @StateObject private var history = StatusSummaryHistory()
    var side: CGFloat = 600
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void
    var onTool: (QuickTool) -> Void = { _ in }

    private var snapshot: StatusSummarySnapshot {
        StatusSummarySnapshot(tools: viewModel.visibleTools, includesCache: viewModel.usageIncludesCache)
    }
    private var models: [ModelGroup] {
        UsageAggregator.groupedByModel(snapshot.tools, unknownLabel: L10n.shared.tr("detail.unknownModel"))
            .sorted {
                let left = $0.totalTokens + (snapshot.includesCache ? $0.totalCacheReadTokens : 0)
                let right = $1.totalTokens + (snapshot.includesCache ? $1.totalCacheReadTokens : 0)
                return left == right ? $0.name < $1.name : left > right
            }
    }
    private var day: String { DateHelper.dateKey(from: Date()) }
    private var hourlyTools: Set<String> {
        Set(snapshot.tools.filter { $0.measurementUnit == .tokens && $0.measurementScope == .today }.map(\.name))
    }
    private var hourlyKey: String { day + "|" + hourlyTools.sorted().joined(separator: "|") }

    var body: some View {
        StatusSummaryContent(
            snapshot: snapshot, models: models, date: viewModel.dateString,
            tokens: viewModel.totalTokensFormatted, cost: viewModel.totalCostFormatted,
            isLoading: viewModel.isInitialLoading, side: side,
            hourly: history.data.day == day ? history.data : .empty(day: day),
            previousHourly: history.previousData,
            comparison: history.comparison.compare(to: snapshot.tools, includesCache: snapshot.includesCache),
            timeline: StatusSummaryTimeline.events(quotas: viewModel.statusSummaryQuotaIndicators,
                records: viewModel.subscriptionAccounts, activeIDs: viewModel.activeSubscriptionAccountIDs),
            quotas: viewModel.statusSummaryQuotaIndicators, isQuotaLoading: viewModel.statusSummaryQuotaLoading,
            harnessSpeeds: Dictionary(uniqueKeysWithValues: snapshot.rankedTools.map { ($0.name, speedStore.summary(provider: $0.name)) }),
            notebook: viewModel.userContent.notebook,
            onHistory: onHistory, onQuota: onQuota, onShare: onShare, onTool: onTool
        )
        .task(id: hourlyKey) { history.reload(day: day, tools: hourlyTools) }
        .onReceive(NotificationCenter.default.publisher(for: HourlyHistoryStore.updated)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            history.reload(day: day, tools: hourlyTools)
        }
        .onAppear { viewModel.refreshStatusSummaryQuotasIfNeeded() }
        .onDisappear { history.cancel() }
    }
}

/// Presentation also used by the native preview without starting a second usage scan.
@MainActor
struct StatusSummaryContent: View {
    let snapshot: StatusSummarySnapshot
    let models: [ModelGroup]
    let date: String
    let tokens: String
    let cost: String
    var isLoading = false
    var side: CGFloat = 600
    var hourly = StatusSummaryHourlyData.empty(day: "")
    var previousHourly = StatusSummaryHourlyData.empty(day: "")
    var comparison = StatusSummaryComparison(completedHours: 0)
    var timeline: [StatusSummaryTimelineEvent] = []
    var quotas: [StatusSummaryQuota] = []
    var isQuotaLoading = false
    var harnessSpeeds: [String: GenerationSpeed] = [:]
    var notebook: NotebookStore? = nil
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void
    var onTool: (QuickTool) -> Void = { _ in }
    @State private var showsModels = false
    @State private var showsTimeline = false
    @State private var showsFullDay = false
    private var layout: StatusSummaryLayout { StatusSummaryLayout(side: side) }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: layout.isCompact ? 16 : 18, weight: .medium))
                        .foregroundStyle(.cyan.gradient)
                        .frame(width: layout.isCompact ? 28 : 32, height: layout.isCompact ? 28 : 32)
                        .background(.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TOKENCLOCK").font(.system(size: 9, weight: .semibold)).tracking(1.8)
                            .foregroundStyle(.secondary)
                        Text(L10n.shared.tr("status.summary"))
                            .font(.system(size: layout.isCompact ? 17 : 20, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 8)
                Text(date).font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    .frame(maxWidth: layout.isCompact ? 96 : 125, alignment: .trailing)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: layout.spacing) {
                    if let notebook {
                        HStack(alignment: .top, spacing: layout.spacing) {
                            tokenCard.frame(maxWidth: .infinity)
                            StatusSummaryNotebookCard(store: notebook, height: layout.notebookHeight,
                                compact: layout.isCompact, onOpen: { onTool(.notebook) })
                                .frame(width: layout.notebookWidth)
                        }.accessibilityIdentifier("summary-usage-notebook-row")
                    } else { tokenCard }
                    if layout.isCompact {
                        quotaStrip
                        summaryUsage
                    } else {
                        HStack(alignment: .top, spacing: layout.spacing) {
                            quotaStrip.frame(width: max(190, (side-2*layout.padding-24)*0.43))
                            summaryUsage.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    if layout.isCompact { summaryToolbox }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("summary-content-scroll")

            if !layout.isCompact { summaryToolbox }
            Text(L10n.shared.tr(snapshot.includesCache ? "status.cacheIncluded" : "status.cacheExcluded"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)

        }
        .padding(layout.padding)
        .frame(width: side, height: side)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(6)
        .accessibilityIdentifier("status-today-summary")
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: notebook == nil ? 5 : 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.shared.tr("clock.todayTokens"), systemImage: "chart.bar.fill")
                        .font(.system(size: notebook == nil ? 12 : 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(comparisonCaption + " " + deltaText(comparison.tokenDelta, money: false)
                         + (comparison.isPartial ? " · " + L10n.shared.tr("status.comparisonPartial") : ""))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(comparison.tokenDelta == nil ? Color.secondary : .teal)
                        .help(comparisonHelp)
                }
                Spacer()
                Text(tokens).font(.system(size: notebook == nil ? 29 : 24, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            usageMetrics
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            hourlyChart
        }
        .padding(notebook == nil ? 10 : 8)
        .frame(maxWidth: .infinity, minHeight: notebook == nil ? nil : layout.notebookHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [.cyan.opacity(0.17), .blue.opacity(0.08), .purple.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.cyan.opacity(0.15), lineWidth: 0.7) }
    }

    @ViewBuilder private var usageMetrics: some View {
        if notebook != nil {
            VStack(alignment: .leading, spacing: 3) {
                HStack { messageMetric; Spacer(minLength: 3); costMetric }
                cacheMetric
            }
        } else if layout.isCompact {
            VStack(alignment: .leading, spacing: 5) {
                HStack { messageMetric; Spacer(); costMetric }
                cacheMetric
            }
        } else {
            HStack { messageMetric; Spacer(); cacheMetric; Spacer(); costMetric }
        }
    }

    private var messageMetric: some View {
        Label(isLoading ? "—" : "\(snapshot.totalMessages)", systemImage: "bubble.left.and.bubble.right")
    }
    private var cacheMetric: some View {
        Label(L10n.shared.tr("status.cacheReads") + " " + (isLoading ? "—" : TokenFormat.compact(snapshot.cacheReadTokens))
              + " · " + (isLoading ? "—" : (snapshot.cacheShare.map { String(format: "%.1f%%", $0 * 100) } ?? "—")),
              systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.teal).help(L10n.shared.tr("status.cacheShareHelp"))
    }
    private var costMetric: some View {
        Text("\(L10n.shared.tr("detail.cost"))  \(cost)"
             + (comparison.costDelta.map { " · " + deltaText($0, money: true) } ?? ""))
            .help(comparisonHelp)
    }

    private var hourlyChart: some View {
        let hours = hourly.chartHours(expanded: showsFullDay, currentHour: Calendar.current.component(.hour, from: Date()),
                                     previous: previousHourly)
        let maximum = max(1, hours.map { $0.usage.displayedTokens(includingCache: snapshot.includesCache) }.max() ?? 0)
        let partial = hourly.hours.reduce(0) { $0 + $1.displayedTokens(includingCache: snapshot.includesCache) } != snapshot.totalTokens
            || (snapshot.includesCache && hours.contains { !$0.usage.cacheIsExact })
        let toggleTitle = L10n.shared.tr(showsFullDay ? "status.collapseHourly" : "status.expandHourly")
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { showsFullDay.toggle() }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(showsFullDay ? HourlyOverviewLabels.title + " · 24h" : L10n.shared.tr("status.recentHours"))
                    Spacer(minLength: 0)
                    if partial {
                        if layout.isCompact || notebook != nil {
                            Image(systemName: "info.circle").help(HourlyOverviewLabels.partial)
                        } else {
                            Label(L10n.shared.tr("status.partialHourly"), systemImage: "info.circle")
                                .help(HourlyOverviewLabels.partial)
                        }
                    }
                    Text(showsFullDay ? "24h" : "6h").monospacedDigit()
                    Image(systemName: showsFullDay ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(hours) { hour in
                            chartBar(hour, maximum: maximum, height: geometry.size.height)
                        }
                    }
                }
                .frame(height: showsFullDay ? 53 : 26)
                HStack(spacing: 4) {
                    if showsFullDay {
                        ForEach([0, 6, 12, 18, 23], id: \.self) { hour in
                            if hour > 0 { Spacer() }
                            Text(String(format: "%02d", hour))
                        }
                    } else {
                        ForEach(hours) { hour in
                            Text(String(format: "%02d:00", hour.usage.hour)).frame(maxWidth: .infinity)
                        }
                    }
                }
                .font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(toggleTitle)
        .accessibilityLabel(toggleTitle)
        .accessibilityValue(showsFullDay ? "24h" : "6h")
        .accessibilityIdentifier("summary-hourly-toggle")
    }

    private func chartBar(_ bucket: StatusSummaryChartHour, maximum: Int, height: CGFloat) -> some View {
        let hour = bucket.usage
        let value = hour.displayedTokens(includingCache: snapshot.includesCache)
        let label = HourlyOverviewLabels.label(bucket.id)
        let tooltip: String = label + " · " + (hour.hasRecords ? "\(TokenFormat.compact(value)) tokens" : L10n.shared.tr("status.noHourlyRecord"))
        let accessibility: String = label + ": " + (hour.hasRecords ? "\(value) tokens" : L10n.shared.tr("status.noHourlyRecord"))
        return RoundedRectangle(cornerRadius: 2)
            .fill(hour.hasRecords ? Color.cyan.opacity(0.75).gradient : Color.primary.opacity(0.07).gradient)
            .frame(width: showsFullDay ? nil : (notebook == nil ? 14 : 10))
            .frame(height: value > 0 ? max(2, height * Double(value) / Double(maximum)) : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .help(tooltip)
            .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var summaryUsage: some View {
        if isLoading {
            ProgressView(L10n.shared.tr("detail.loading")).frame(maxWidth:.infinity,minHeight:100)
        } else if snapshot.rankedTools.isEmpty {
            Text(L10n.shared.tr("status.empty")).font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:100)
        } else { usageTable }
    }

    private var quotaStrip: some View {
        let grid = layout.quotaGrid(count: quotas.count)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.shared.tr("detail.subscriptionQuota")).font(.system(size: 11, weight: .semibold))
                if isQuotaLoading { ProgressView().controlSize(.mini) }
                Spacer()
            }
            if quotas.isEmpty {
                Button(L10n.shared.tr(isQuotaLoading ? "quota.loadingAll" : "status.noReadableQuota"), action: onQuota)
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: layout.spacing, alignment: .top), count: grid.columns),
                          alignment: .center, spacing: layout.spacing) {
                        ForEach(quotas) { indicator in
                            Button(action: onQuota) {
                                VStack(spacing: 3) {
                                    summaryRing(indicator.indicator, size: grid.ringSize)
                                    HStack(spacing: 3) {
                                        BrandIconView(name: indicator.displayName,
                                            fallback: indicator.subscriptionName == nil ? indicator.provider.emoji : "𝕏", size: 11)
                                        Text(indicator.displayName).font(.system(size: 9)).lineLimit(1)
                                    }
                                    Text(L10n.shared.tr("status.nextQuotaReset"))
                                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                                    ForEach(indicator.resets) { reset in
                                        HStack(spacing: 3) {
                                            Text(reset.title).lineLimit(1).minimumScaleFactor(0.8)
                                            Spacer(minLength: 0)
                                            Text(quotaResetDate(reset.resetsAt)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                        }
                                        .font(.system(size: 8)).foregroundStyle(.secondary)
                                        .instantHint(resetHelp(reset))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .instantHint(([indicator.displayName, indicator.accountName].compactMap { $0 }
                                + indicator.details.map { L10n.shared.tr($0.labelKey) + " " + String(format: "%.0f%%", $0.remainingPercent) })
                                .joined(separator: "\n"))
                        }
                }
                .padding(.vertical, 2)
            }
            timelineView
        }
        .padding(layout.sectionPadding)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 15))
    }

    private func quotaResetDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func resetHelp(_ reset: StatusSummaryQuotaReset) -> String {
        let date: String
        if let value = reset.resetsAt {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
            formatter.dateStyle = .full; formatter.timeStyle = .long
            date = formatter.string(from: value)
        } else { date = L10n.shared.tr("status.quotaResetUnknown") }
        return L10n.shared.tr(reset.labelKey) + " · " + date + (reset.source.isEmpty ? "" : "\n" + reset.source)
    }

    private var comparisonHelp: String {
        guard !isLoading, comparison.tokenDelta != nil else { return L10n.shared.tr("status.comparisonUnavailable") }
        return L10n.shared.tr("status.comparisonBasis", comparison.completedHours, comparison.sourceCount)
            + (comparison.costDelta == nil ? "\n" + L10n.shared.tr("status.comparisonCostUnavailable") : "")
    }

    private var comparisonCaption: String {
        L10n.shared.tr("status.comparedYesterday")
            + (comparison.tokenDelta == nil ? "" : String(format: " (%02d:00)", comparison.completedHours))
    }

    private func deltaText(_ delta: StatusSummaryDelta?, money: Bool) -> String {
        guard !isLoading, let delta else { return "—" }
        if let percent = delta.percent { return abs(percent) < 0.05 ? "0.0%" : String(format: "%+.1f%%", percent) }
        if delta.current == 0 { return L10n.shared.tr("status.comparisonUnchanged") }
        let value = money ? CostFormat.estimate(CostEstimate(value: delta.current)) : TokenFormat.compact(Int(delta.current))
        return L10n.shared.tr("status.comparisonNew", value)
    }

    private var timelineView: some View {
        DisclosureGroup(isExpanded: $showsTimeline) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(timeline) { event in
                        Group {
                            if layout.isCompact {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.name + " · " + L10n.shared.tr(event.titleKey)).lineLimit(2)
                                    Text(timelineDate(event)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                HStack(spacing: 6) {
                                    Circle().fill(event.kind == .reset ? Color.cyan : .orange).frame(width: 4, height: 4)
                                    Text(event.name + " · " + L10n.shared.tr(event.titleKey)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(timelineDate(event)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.system(size: 10))
                        .help(event.accountName + "\n" + event.detail)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: 64)
        } label: {
            HStack {
                Text(L10n.shared.tr("status.timelineTitle"))
                Spacer(minLength: 6)
                if let next = timeline.first {
                    Text(next.name + " · " + L10n.shared.tr(next.titleKey) + " · " + timelineDate(next)).lineLimit(1)
                } else { Text(L10n.shared.tr("status.timelineEmpty")) }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .disabled(timeline.isEmpty)
    }

    private func timelineDate(_ event: StatusSummaryTimelineEvent) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateStyle = .short
        formatter.timeStyle = event.dateOnly ? .none : .short
        return formatter.string(from: event.date)
    }

    private func summaryRing(_ indicator: DialQuotaIndicator, size: CGFloat) -> some View {
        let color = indicator.provider == .zhipu ? Color.primary : indicator.provider.dialQuotaColor
        let centerLabel = QuotaCenterLabel(remaining: indicator.outerRemainingPercent)
        let middle = indicator.thirdRemainingPercent == nil ? color.opacity(0.4)
            : Color(nsColor: GlassQuotaRingPalette.cool.concentricColor(layer: 1, contrastColor: .labelColor))
        let innermost = Color(nsColor: GlassQuotaRingPalette.cool.concentricColor(layer: 2, contrastColor: .labelColor))
        let scale = size / 48
        return ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 4 * scale)
            Circle().trim(from: 0, to: indicator.outerRemainingPercent / 100)
                .stroke(color.opacity(0.75).gradient, style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let inner = indicator.innerRemainingPercent {
                Circle().inset(by: 7 * scale).stroke(indicator.thirdRemainingPercent == nil ? Color.primary.opacity(0.06) : middle.opacity(0.22), lineWidth: 2 * scale)
                Circle().inset(by: 7 * scale).trim(from: 0, to: inner / 100)
                    .stroke(middle, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let third = indicator.thirdRemainingPercent {
                Circle().inset(by: 11 * scale).stroke(innermost.opacity(0.22), lineWidth: 1.3 * scale)
                Circle().inset(by: 11 * scale).trim(from: 0, to: third / 100)
                    .stroke(innermost, style: StrokeStyle(lineWidth: 1.3 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(centerLabel.text)
                    .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                if centerLabel.showsPercent {
                    Text("%")
                        .font(.system(size: 8 * scale, weight: .regular, design: .rounded))
                }
            }
            .monospacedDigit()
            .frame(width: indicator.thirdRemainingPercent == nil ? nil : 20 * scale)
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(3 * scale).frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.shared.tr("quota.dialAccessibility", indicator.provider.displayName,
                                              Int(indicator.outerRemainingPercent.rounded()))))
    }

    private var usageTable: some View {
        VStack(spacing: 6) {
            Picker("", selection: $showsModels) {
                Text(L10n.shared.tr("status.harnesses")).tag(false)
                Text(L10n.shared.tr("status.modelList")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            VStack(spacing: 6) {
                if showsModels {
                    ForEach(models) { model in
                        usageRow(name: model.name, emoji: model.emoji,
                            tokens: model.totalTokens + (snapshot.includesCache ? model.totalCacheReadTokens : 0),
                            cost: model.formattedCost, speed: model.generationSpeed)
                    }
                } else {
                    ForEach(snapshot.rankedTools) { tool in
                        usageRow(name: tool.name, emoji: tool.emoji, tokens: snapshot.tokens(for: tool),
                            cost: tool.formattedCost, speed: harnessSpeeds[tool.name] ?? GenerationSpeed())
                    }
                }
            }
            .padding(.trailing, 3)
        }
        .padding(layout.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.purple.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private func usageRow(name: String, emoji: String, tokens: Int, cost: String, speed: GenerationSpeed) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                BrandIconView(name: name, fallback: emoji, size: 14)
                Text(name).lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 5) {
                compactValue("Tokens", TokenFormat.compact(tokens))
                Spacer(minLength: 0)
                compactValue(L10n.shared.tr("detail.cost"), cost)
                Spacer(minLength: 0)
                compactValue("t/s", speed.formatted).instantHint(speed.helpText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)

        .font(.system(size: 11)).monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary-usage-row-" + name)
    }

    private func compactValue(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    private var summaryToolbox: some View {
        StatusSummaryToolbox(side: side, onHistory: onHistory, onQuota: onQuota, onShare: onShare, onTool: onTool)
    }

}


enum StatusSummaryToolboxAction: String, CaseIterable, Identifiable {
    case model, network, local, quota, history, notebook, news, share
    var id: String { rawValue }
    var tool: QuickTool? { QuickTool(rawValue: rawValue) }
    var title: String { tool?.title ?? toolboxText("Ailyre速递", "Ailyre AI digest") }
    var hint: String { tool?.hint ?? toolboxText("在默认浏览器打开 Ailyre 新闻页", "Open the Ailyre news page in your default browser") }
    static func normalized(_ values: [String]) -> [Self] {
        var seen = Set<Self>()
        return values.compactMap(Self.init(rawValue:)).filter { seen.insert($0).inserted }
    }
    static func initialOrder(from tools: [QuickTool]) -> [Self] {
        // History, quota and sharing previously appeared in the fixed footer.
        normalized(tools.map(\.rawValue) + ["quota", "history", "news", "share"])
    }
}

@MainActor
private struct StatusSummaryToolbox: View {
    let side: CGFloat
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void
    let onTool: (QuickTool) -> Void
    @ObservedObject private var inherited = QuickToolPreferences.shared
    @AppStorage("TC_statusSummaryToolboxOrder.v1") private var storedOrder = ""
    @State private var editing = false
    private var items: [StatusSummaryToolboxAction] {
        guard let data = storedOrder.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else {
            return StatusSummaryToolboxAction.initialOrder(from: inherited.order)
        }
        return StatusSummaryToolboxAction.normalized(values)
    }
    private var columns: Int { side < 320 ? 1 : side < 480 ? 2 : 4 }
    private var rows: [[StatusSummaryToolboxAction]] {
        stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0+columns,items.count)]) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(toolboxText("工具箱", "Toolboxes")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { editing.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
                    .buttonStyle(.plain).instantHint(toolboxText("编辑总结面板的快捷按钮", "Edit summary shortcuts"))
                    .popover(isPresented: $editing) { editor }
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row) { item in
                                Button { open(item) } label: {
                                    HStack(spacing: 5) {
                                        if item == .news {
                                            AilyreNewsMark(template: true).frame(width: 16, height: 20).foregroundStyle(.orange)
                                        } else {
                                            Image(systemName: item.tool?.symbol ?? "square.grid.2x2").foregroundStyle(accent(item))
                                        }
                                        Text(item.title).lineLimit(1).minimumScaleFactor(0.75)
                                    }.font(.system(size: 10.5, weight: .medium))
                                        .frame(maxWidth: .infinity, minHeight: 20).padding(.vertical, 3)
                                }.buttonStyle(.glass).instantHint(item.hint)
                                    .accessibilityIdentifier("summary-tool.\(item.rawValue)")
                            }
                        }
                    }
                }
            }
        }.accessibilityIdentifier("summary-toolbox")
    }
    private func open(_ item: StatusSummaryToolboxAction) {
        switch item {
        case .history: onHistory()
        case .quota: onQuota()
        case .share: onShare()
        case .news: NSWorkspace.shared.open(URL(string: "https://www.ailyre.com/news/")!)
        default: if let tool = item.tool { onTool(tool) }
        }
    }
    private func accent(_ item: StatusSummaryToolboxAction) -> Color {
        switch item {
        case .model: return .cyan
        case .network, .history: return .teal
        case .local: return .mint
        case .quota: return .indigo
        case .notebook, .news, .share: return .orange
        }
    }
    private func setItems(_ values: [StatusSummaryToolboxAction]) {
        if let data = try? JSONEncoder().encode(values.map(\.rawValue)), let text = String(data: data, encoding: .utf8) { storedOrder = text }
    }
    private func move(_ item: StatusSummaryToolboxAction, by step: Int) {
        var values = items
        guard let index = values.firstIndex(of: item), values.indices.contains(index+step) else { return }
        values.swapAt(index,index+step);setItems(values)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toolboxText("总结面板快捷按钮", "Summary shortcuts")).font(.headline)
            ForEach(items + StatusSummaryToolboxAction.allCases.filter { !items.contains($0) }) { item in
                HStack {
                    Toggle(item.title, isOn: Binding(get: { items.contains(item) }, set: { enabled in
                        var values = items;values.removeAll { $0 == item };if enabled { values.append(item) };setItems(values)
                    })).toggleStyle(.checkbox)
                    Spacer()
                    Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(items.first == item || !items.contains(item)).instantHint(toolboxText("向前移", "Move earlier"))
                    Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(items.last == item || !items.contains(item)).instantHint(toolboxText("向后移", "Move later"))
                }
            }
            Button(toolboxText("恢复默认", "Reset to defaults")) { setItems(StatusSummaryToolboxAction.allCases) }
        }.buttonStyle(.bordered).controlSize(.small).padding(16).frame(width: 330)
    }
}


@MainActor
private struct StatusSummaryNotebookCard: View {
    @ObservedObject var store: NotebookStore
    var height: CGFloat
    var compact: Bool
    let onOpen: () -> Void
    private var entries: [NotebookEntry] { Array(store.pendingSummaryEntries.prefix(compact ? 2 : 3)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 4) {
                    Image(systemName: "note.text").foregroundStyle(.orange)
                    Text(toolboxText("行事本", "Notebook")).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(.secondary)
                }.font(.system(size: 11)).contentShape(Rectangle())
            }.buttonStyle(.plain).instantHint(toolboxText("打开行事本，记录想法或设置提醒", "Open your notebook to write or set a reminder"))
            if entries.isEmpty {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: "square.and.pencil").font(.system(size: 18)).foregroundStyle(.orange.opacity(0.65))
                        Text(toolboxText("随手记下想法与待办", "Capture a thought or task"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 5) {
                        Button { store.setCompleted(entry.id, true) } label: {
                            Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 15, height: 17)
                        }.buttonStyle(.plain).instantHint(toolboxText("标记为已完成", "Mark complete"))
                        Button { store.selectedID = entry.id; onOpen() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? toolboxText("未命名记录", "Untitled entry") : entry.title)
                                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                if let date = entry.remindAt {
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                        .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                } else if !entry.body.isEmpty {
                                    Text(entry.body).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).instantHint(toolboxText("打开这条记录", "Open this entry"))
                    }
                    if entry.id != entries.last?.id { Divider().opacity(0.5) }
                }
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Text(toolboxText("全部记录", "All entries") + " · \(store.pendingSummaryEntries.count)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.buttonStyle(.plain)
            }
        }
        .padding(9).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(LinearGradient(colors: [.orange.opacity(0.08), .yellow.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.orange.opacity(0.12), lineWidth: 0.7))
        .environment(\.locale, Locale(identifier: L10n.shared.language.rawValue))
        .accessibilityIdentifier("summary-notebook")
    }
}
