import SwiftUI

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
            comparison: history.comparison.compare(to: snapshot.tools, includesCache: snapshot.includesCache),
            timeline: StatusSummaryTimeline.events(quotas: viewModel.statusSummaryQuotaIndicators,
                records: viewModel.subscriptionAccounts, activeIDs: viewModel.activeSubscriptionAccountIDs),
            quotas: viewModel.statusSummaryQuotaIndicators, isQuotaLoading: viewModel.statusSummaryQuotaLoading,
            harnessSpeeds: Dictionary(uniqueKeysWithValues: snapshot.rankedTools.map { ($0.name, speedStore.summary(provider: $0.name)) }),
            onHistory: onHistory, onQuota: onQuota, onShare: onShare
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
    var comparison = StatusSummaryComparison(completedHours: 0)
    var timeline: [StatusSummaryTimelineEvent] = []
    var quotas: [StatusSummaryQuota] = []
    var isQuotaLoading = false
    var harnessSpeeds: [String: GenerationSpeed] = [:]
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void
    @State private var showsModels = false
    @State private var showsTimeline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.cyan.gradient)
                        .frame(width: 38, height: 38)
                        .background(.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TOKENCLOCK").font(.system(size: 9, weight: .semibold)).tracking(1.8)
                            .foregroundStyle(.secondary)
                        Text(L10n.shared.tr("status.summary"))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                    }
                }
                Spacer(minLength: 8)
                Text(date).font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    .frame(maxWidth: 125, alignment: .trailing)
            }

            tokenCard
            quotaStrip

            if isLoading {
                ProgressView(L10n.shared.tr("detail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.rankedTools.isEmpty {
                Text(L10n.shared.tr("status.empty"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                usageTable
            }

            VStack(spacing: 9) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        action("detail.historyUsage", icon: "clock.arrow.circlepath", color: .teal, perform: onHistory)
                        action("detail.subscriptionQuota", icon: "gauge.with.dots.needle.50percent", color: .indigo, perform: onQuota)
                        action("status.share", icon: "square.and.arrow.up", color: .orange, perform: onShare)
                    }
                }
                Text(L10n.shared.tr(snapshot.includesCache ? "status.cacheIncluded" : "status.cacheExcluded"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: side, height: side)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(6)
        .accessibilityIdentifier("status-today-summary")
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.shared.tr("clock.todayTokens"), systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(comparisonCaption + " " + deltaText(comparison.tokenDelta, money: false)
                         + (comparison.isPartial ? " · " + L10n.shared.tr("status.comparisonPartial") : ""))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(comparison.tokenDelta == nil ? Color.secondary : .teal)
                        .help(comparisonHelp)
                }
                Spacer()
                Text(tokens).font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            HStack {
                Label(isLoading ? "—" : "\(snapshot.totalMessages)", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                Label(L10n.shared.tr("status.cacheReads") + " " + (isLoading ? "—" : TokenFormat.compact(snapshot.cacheReadTokens))
                      + " · " + (isLoading ? "—" : (snapshot.cacheShare.map { String(format: "%.1f%%", $0 * 100) } ?? "—")),
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.teal).help(L10n.shared.tr("status.cacheShareHelp"))
                Spacer()
                Text("\(L10n.shared.tr("detail.cost"))  \(cost)"
                     + (comparison.costDelta.map { " · " + deltaText($0, money: true) } ?? ""))
                    .help(comparisonHelp)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            hourlyChart
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [.cyan.opacity(0.17), .blue.opacity(0.08), .purple.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.cyan.opacity(0.15), lineWidth: 0.7) }
    }

    private var hourlyChart: some View {
        let values = hourly.hours.map { $0.displayedTokens(includingCache: snapshot.includesCache) }
        let maximum = max(1, values.max() ?? 0)
        let partial = values.reduce(0, +) != snapshot.totalTokens
            || (snapshot.includesCache && hourly.hours.contains { !$0.cacheIsExact })
        return VStack(spacing: 3) {
            HStack {
                Text(HourlyOverviewLabels.title)
                Spacer()
                if partial {
                    Label(L10n.shared.tr("status.partialHourly"), systemImage: "info.circle")
                        .help(HourlyOverviewLabels.partial)
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(hourly.hours) { hour in
                        let value = hour.displayedTokens(includingCache: snapshot.includesCache)
                        let label = HourlyOverviewLabels.label(hourly.day + String(format: "-%02d", hour.hour))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(hour.hasRecords ? Color.cyan.opacity(0.75).gradient : Color.primary.opacity(0.07).gradient)
                            .frame(maxWidth: .infinity)
                            .frame(height: value > 0 ? max(2, geometry.size.height * Double(value) / Double(maximum)) : 1)
                            .frame(height: geometry.size.height, alignment: .bottom)
                            .contentShape(Rectangle())
                            .help(label + " · " + (hour.hasRecords ? "\(TokenFormat.compact(value)) tokens" : L10n.shared.tr("status.noHourlyRecord")))
                            .accessibilityLabel(label + ": " + (hour.hasRecords ? "\(value) tokens" : L10n.shared.tr("status.noHourlyRecord")))
                    }
                }
            }
            .frame(height: 53)
            HStack {
                ForEach([0, 6, 12, 18, 23], id: \.self) { hour in
                    if hour > 0 { Spacer() }
                    Text(String(format: "%02d", hour))
                }
            }
            .font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var quotaStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.shared.tr("detail.subscriptionQuota")).font(.system(size: 11, weight: .semibold))
                if isQuotaLoading { ProgressView().controlSize(.mini) }
                Spacer()
            }
            if quotas.isEmpty {
                Button(L10n.shared.tr(isQuotaLoading ? "quota.loadingAll" : "status.noReadableQuota"), action: onQuota)
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(quotas) { indicator in
                            Button(action: onQuota) {
                                VStack(spacing: 3) {
                                    summaryRing(indicator.indicator)
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
                                            Text(quotaResetDate(reset.resetsAt)).monospacedDigit().fixedSize()
                                        }
                                        .font(.system(size: 8)).foregroundStyle(.secondary)
                                        .help(resetHelp(reset))
                                    }
                                }
                                .frame(width: 124)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(([indicator.displayName, indicator.accountName].compactMap { $0 }
                                + indicator.details.map { L10n.shared.tr($0.labelKey) + " " + String(format: "%.0f%%", $0.remainingPercent) })
                                .joined(separator: "\n"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }
            timelineView
        }
        .padding(10)
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
                        HStack(spacing: 6) {
                            Circle().fill(event.kind == .reset ? Color.cyan : .orange).frame(width: 4, height: 4)
                            Text(event.name + " · " + L10n.shared.tr(event.titleKey)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(timelineDate(event)).monospacedDigit().foregroundStyle(.secondary)
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

    private func summaryRing(_ indicator: DialQuotaIndicator) -> some View {
        let color = indicator.provider == .zhipu ? Color.primary : indicator.provider.dialQuotaColor
        let centerLabel = QuotaCenterLabel(remaining: indicator.outerRemainingPercent)
        return ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 4)
            Circle().trim(from: 0, to: indicator.outerRemainingPercent / 100)
                .stroke(color.opacity(0.75).gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let inner = indicator.innerRemainingPercent {
                Circle().inset(by: 7).stroke(.primary.opacity(0.06), lineWidth: 2)
                Circle().inset(by: 7).trim(from: 0, to: inner / 100)
                    .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let third = indicator.thirdRemainingPercent {
                Circle().inset(by: 11).stroke(.primary.opacity(0.06), lineWidth: 1.3)
                Circle().inset(by: 11).trim(from: 0, to: third / 100)
                    .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(centerLabel.text)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                if centerLabel.showsPercent {
                    Text("%")
                        .font(.system(size: 8, weight: .regular, design: .rounded))
                }
            }
            .monospacedDigit()
            .frame(width: indicator.thirdRemainingPercent == nil ? nil : 20)
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(3).frame(width: 48, height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.shared.tr("quota.dialAccessibility", indicator.provider.displayName,
                                              Int(indicator.outerRemainingPercent.rounded()))))
    }

    private var usageTable: some View {
        VStack(spacing: 8) {
            Picker("", selection: $showsModels) {
                Text(L10n.shared.tr("status.harnesses")).tag(false)
                Text(L10n.shared.tr("status.modelList")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 12) {
                Text(showsModels ? L10n.shared.tr("detail.model") : "Harness").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 68, alignment: .trailing)
                Text(L10n.shared.tr("detail.cost")).frame(width: 64, alignment: .trailing)
                Text("t/s").frame(width: 40, alignment: .trailing).help(L10n.shared.tr("detail.generationSpeedHelp"))
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
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
            .scrollIndicators(.automatic)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(.purple.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private func usageRow(name: String, emoji: String, tokens: Int, cost: String, speed: GenerationSpeed) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                BrandIconView(name: name, fallback: emoji, size: 14)
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(TokenFormat.compact(tokens)).frame(width: 68, alignment: .trailing)
            Text(cost).frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
            Text(speed.formatted).frame(width: 40, alignment: .trailing).help(speed.helpText)
        }
        .font(.system(size: 11)).monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func action(_ title: String, icon: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(L10n.shared.tr(title)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
        }
        .buttonStyle(.glass)
    }
}
