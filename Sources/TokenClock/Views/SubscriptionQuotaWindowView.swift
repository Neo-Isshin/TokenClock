import SwiftUI

/// 独立订阅额度窗口。Claude 连接仅由用户主动触发；后台额度读取始终静默。
struct SubscriptionQuotaWindowView: View {
    @ObservedObject var viewModel: ViewModel
    var onLayoutChange: (Bool) -> Void = { _ in }
    var onEditAccount: (SubscriptionAccountRecord) -> Void = { _ in }
    @State private var isEditingOrder = false
    @State private var providerOrder: [SubscriptionProvider]
    @State private var expandedEmails: Set<String> = []
    @State private var costModesExpanded = false
    @State private var legacyClaudeExpanded = false

    init(
        viewModel: ViewModel,
        onLayoutChange: @escaping (Bool) -> Void = { _ in },
        onEditAccount: @escaping (SubscriptionAccountRecord) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onLayoutChange = onLayoutChange
        self.onEditAccount = onEditAccount
        _providerOrder = State(initialValue: Self.loadProviderOrder())
    }

    private var isLoading: Bool {
        viewModel.codexQuota.status == .loading ||
        viewModel.claudeQuota.status == .loading ||
        viewModel.antigravityQuota.status == .loading ||
        viewModel.cursorQuota.status == .loading ||
        viewModel.grokBotQuota.status == .loading ||
        viewModel.zhipuQuota.status == .loading
    }

    private var visibleProviders: [SubscriptionProvider] {
        providerOrder.filter(hasQuotaData)
    }

