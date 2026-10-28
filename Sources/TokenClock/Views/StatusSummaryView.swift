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
    var quotas: [StatusSummaryQuota] = []
    var isQuotaLoading = false
    var harnessSpeeds: [String: GenerationSpeed] = [:]
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void
    @State private var showsModels = false

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
                Label(L10n.shared.tr("clock.todayTokens"), systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(tokens).font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            HStack {
                Label(isLoading ? "—" : "\(snapshot.totalMessages)", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                Text("\(L10n.shared.tr("detail.cost"))  \(cost)")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
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
                    HStack(spacing: 14) {
                        ForEach(quotas) { indicator in
                            Button(action: onQuota) {
                                VStack(spacing: 3) {
                                    summaryRing(indicator.indicator)
                                    HStack(spacing: 3) {
                                        BrandIconView(name: indicator.displayName,
                                            fallback: indicator.subscriptionName == nil ? indicator.provider.emoji : "𝕏", size: 11)
                                        Text(indicator.displayName).font(.system(size: 9)).lineLimit(1)
                                    }
                                }
                                .frame(width: 75)
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
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 15))
    }

    private func summaryRing(_ indicator: DialQuotaIndicator) -> some View {
        let color = indicator.provider == .zhipu ? Color.primary : indicator.provider.dialQuotaColor
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
            HStack(spacing: 0) {
                Text(String(format: "%.0f", indicator.outerRemainingPercent)).fontWeight(.bold)
                Text("%")
            }
            .font(.system(size: 10, design: .rounded)).monospacedDigit()
        }
        .padding(3).frame(width: 48, height: 48)
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
