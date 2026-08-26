import SwiftUI

/// 独立的订阅额度窗口。所有网络/本地服务读取都由用户打开窗口或点击刷新时触发。
struct SubscriptionQuotaWindowView: View {
    private enum QuotaProvider: String, CaseIterable, Identifiable {
        case codex, claude, antigravity, cursor
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: ViewModel
    @State private var isEditingOrder = false
    @State private var providerOrder: [QuotaProvider]

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        _providerOrder = State(initialValue: Self.loadProviderOrder())
    }

    private var isLoading: Bool {
        viewModel.codexQuota.status == .loading ||
        viewModel.claudeQuota.status == .loading ||
        viewModel.antigravityQuota.status == .loading ||
        viewModel.cursorQuota.status == .loading
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.shared.tr("quota.windowTitle"))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("quota.windowSubtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isEditingOrder.toggle()
                } label: {
                    Label(
                        L10n.shared.tr(isEditingOrder ? "quota.finishOrder" : "quota.editOrder"),
                        systemImage: isEditingOrder ? "checkmark" : "arrow.up.arrow.down"
                    )
                }
                .buttonStyle(.bordered)
                Button { viewModel.refreshSubscriptionQuotas() } label: {
                    Label(L10n.shared.tr("quota.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 14) {
                    ForEach(Array(providerOrder.enumerated()), id: \.element.id) { index, provider in
                        HStack(alignment: .top, spacing: 8) {
                            if isEditingOrder {
                                reorderControls(for: provider, at: index)
                            }
                            providerView(provider)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 380, idealWidth: 430, minHeight: 480, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func providerView(_ provider: QuotaProvider) -> some View {
        switch provider {
        case .codex: codexSection
        case .claude: claudeSection
        case .antigravity:
            providerSection(
                title: "🛸 Antigravity",
                snapshot: viewModel.antigravityQuota,
                unavailableKey: "quota.antigravityUnavailable"
            )
        case .cursor:
            providerSection(
                title: "🖱️ Cursor",
                snapshot: viewModel.cursorQuota,
                unavailableKey: "quota.cursorUnavailable"
            )
        }
    }

    private func reorderControls(for provider: QuotaProvider, at index: Int) -> some View {
        VStack(spacing: 4) {
            reorderButton("chevron.up", disabled: index == 0) { move(provider, by: -1) }
            reorderButton("chevron.down", disabled: index == providerOrder.count - 1) { move(provider, by: 1) }
        }
        .padding(.top, 8)
    }

    private func reorderButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(Color.primary.opacity(disabled ? 0.035 : 0.09)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func move(_ provider: QuotaProvider, by offset: Int) {
        guard let source = providerOrder.firstIndex(of: provider) else { return }
        let destination = source + offset
        guard providerOrder.indices.contains(destination) else { return }
        providerOrder.swapAt(source, destination)
        UserDefaults.standard.set(
            providerOrder.map(\.rawValue),
            forKey: SettingsKey.subscriptionQuotaOrder.rawValue
        )
    }

    private static func loadProviderOrder() -> [QuotaProvider] {
        let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.subscriptionQuotaOrder.rawValue) ?? []
        var result = saved.compactMap(QuotaProvider.init(rawValue:))
        for provider in QuotaProvider.allCases where !result.contains(provider) {
            result.append(provider)
        }
        return result
    }

    private var codexSection: some View {
        quotaSection(
            title: "🤖 Codex",
            plan: viewModel.codexQuota.planType,
            status: viewModel.codexQuota.status,
            buckets: viewModel.codexQuota.buckets,
            unavailableKey: "quota.codexUnavailable",
            source: viewModel.codexQuota.source == .appServer
                ? L10n.shared.tr("quota.liveSource") : L10n.shared.tr("quota.logSource"),
            refreshedAt: viewModel.codexQuota.refreshedAt
        ) {
            if viewModel.codexQuota.hasUnlimitedCredits {
                metaChip(L10n.shared.tr("quota.unlimited"))
            } else if let balance = viewModel.codexQuota.creditBalance, balance != "0" {
                metaChip(L10n.shared.tr("quota.creditBalance", balance))
            }
            if viewModel.codexQuota.resetCreditCount > 0 {
                metaChip(L10n.shared.tr("quota.resetCredits", viewModel.codexQuota.resetCreditCount))
            }
        }
    }

    private var claudeSection: some View {
        quotaSection(
            title: "✳️ Claude Code",
            plan: viewModel.claudeQuota.planType,
            status: viewModel.claudeQuota.status,
            buckets: viewModel.claudeQuota.buckets,
            unavailableKey: "quota.claudeUnavailable",
            source: L10n.shared.tr("quota.claudeSource"),
            refreshedAt: viewModel.claudeQuota.refreshedAt
        ) { EmptyView() }
    }

    private func providerSection(
        title: String,
        snapshot: ProviderQuotaSnapshot,
        unavailableKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            providerHeader(title, plan: snapshot.planType, loading: snapshot.status == .loading)
            if snapshot.groups.isEmpty {
                unavailableRow(snapshot.status == .loading
                    ? L10n.shared.tr("quota.loadingProvider", title)
                    : (snapshot.message ?? L10n.shared.tr(unavailableKey)))
            } else {
                ForEach(snapshot.groups) { group in
                    if snapshot.groups.count > 1 || group.name != "Subscription" {
                        Text(group.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.buckets) { quotaCard($0) }
                }
                sourceRow(snapshot.source, refreshedAt: snapshot.refreshedAt)
            }
        }
        .sectionContainer()
    }

    private func quotaSection<Meta: View>(
        title: String,
        plan: String?,
        status: CodexQuotaStatus,
        buckets: [CodexQuotaBucket],
        unavailableKey: String,
        source: String,
        refreshedAt: Date?,
        @ViewBuilder meta: () -> Meta
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            providerHeader(title, plan: plan, loading: status == .loading)
            if buckets.isEmpty {
                unavailableRow(L10n.shared.tr(status == .loading ? "quota.loadingProvider" : unavailableKey, title))
            } else {
                ForEach(buckets) { quotaCard($0) }
                HStack(spacing: 6) { meta(); Spacer(minLength: 0) }
                sourceRow(source, refreshedAt: refreshedAt)
            }
        }
        .sectionContainer()
    }

    private func providerHeader(_ title: String, plan: String?, loading: Bool) -> some View {
        HStack(spacing: 7) {
            if loading { ProgressView().controlSize(.small) }
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            if let plan, !plan.isEmpty {
                metaChip(L10n.shared.tr("quota.plan", displayPlan(plan)))
            }
        }
    }

    private func quotaCard(_ bucket: CodexQuotaBucket) -> some View {
        let accent = quotaAccent(for: bucket.remainingPercent)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.name.isEmpty ? quotaWindowLabel(minutes: bucket.windowMinutes) : bucket.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(quotaWindowLabel(minutes: bucket.windowMinutes))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.0f%% %@", bucket.remainingPercent, L10n.shared.tr("quota.remainingLabel")))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(accent)
                        .frame(width: max(bucket.remainingPercent > 0 ? 3 : 0,
                                          geometry.size.width * bucket.remainingPercent / 100))
                }
            }
            .frame(height: 8)
            if let reset = bucket.resetsAt {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise.circle")
                    Text(resetLabel(reset))
                    Spacer()
                    Text(absoluteDate(reset))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func unavailableRow(_ message: String) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func sourceRow(_ source: String, refreshedAt: Date?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Text(source)
            Spacer()
            if let refreshedAt { Text(L10n.shared.tr("quota.updated", relativeDate(refreshedAt))) }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
    }

    private func metaChip(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func quotaAccent(for remaining: Double) -> Color {
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
    }

    private func quotaWindowLabel(minutes: Int) -> String {
        if minutes == 10_080 { return L10n.shared.tr("quota.weekly") }
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) { return L10n.shared.tr("quota.days", minutes / 1_440) }
        if minutes >= 60, minutes.isMultiple(of: 60) { return L10n.shared.tr("quota.hours", minutes / 60) }
        if minutes > 0 { return L10n.shared.tr("quota.minutes", minutes) }
        return L10n.shared.tr("quota.period")
    }

    private func displayPlan(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func resetLabel(_ date: Date) -> String {
        L10n.shared.tr("quota.resetsRelative", relativeDate(date))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateFormat = L10n.shared.language == .en ? "MMM d · h:mm a" : "M月d日 · HH:mm"
        return formatter.string(from: date)
    }
}

private extension View {
    func sectionContainer() -> some View {
        padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.6))
    }
}