    @ViewBuilder
    private func dialGroupBadge(for provider: SubscriptionProvider) -> some View {
        if let group = viewModel.dialQuotaGroupNumber(for: provider) {
            Text(String(group))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var isTwoColumn: Bool { visibleProviders.count >= 4 }

    private var quotaColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 300), spacing: 14, alignment: .top),
              count: isTwoColumn ? 2 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
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
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.shared.tr("quota.dialDisplay"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 105), spacing: 12)],
                        alignment: .leading,
                        spacing: 7
                    ) {
                        ForEach(viewModel.dialQuotaProviderOptions) { provider in
                            let isSelected = viewModel.dialQuotaProviders.contains(provider)
                            Toggle(isOn: Binding(
                                get: { isSelected },
                                set: { value in
                                    if value != isSelected {
                                        viewModel.toggleDialQuotaProvider(provider)
                                    }
                                }
                            )) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(provider.dialQuotaColor.opacity(0.72))
                                        .frame(width: 7, height: 7)
                                    Text(viewModel.quotaDisplayName(for: provider))
                                        .lineLimit(1)
                                    dialGroupBadge(for: provider)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11, weight: .medium))
                            .disabled(
                                !isSelected && viewModel.dialQuotaProviders.count >= DialQuotaPager.maximumSelection
                            )
                        }
                    }
                    .help(L10n.shared.tr("quota.dialDisplayHelp"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            costModeDisclosure
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
            Divider()

            if visibleProviders.isEmpty {
                VStack(spacing: 10) {
                    if isLoading { ProgressView().controlSize(.regular) }
                    Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.questionmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n.shared.tr(isLoading ? "quota.loadingAll" : "quota.noActiveProviders"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: quotaColumns, alignment: .leading, spacing: 14) {
                        ForEach(Array(visibleProviders.enumerated()), id: \.element.id) { index, provider in
                        HStack(alignment: .top, spacing: 8) {
                            if isEditingOrder {
                                reorderControls(for: provider, at: index, count: visibleProviders.count)
                            }
                            providerView(provider)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: isTwoColumn ? 700 : 380,
               idealWidth: isTwoColumn ? 760 : 430,
               minHeight: 480, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier:L10n.shared.language.rawValue))
        .onAppear { onLayoutChange(isTwoColumn) }
        .onChange(of: isTwoColumn) { onLayoutChange($0) }
    }

    private var costModeDisclosure: some View {
        let tool = viewModel.visibleTools.first { $0.name == "Codex" }
        let split = tool?.costModes
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    costModesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: costModesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(L10n.shared.tr("quota.costMode.title"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 6)
                    Text(tool?.formattedCost ?? "—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.shared.tr(costModesExpanded ? "quota.costMode.expanded" : "quota.costMode.collapsed"))

            if costModesExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.shared.tr("quota.costMode.scope"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let split, split.requestCount > 0 {
                        ForEach(split.parts, id: \.mode) { part in
                            HStack(spacing: 6) {
                                Text(L10n.shared.tr(part.mode.labelKey))
                                    .font(.system(size: 11, weight: .medium))
                                if !part.rateBadge.isEmpty {
                                    Text(part.rateBadge).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                Text(L10n.shared.tr("quota.costMode.calls", part.requests))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(part.formattedCost)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(width: 85, alignment: .trailing)
                            }
                        }
                        Text(L10n.shared.tr("quota.costMode.note"))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.shared.tr("quota.costMode.empty"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 5)
            }
        }
    }

    @ViewBuilder
    private func providerView(_ provider: SubscriptionProvider) -> some View {
        let title = "\(provider.emoji) \(provider.displayName)"
        if provider == .claude, viewModel.claudeQuota.buckets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    BrandIconView(name: provider.displayName, fallback: provider.emoji, size: 18)
                    Text("Claude").font(.system(size: 13, weight: .bold, design: .rounded))
                    Spacer()
                    if providerIsLoading(provider) { ProgressView().controlSize(.small) }
                }
                Text(viewModel.claudeQuota.message ?? L10n.shared.tr("quota.claudeRecoveryHelp"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { viewModel.connectClaude() } label: {
                    Label(L10n.shared.tr("quota.claudeConnect"), systemImage: "person.crop.circle.badge.checkmark")
                }.buttonStyle(.bordered).controlSize(.small)
                Text(L10n.shared.tr("quota.claudeNoBackgroundPrompts"))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }.sectionContainer()
        } else if provider == .grokBot, viewModel.grokBotAuthorizationVisible {
            ZStack {
                accountProviderSection(provider, title: title)
                    .saturation(0)
                    .opacity(0.34)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.76))
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 19, weight: .semibold))
                    Text(L10n.shared.tr("quota.grokBotAuthorizationTitle"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("quota.grokBotAuthorizationBody"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        viewModel.authorizeGrokBotNativeAccess()
                    } label: {
                        if viewModel.grokBotNativeAccessState == .authorizing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L10n.shared.tr("quota.grokBotAuthorizing"))
                            }
                        } else {
                            Label(
                                L10n.shared.tr("quota.grokBotAuthorize"),
                                systemImage: "key"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.grokBotNativeAccessState == .authorizing)
                }
                .padding(16)
            }
        } else {
            accountProviderSection(provider, title: title)
        }
    }

    private func reorderControls(for provider: SubscriptionProvider, at index: Int, count: Int) -> some View {
        VStack(spacing: 4) {
            reorderButton("chevron.up", disabled: index == 0) { move(provider, by: -1) }
            reorderButton("chevron.down", disabled: index == count - 1) { move(provider, by: 1) }
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

    private func move(_ provider: SubscriptionProvider, by offset: Int) {
        let visible = visibleProviders
        guard let visibleSource = visible.firstIndex(of: provider) else { return }
        let visibleDestination = visibleSource + offset
        guard visible.indices.contains(visibleDestination),
              let source = providerOrder.firstIndex(of: provider),
              let destination = providerOrder.firstIndex(of: visible[visibleDestination]) else { return }
        providerOrder.swapAt(source, destination)
        UserDefaults.standard.set(
            providerOrder.map(\.rawValue),
            forKey: SettingsKey.subscriptionQuotaOrder.rawValue
        )
    }

    private func hasQuotaData(_ provider: SubscriptionProvider) -> Bool {
        if viewModel.isHiddenUnifiedQuotaAlias(provider), viewModel.subscriptionAccounts(for: provider).isEmpty { return false }
        switch provider {
        case .codex: return !viewModel.codexQuota.buckets.isEmpty
        case .claude: return true // Connect must be reachable without App/CLI credentials.
        case .antigravity: return !viewModel.antigravityQuota.groups.isEmpty
        case .cursor: return !viewModel.cursorQuota.groups.isEmpty
        case .grokBot:
            return !viewModel.grokBotQuota.groups.isEmpty || viewModel.grokBotAuthorizationVisible
        case .zhipu: return !viewModel.zhipuQuota.groups.isEmpty
        }
    }

    private static func loadProviderOrder() -> [SubscriptionProvider] {
        let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.subscriptionQuotaOrder.rawValue) ?? []
        var result = saved.compactMap(SubscriptionProvider.init(rawValue:))
        for provider in SubscriptionProvider.allCases where !result.contains(provider) {
            result.append(provider)
        }
        return result
    }

    private func accountProviderSection(_ provider: SubscriptionProvider, title: String) -> some View {
        let allAccounts = viewModel.subscriptionAccounts(for: provider)
        let legacyIDs = provider == .claude ? ClaudeQuotaIdentity.legacySnapshotIDs(in: allAccounts) : []
        let accounts = allAccounts.filter { !legacyIDs.contains($0.id) }
        let legacy = allAccounts.filter { legacyIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                if providerIsLoading(provider) { ProgressView().controlSize(.small) }
                let name = viewModel.quotaDisplayName(for: provider)
                BrandIconView(name: name, fallback: name == XSubscriptionQuota.title ? "𝕏" : provider.emoji, size: 18)
                Text(name).font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if provider == .claude {
                    if viewModel.claudeQuota.localAuthorizationRequired {
                        Button(L10n.shared.tr("quota.claudeReadLocal")) {
                            NSApp.activate(ignoringOtherApps:true)
                            viewModel.authorizeClaudeLocal()
                        }.buttonStyle(.bordered).controlSize(.small)
                            .instantHint(L10n.shared.tr("quota.claudeLocalAuthHint"))
                    } else {
                        Button(L10n.shared.tr("quota.claudeConnect")) { viewModel.connectClaude() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if accounts.count > 1 { metaChip(L10n.shared.tr("quota.accounts", accounts.count)) }
            }
            if provider == .claude {
                Text(L10n.shared.tr("quota.claudeSharedScope")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                if viewModel.claudeQuota.localAuthorizationRequired {
                    if !accounts.isEmpty {
                        Text(viewModel.claudeQuota.message ?? L10n.shared.tr("quota.claudeLocalAuthorizationRequired"))
                            .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Button(L10n.shared.tr("quota.claudeWebFallback")) { viewModel.connectClaude() }
                        .buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.secondary)
                }
            }
            if accounts.isEmpty {
                unavailableRow(provider == .claude && viewModel.claudeQuota.status != .loading
                    ? (viewModel.claudeQuota.message ?? L10n.shared.tr("quota.claudePassiveUnavailable"))
                    : provider == .codex && !viewModel.codexQuota.buckets.isEmpty
                        ? QuotaAccountLabels.unverified : L10n.shared.tr("quota.loadingProvider", title))
            } else {
                ForEach(accounts) { accountCard($0) }
            }
            if !legacy.isEmpty {
                DisclosureGroup(L10n.shared.tr("quota.claudeLegacySnapshots",legacy.count),isExpanded:$legacyClaudeExpanded) {
                    VStack(spacing:8) {ForEach(legacy) {accountCard($0)}}.padding(.top,6)
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
        .sectionContainer()
    }

    private func accountCard(_ account: SubscriptionAccountRecord) -> some View {
        let isCurrent = viewModel.activeSubscriptionAccountIDs[account.provider] == account.id
        let isStale = DialQuotaResolver.freshGroups(
            account.groups, refreshedAt: account.refreshedAt
        ).isEmpty
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(account.displayName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isStale { metaChip(L10n.shared.tr("quota.snapshotStale")) }
                if let plan = account.effectivePlan {
                    metaChip(L10n.shared.tr("quota.plan", displayPlan(plan)))
                }
                Button {
                    expandedEmails.remove(account.id)
                    onEditAccount(account)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(L10n.shared.tr("quota.editAccount"))
                if account.revealsEmailOnDemand {
                    Button {
                        if expandedEmails.contains(account.id) {
                            expandedEmails.remove(account.id)
                        } else {
                            expandedEmails.insert(account.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expandedEmails.contains(account.id) ? 90 : 0))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.shared.tr("quota.showEmail"))
                }
            }
            if account.isUnifiedSubscription {
                Text(XSubscriptionQuota.title + " · " + (account.detectedPlan ?? ""))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(XSubscriptionQuota.scopeLabel)
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(BillingText.summary(account.effectiveBilling))
                .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { viewModel.isDialAccountSelected(account) },
                set: { _ in viewModel.toggleDialAccount(account) }
            )) {
                HStack(spacing: 5) {
                    Text(QuotaAccountLabels.showOnDial)
                    if viewModel.isDialAccountSelected(account) {
                        dialGroupBadge(for: account.provider)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 10.5))
            .disabled(!viewModel.dialQuotaProviders.contains(account.provider) && viewModel.dialQuotaProviders.count >= DialQuotaPager.maximumSelection)
            if viewModel.isDialAccountSelected(account) && (isStale || !isCurrent) {
                Text(QuotaAccountLabels.unavailable).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if account.revealsEmailOnDemand,
               expandedEmails.contains(account.id),
               let email = account.email {
                Label(email, systemImage: "envelope")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(account.groups) { group in
                if account.groups.count > 1 || group.name != "Subscription" {
                    Text(localizedQuotaName(group.name))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(group.buckets) { quotaCard($0) }
            }
            if account.hasUnlimitedCredits {
                metaChip(L10n.shared.tr("quota.unlimited"))
            } else if let balance = account.creditBalance, balance != "0" {
                metaChip(L10n.shared.tr("quota.creditBalance", balance))
            }
            if account.resetCreditCount > 0 {
                metaChip(L10n.shared.tr("quota.resetCredits", account.resetCreditCount))
            }
            sourceRow(account.source, refreshedAt: account.refreshedAt, isCurrent: isCurrent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5))
    }

    private func providerIsLoading(_ provider: SubscriptionProvider) -> Bool {
        switch provider {
        case .codex: return viewModel.codexQuota.status == .loading
        case .claude: return viewModel.claudeQuota.status == .loading
        case .antigravity: return viewModel.antigravityQuota.status == .loading
        case .cursor: return viewModel.cursorQuota.status == .loading
        case .grokBot: return viewModel.grokBotQuota.status == .loading
        case .zhipu: return viewModel.zhipuQuota.status == .loading
        }
    }

    private func quotaCard(_ bucket: CodexQuotaBucket) -> some View {
        let accent = quotaAccent(for: bucket.remainingPercent)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.name.isEmpty ? quotaWindowLabel(minutes: bucket.windowMinutes) : localizedQuotaName(bucket.name))
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

    private func sourceRow(_ source: String, refreshedAt: Date?, isCurrent: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(isCurrent ? Color.green : Color.orange).frame(width: 5, height: 5)
            Text(isCurrent ? source : L10n.shared.tr("quota.savedSnapshot"))
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

    private func localizedQuotaName(_ raw: String) -> String {
        switch raw {
        case "Subscription": return toolboxText("订阅", "Subscription")
        case "Cursor Models": return L10n.shared.tr("quota.dial.cursorModels")
        case "Other Models": return L10n.shared.tr("quota.dial.otherModels")
        case "Weekly quota": return L10n.shared.tr("quota.weekly")
        case "5-hour quota": return toolboxText("5 小时额度", "5-hour quota")
        case "Monthly MCP quota": return toolboxText("MCP 月额度", "Monthly MCP quota")
        case "Extra Usage": return toolboxText("额外用量", "Extra Usage")
        case "Claude Apps": return toolboxText("Claude 应用", "Claude Apps")
        default: return raw
        }
    }

    private func quotaWindowLabel(minutes: Int) -> String {
        if minutes == 10_080 { return L10n.shared.tr("quota.weekly") }
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) { return L10n.shared.tr("quota.days", minutes / 1_440) }
        if minutes >= 60, minutes.isMultiple(of: 60) { return L10n.shared.tr("quota.hours", minutes / 60) }
        if minutes > 0 { return L10n.shared.tr("quota.minutes", minutes) }
        return L10n.shared.tr("quota.period")
    }

    private func displayPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro_5x", "pro-5x": return "Pro 5x"
        case "pro_20x", "pro-20x": return "Pro 20x"
        case "max_5x", "default_claude_max_5x": return "Max 5x"
        case "max_20x", "default_claude_max_20x": return "Max 20x"
        case "pro_plus", "pro+": return "Pro+"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
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

struct SubscriptionAccountEditorView: View {
    let account: SubscriptionAccountRecord
    let onSave: (String, String?, SubscriptionBillingEdit) -> Void
    let onCancel: () -> Void
    @State private var note: String
    @State private var selectedPlan: String
    @State private var manualDateEnabled: Bool
    @State private var billingDate: Date
    @State private var billingCycle: SubscriptionBillingCycle
    @State private var autoRenews: Bool
    @State private var reminderEnabled: Bool
    @State private var reminderDays: Int

    init(
        account: SubscriptionAccountRecord,
        onSave: @escaping (String, String?, SubscriptionBillingEdit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.account = account
        self.onSave = onSave
        self.onCancel = onCancel
        _note = State(initialValue: account.note)
        _selectedPlan = State(initialValue: account.manualPlan ?? "")
        let info = account.effectiveBilling
        let reminders = account.billingReminders ?? BillingReminderSettings()
        _manualDateEnabled = State(initialValue: account.manualBilling != nil)
        _billingDate = State(initialValue: info?.date ?? Date())
        _billingCycle = State(initialValue: info?.cycle ?? .monthly)
        _autoRenews = State(initialValue: info?.autoRenews ?? true)
        _reminderEnabled = State(initialValue: reminders.enabled)
        _reminderDays = State(initialValue: reminders.safeDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.shared.tr("quota.editAccount"))
                .font(.system(size: 17, weight: .bold, design: .rounded))
            if let email = account.email {
                Label(email, systemImage: "envelope")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.shared.tr("quota.accountNote"))
                    .font(.system(size: 11, weight: .semibold))
                SubscriptionAccountNoteField(
                    text: $note,
                    placeholder: L10n.shared.tr("quota.accountNotePlaceholder")
                )
                .frame(height: 22)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.shared.tr("quota.planLabel"))
                    .font(.system(size: 11, weight: .semibold))
                Picker("", selection: $selectedPlan) {
                    Text(autoPlanLabel).tag("")
                    ForEach(planOptions, id: \.self) { plan in Text(plan).tag(plan) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(BillingText.title).font(.system(size: 12, weight: .semibold))
                Text(BillingText.summary(account.detectedBilling))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(BillingText.manual, isOn: $manualDateEnabled)
                if manualDateEnabled {
                    DatePicker("", selection: $billingDate, displayedComponents: .date).labelsHidden()
                    Picker("", selection: $billingCycle) {
                        ForEach(SubscriptionBillingCycle.allCases, id: \.self) { cycle in Text(cycle.title).tag(cycle) }
                    }.labelsHidden()
                    Toggle(BillingText.autoRenew, isOn: $autoRenews)
                }
                Toggle(BillingText.enabled, isOn: $reminderEnabled)
                Picker(BillingText.reminder, selection: $reminderDays) {
                    ForEach(BillingReminderSettings.dayOptions, id: \.self) { day in Text(String(day)).tag(day) }
                }
                .pickerStyle(.segmented)
                .disabled(!reminderEnabled)
                Text(BillingText.localOnly).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11))
            HStack {
                Spacer()
                Button(L10n.shared.tr("quota.cancel")) { onCancel() }
                Button(L10n.shared.tr("quota.save")) {
                    let manual = manualDateEnabled ? SubscriptionBillingInfo(
                        date: billingDate, cycle: billingCycle, autoRenews: autoRenews, source: "manual", observedAt: Date()
                    ) : nil
                    onSave(note, selectedPlan.isEmpty ? nil : selectedPlan, SubscriptionBillingEdit(
                        manual: manual, reminders: BillingReminderSettings(enabled: reminderEnabled, days: reminderDays)))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var autoPlanLabel: String {
        let detected = account.detectedPlan.map(Self.displayPlan) ?? L10n.shared.tr("quota.unknownPlan")
        return L10n.shared.tr("quota.detectedPlan", detected)
    }

    private var planOptions: [String] {
        let values: [String]
        switch account.provider {
        case .codex: values = ["Plus", "Pro", "Pro 5x", "Pro 20x", "Business", "Enterprise", "Edu"]
        case .claude: values = ["Pro", "Max 5x", "Max 20x", "Team", "Enterprise"]
        case .cursor: values = ["Hobby", "Start", "Pro", "Pro+", "Ultra", "Teams"]
        case .grokBot: values = []
        case .zhipu: values = ["Start", "Pro"]
        case .antigravity: values = []
        }
        let detected = account.detectedPlan.map(Self.displayPlan)
        return values.filter { $0 != detected }
    }

    private static func displayPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro_5x", "pro-5x": return "Pro 5x"
        case "pro_20x", "pro-20x": return "Pro 20x"
        case "max_5x", "default_claude_max_5x": return "Max 5x"
        case "max_20x", "default_claude_max_20x": return "Max 20x"
        case "pro_plus", "pro+": return "Pro+"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The quota window may live at status-bar level while TokenClock runs without a
/// normal app window. SwiftUI's TextField can then display its field editor but
/// fail to make the sheet key on newer macOS builds. Use a native field that
/// explicitly activates its own window before requesting the first responder.
private struct SubscriptionAccountNoteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ActivatingTextField {
        let field = ActivatingTextField(string: text)
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBezeled = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: ActivatingTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    final class ActivatingTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                NSApp.activate(ignoringOtherApps: true)
                _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
                window.makeKeyAndOrderFront(nil)
                _ = window.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) {
            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            window?.makeKey()
            _ = window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
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
