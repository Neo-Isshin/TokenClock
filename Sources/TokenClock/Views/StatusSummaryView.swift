import SwiftUI

/// A menu-bar overview of existing usage snapshots; opening it performs no I/O.
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
    var side: CGFloat = 500
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

    var body: some View {
        StatusSummaryContent(
            snapshot: snapshot, models: models, date: viewModel.dateString,
            tokens: viewModel.totalTokensFormatted, cost: viewModel.totalCostFormatted,
            isLoading: viewModel.isInitialLoading, side: side,
            onHistory: onHistory, onQuota: onQuota, onShare: onShare
        )
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
    var side: CGFloat = 500
    let onHistory: () -> Void
    let onQuota: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            HStack(spacing: 10) {
                tokenCard.frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    metric("detail.messages", value: isLoading ? "—" : "\(snapshot.totalMessages)",
                           icon: "bubble.left.and.bubble.right.fill", color: .indigo)
                    metric("detail.cost", value: cost, icon: "dollarsign.circle.fill", color: .orange)
                }
                .frame(width: side * 0.32)
            }
            .frame(height: 134)

            if isLoading {
                ProgressView(L10n.shared.tr("detail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.rankedTools.isEmpty {
                Text(L10n.shared.tr("status.empty"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    detailCard("status.tools", color: .teal) {
                        ForEach(snapshot.rankedTools) { tool in toolRow(tool) }
                    }
                    detailCard("status.models", color: .purple) {
                        ForEach(models.prefix(5)) { model in modelRow(model) }
                    }
                }
                .frame(maxHeight: .infinity)
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
        .padding(20)
        .frame(width: side, height: side)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(6)
        .accessibilityIdentifier("status-today-summary")
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.shared.tr("clock.todayTokens"), systemImage: "sparkle")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(tokens).font(.system(size: 43, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geometry in
                let tools = isLoading ? [] : snapshot.rankedTools.filter { snapshot.tokens(for: $0) > 0 }
                let width = max(0, geometry.size.width - CGFloat(max(0, tools.count - 1)) * 3)
                HStack(spacing: 3) {
                    ForEach(tools) { tool in
                        Capsule().fill(toolColor(tool.name).gradient)
                            .frame(width: width * Double(snapshot.tokens(for: tool)) / Double(max(1, snapshot.totalTokens)))
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [.cyan.opacity(0.17), .blue.opacity(0.08), .purple.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.cyan.opacity(0.15), lineWidth: 0.7) }
    }

    private func metric(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color.gradient)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.shared.tr(title)).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(color.opacity(0.1), lineWidth: 0.5) }
    }

    private func detailCard<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(color.gradient).frame(width: 6, height: 6)
                Text(L10n.shared.tr(title)).font(.system(size: 11, weight: .semibold))
            }
            ScrollView {
                VStack(spacing: 13, content: content)
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(color.opacity(0.09), lineWidth: 0.5) }
    }

    private func toolRow(_ tool: ToolUsage) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                BrandIconView(name: tool.name, fallback: tool.emoji, size: 14)
                Text(tool.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(TokenFormat.compact(snapshot.tokens(for: tool)))
                    .fontWeight(.semibold).monospacedDigit().layoutPriority(1)
            }
            .font(.system(size: 11))
            HStack {
                Text("\(tool.todayMessages) \(L10n.shared.tr("detail.messages"))")
                Spacer()
                Text(tool.formattedCost)
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let share = min(1, max(0, Double(snapshot.tokens(for: tool)) / Double(max(1, snapshot.totalTokens))))
                Capsule().fill(.primary.opacity(0.05))
                Capsule().fill(toolColor(tool.name).opacity(0.65).gradient)
                    .frame(width: geometry.size.width * share)
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }

    private func modelRow(_ model: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                BrandIconView(name: model.name, fallback: model.emoji, size: 14)
                Text(model.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Text(TokenFormat.compact(model.totalTokens + (snapshot.includesCache ? model.totalCacheReadTokens : 0)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer(minLength: 4)
                Text(model.formattedCost).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func toolColor(_ name: String) -> Color {
        let key = name.lowercased()
        if key.contains("codex") { return .cyan }
        if key.contains("claude") { return .orange }
        if key.contains("grok") { return .indigo }
        if key.contains("cursor") { return .blue }
        if key.contains("zcode") || key.contains("qwen") { return .mint }
        if key.contains("gemini") { return .purple }
        if key.contains("antigravity") { return .pink }
        return .teal
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
