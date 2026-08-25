import SwiftUI

/// 将 token 数格式化为「占总数百分比」字符串：0 → "-"，(0%,1%) → "<1%"，其余取整（与缓存率风格一致）。
private func formatPercent(_ tokens: Int, of total: Int) -> String {
    if tokens <= 0 || total <= 0 { return "-" }
    let pct = Double(tokens) / Double(total) * 100
    if pct < 1 { return "<1%" }
    return String(format: "%.0f%%", pct)
}

/// 数值列按显示模式取文案（两态）：tokens=用量/消息数；costPercent=费用/占比。
/// includeCacheRead=true 时用量列显示「含缓存」口径（tokens + cacheRead）。
private func primaryValueText(tokens: Int, cacheRead: Int, cost: CostEstimate,
                              mode: DetailValueMode, includeCacheRead: Bool) -> String {
    switch mode {
    case .tokens:
        let shown = includeCacheRead ? tokens + cacheRead : tokens
        return TokenFormat.compact(shown)
    case .costPercent:
        return tokens > 0 ? CostFormat.estimate(cost) : "—"
    }
}

/// 次列（消息数 ↔ 占比）
private func secondaryValueText(tokens: Int, cacheRead: Int, messages: Int,
                                mode: DetailValueMode, grandTotal: Int, includeCacheRead: Bool) -> String {
    switch mode {
    case .tokens: return "\(messages)"
    case .costPercent:
        let shown = includeCacheRead ? tokens + cacheRead : tokens
        return formatPercent(shown, of: grandTotal)
    }
}

/// 小型 chip 按钮的按压反馈：按下时轻微缩放 + 降透明，给纯文字 toggle 一个"可点"手感。
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 展开态详情列表（主题感知，支持 session/agent 展开）
struct DetailDropdownView: View {
    let tools: [ToolUsage]
    var theme: ClockFaceTheme = .classic
    /// Glass 版可覆写详情面板文字色；nil 时跟随表盘主题。
    var dropdownTextColorOverride: Color? = nil
    var weather: WeatherInfo = WeatherInfo()
    var localizedCityName: String = ""
    /// 首次数据读取中：为 true 时用加载提示取代（基于 mock 的）工具列表，避免误导
    var isLoading: Bool = false

    /// 当前分组模式（按会话 / 按模型）
    var groupingMode: GroupingMode = .session
    /// 分组模式切换回调
    var onGroupingChange: ((GroupingMode) -> Void)? = nil

    /// 数值显示模式（用量 / 占比 / 费用）
    var valueMode: DetailValueMode = .tokens
    /// 显示模式循环切换回调
    var onValueModeChange: ((DetailValueMode) -> Void)? = nil

    /// 用量口径：true=token 展示包含缓存读（详情快捷按钮切换）
    var usageIncludesCache: Bool = false
    var onUsageIncludesCacheToggle: (() -> Void)? = nil

    var quickContrastPreset: QuickContrastPreset? = nil
    var onQuickContrast: (() -> Void)? = nil
    var onHistoryUsage: (() -> Void)? = nil
    var onSubscriptionQuota: (() -> Void)? = nil

    /// Codex 剩余额度面板。额度只在点击后按需读取，不参与 30 秒用量扫描。
    var showsCodexQuota: Bool = false
    var codexQuota: CodexQuotaSnapshot = .idle
    var claudeQuota: ClaudeQuotaSnapshot = .idle
    var onCodexQuotaToggle: (() -> Void)? = nil
    var onCodexQuotaRefresh: (() -> Void)? = nil

    /// 百分比 chip 的悬停态（驱动背景底色透明度）
    @State private var percentHovered = false
    @State private var quotaHovered = false
    @State private var modelDetectHovered = false
    @State private var cacheHovered = false
    @State private var textColorHovered = false
    @State private var historyHovered = false

    private var textColor: Color { dropdownTextColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { dropdownTextColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { dropdownTextColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    /// 过滤掉今日消耗为 0 的工具
    private var activeTools: [ToolUsage] {
        tools.filter { $0.todayTokens > 0 }
    }

    /// 「按模型」分组的视图数据（跨工具归并）
    private var modelGroups: [ModelGroup] {
        UsageAggregator.groupedByModel(tools, unknownLabel: L10n.shared.tr("detail.unknownModel"))
    }

    /// 百分比分母：所有工具当日 token 总和（随用量口径切换；未激活工具为 0，
    /// 与「仅活跃工具之和」「各模型分组之和」一致，两种分组模式共用）。
    private var grandTotal: Int {
        tools.reduce(0) {
            $0 + $1.todayTokens + (usageIncludesCache ? $1.todayCacheReadTokens : 0)
        }
    }

    /// 全部工具今日估算费用（费用模式下的表头汇总行暂未使用，保留聚合口径）
    private var totalCost: CostEstimate {
        var result = CostEstimate.zero
        for tool in tools { result.merge(tool.todayCost) }
        return result
    }

    /// 数值列表头（主列：用量↔费用；次列：消息数↔占比）
    private var primaryHeaderKey: String { valueMode == .tokens ? "detail.todayUsage" : "detail.cost" }
    private var secondaryHeaderKey: String { valueMode == .tokens ? "detail.messages" : "detail.share" }

    var body: some View {
        VStack(spacing: 0) {
            // 天气趋势条（只要有城市名就显示，forecast 为空时只显示当前天气）
            if !weather.cityName.isEmpty {
                forecastBar()
                Divider()
                    .background(theme.dropdownDividerColor)
                    .padding(.horizontal, 8)
            }

            if isLoading {
                // 首次数据读取中：显示加载提示（不展示 mock 占位工具，避免误导）
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.shared.tr("detail.loading"))
                        .font(.system(size: 11))
                        .foregroundColor(subtextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 第一行是会打开独立窗口的主入口，视觉上比下方 toggle 更有层次。
                HStack(spacing: 8) {
                    launcherCard(
                        icon: "waveform.path.ecg.rectangle",
                        titleLine1: L10n.shared.tr("detail.modelDetectLine1"),
                        titleLine2: L10n.shared.tr("detail.modelDetectLine2"),
                        hovered: modelDetectHovered,
                        enabled: false,
                        action: {}
                    )
                    .onHover { modelDetectHovered = $0 }

                    launcherCard(
                        icon: "gauge.with.dots.needle.50percent",
                        titleLine1: L10n.shared.tr("detail.subscriptionQuotaLine1"),
                        titleLine2: L10n.shared.tr("detail.subscriptionQuotaLine2"),
                        hovered: quotaHovered,
                        enabled: true,
                        action: { onSubscriptionQuota?() }
                    )
                    .onHover { quotaHovered = $0 }
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 4)

                // 第二行：按会话 / 按模型。
                HStack(spacing: 2) {
                    ForEach([GroupingMode.session, GroupingMode.model], id: \.self) { mode in
                        let selected = (groupingMode == mode)
                        Button { onGroupingChange?(mode) } label: {
                            Text(L10n.shared.tr(mode == .session ? "detail.groupBySession" : "detail.groupByModel"))
                                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? textColor : subtextColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(textColor.opacity(selected ? 0.12 : 0))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    Capsule(style: .continuous)
                        .fill(textColor.opacity(0.07))
                )
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 3)

                // 第三行均为紧凑 toggle/快捷操作。
                HStack(spacing: 4) {
                    compactAction(
                        icon: usageIncludesCache ? "externaldrive.fill.badge.checkmark" : "externaldrive",
                        title: "\(L10n.shared.tr("detail.cacheDataLine1"))\n\(L10n.shared.tr("detail.cacheDataLine2"))",
                        subtitle: "",
                        selected: usageIncludesCache,
                        hovered: cacheHovered,
                        action: { onUsageIncludesCacheToggle?() }
                    )
                    .frame(width: 64)
                    .onHover { cacheHovered = $0 }

                    compactAction(
                        icon: "circle.fill",
                        iconColor: textColor,
                        title: "\(L10n.shared.tr("detail.textColorLine1"))\n\(L10n.shared.tr("detail.textColorLine2"))",
                        subtitle: "",
                        selected: quickContrastPreset != nil,
                        hovered: textColorHovered,
                        action: { onQuickContrast?() }
                    )
                    .frame(width: 58)
                    .onHover { textColorHovered = $0 }

                    compactAction(
                        icon: "clock.arrow.circlepath",
                        title: "\(L10n.shared.tr("detail.historyUsageLine1"))\n\(L10n.shared.tr("detail.historyUsageLine2"))",
                        subtitle: "",
                        selected: false,
                        hovered: historyHovered,
                        action: { onHistoryUsage?() }
                    )
                    .frame(width: 80)
                    .onHover { historyHovered = $0 }

                    compactAction(
                        icon: "dollarsign.circle",
                        title: valueMode == .tokens ? L10n.shared.tr("detail.byCost") : L10n.shared.tr("detail.byPercent"),
                        subtitle: valueMode == .tokens ? L10n.shared.tr("detail.byPercent") : L10n.shared.tr("detail.todayUsage"),
                        selected: valueMode == .costPercent,
                        hovered: percentHovered,
                        action: { onValueModeChange?(valueMode.next) }
                    )
                    .frame(width: 82)
                    .help(L10n.shared.tr("detail.valueModeHelp"))
                    .onHover { percentHovered = $0 }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 3)

                // 表头：名称 + 主列（用量↔费用）+ 次列（消息数↔占比）+ 缓存率（仅会话模式）
                HStack(spacing: 0) {
                    Text(L10n.shared.tr(groupingMode == .model ? "detail.model" : "detail.instance"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.shared.tr(primaryHeaderKey))
                        .frame(width: 62, alignment: .trailing)
                    Text(L10n.shared.tr(secondaryHeaderKey))
                        .frame(width: 36, alignment: .trailing)
                    if groupingMode == .session {
                        Text(L10n.shared.tr("detail.cacheRate"))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(headerColor)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)

                // 列表（按模式切换）
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        if groupingMode == .session {
                            ForEach(Array(activeTools.enumerated()), id: \.element.id) { index, tool in
                                if index > 0 {
                                    Divider()
                                        .background(theme.dropdownDividerColor)
                                }
                                ToolExpandableRow(tool: tool, theme: theme, textColorOverride: dropdownTextColorOverride, valueMode: valueMode, grandTotal: grandTotal, usageIncludesCache: usageIncludesCache)
                            }
                        } else {
                            ForEach(Array(modelGroups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 {
                                    Divider()
                                        .background(theme.dropdownDividerColor)
                                }
                                ModelExpandableRow(group: group, theme: theme, textColorOverride: dropdownTextColorOverride, valueMode: valueMode, grandTotal: grandTotal, usageIncludesCache: usageIncludesCache)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(
            .regular.tint(theme.glassTint),
            in: .rect(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private func launcherCard(
        icon: String,
        titleLine1: String,
        titleLine2: String,
        subtitle: String? = nil,
        hovered: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine1)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(titleLine2)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 8.5, weight: .medium))
                            .opacity(0.68)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: enabled ? "arrow.up.right" : "lock.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundColor(enabled ? textColor : subtextColor)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 49)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(textColor.opacity(hovered && enabled ? 0.14 : 0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(textColor.opacity(enabled ? 0.18 : 0.09), lineWidth: 0.6)
            )
        }
        .buttonStyle(ChipPressStyle())
        .disabled(!enabled)
        .accessibilityLabel("\(titleLine1) \(titleLine2)")
    }

    private func compactAction(
        icon: String,
        iconColor: Color? = nil,
        title: String,
        subtitle: String,
        trailingIcon: String? = nil,
        selected: Bool,
        hovered: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(iconColor)
                    .overlay {
                        if iconColor != nil {
                            Circle()
                                .strokeBorder(subtextColor.opacity(0.55), lineWidth: 0.6)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).lineLimit(2).multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 7.5, weight: .medium)).opacity(0.65).lineLimit(1)
                    }
                }
                if let trailingIcon {
                    Spacer(minLength: 0)
                    Image(systemName: trailingIcon)
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.68)
                }
            }
            .font(.system(size: 9, weight: selected ? .semibold : .medium))
            .foregroundColor(selected ? textColor : subtextColor)
            .frame(maxWidth: .infinity, minHeight: 35)
            .padding(.horizontal, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(textColor.opacity(selected ? 0.17 : (hovered ? 0.11 : 0.065)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(textColor.opacity(selected ? 0.29 : 0.13), lineWidth: 0.5)
            )
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }

    // MARK: - Codex quota

    @ViewBuilder
    private func codexQuotaPanel() -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(L10n.shared.tr("quota.subscriptions"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(0.2)
                        .foregroundColor(textColor)
                    Spacer()
                    Button { onCodexQuotaRefresh?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(subtextColor)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(textColor.opacity(0.09)))
                    }
                    .buttonStyle(ChipPressStyle())
                    .disabled(codexQuota.status == .loading || claudeQuota.status == .loading)
                    .accessibilityLabel(L10n.shared.tr("quota.retry"))
                }

                quotaProviderHeader("🤖 Codex", plan: codexQuota.planType, loading: codexQuota.status == .loading)
                if codexQuota.buckets.isEmpty {
                    quotaUnavailableRow(L10n.shared.tr(
                        codexQuota.status == .loading ? "quota.loadingCodex" : "quota.codexUnavailable"
                    ))
                } else {
                    ForEach(codexQuota.buckets) { bucket in codexQuotaCard(bucket) }
                    HStack(spacing: 5) {
                        if codexQuota.hasUnlimitedCredits {
                            quotaMetaChip(L10n.shared.tr("quota.unlimited"))
                        } else if let balance = codexQuota.creditBalance, balance != "0" {
                            quotaMetaChip(L10n.shared.tr("quota.creditBalance", balance))
                        }
                        if codexQuota.resetCreditCount > 0 {
                            quotaMetaChip(L10n.shared.tr("quota.resetCredits", codexQuota.resetCreditCount))
                        }
                        Spacer(minLength: 0)
                    }
                    quotaSourceRow(
                        codexQuota.source == .appServer ? "quota.liveSource" : "quota.logSource",
                        refreshedAt: codexQuota.refreshedAt,
                        live: codexQuota.source == .appServer
                    )
                }

                Divider().background(textColor.opacity(0.16)).padding(.vertical, 2)

                quotaProviderHeader("✳️ Claude Code", plan: claudeQuota.planType, loading: claudeQuota.status == .loading)
                if claudeQuota.buckets.isEmpty {
                    quotaUnavailableRow(L10n.shared.tr(
                        claudeQuota.status == .loading ? "quota.loadingClaude" : "quota.claudeUnavailable"
                    ))
                } else {
                    ForEach(claudeQuota.buckets) { bucket in codexQuotaCard(bucket) }
                    quotaSourceRow("quota.claudeSource", refreshedAt: claudeQuota.refreshedAt, live: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 8)
        }
    }

    private func quotaProviderHeader(_ title: String, plan: String?, loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.mini) }
            Text(title)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundColor(textColor)
            Spacer()
            if let plan, !plan.isEmpty {
                quotaMetaChip(L10n.shared.tr("quota.plan", displayPlan(plan)))
            }
        }
        .padding(.horizontal, 1)
    }

    private func quotaSourceRow(_ key: String, refreshedAt: Date?, live: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(live ? Color.green : Color.orange).frame(width: 5, height: 5)
            Text(L10n.shared.tr(key))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(subtextColor)
            Spacer()
            if let refreshedAt {
                Text(L10n.shared.tr("quota.updated", quotaUpdatedLabel(refreshedAt)))
                    .font(.system(size: 9.5))
                    .foregroundColor(subtextColor)
            }
        }
        .padding(.horizontal, 2)
    }

    private func quotaUnavailableRow(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle").foregroundColor(subtextColor)
            Text(text).font(.system(size: 10)).foregroundColor(subtextColor)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(textColor.opacity(0.045)))
    }

    private func codexQuotaCard(_ bucket: CodexQuotaBucket) -> some View {
        let accent = quotaAccent(for: bucket.remainingPercent)
        let reset = bucket.resetsAt.map(quotaResetLabels)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Text(quotaWindowLabel(minutes: bucket.windowMinutes))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(textColor)
                Spacer()
                VStack(alignment: .trailing, spacing: -1) {
                    Text(String(format: "%.0f%%", bucket.remainingPercent))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(L10n.shared.tr("quota.remainingLabel"))
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundColor(subtextColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(textColor.opacity(0.09))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(
                            bucket.remainingPercent > 0 ? 3 : 0,
                            geometry.size.width * bucket.remainingPercent / 100
                        ))
                }
            }
            .frame(height: 8)

            if let reset {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 9, weight: .semibold))
                    Text(reset.relative)
                        .font(.system(size: 9.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(reset.absolute)
                        .font(.system(size: 8.5))
                        .lineLimit(1)
                }
                .foregroundColor(subtextColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(textColor.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(textColor.opacity(0.14), lineWidth: 0.6)
        )
    }

    private func quotaMetaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(subtextColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(textColor.opacity(0.1)))
    }

    private func quotaAccent(for remaining: Double) -> Color {
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
    }

    private func quotaWindowLabel(minutes: Int) -> String {
        if minutes == 10_080 { return L10n.shared.tr("quota.weekly") }
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) {
            return L10n.shared.tr("quota.days", minutes / 1_440)
        }
        if minutes >= 60, minutes.isMultiple(of: 60) {
            return L10n.shared.tr("quota.hours", minutes / 60)
        }
        return L10n.shared.tr("quota.minutes", minutes)
    }

    private func quotaResetLabels(_ date: Date) -> (relative: String, absolute: String) {
        let absolute = DateFormatter()
        absolute.locale = Locale(identifier: L10n.shared.language.rawValue)
        absolute.dateFormat = L10n.shared.language == .en ? "MMM d · h:mm a" : "M月d日 · HH:mm"
        let relative = RelativeDateTimeFormatter()
        relative.locale = absolute.locale
        relative.unitsStyle = .short
        return (
            L10n.shared.tr(
                "quota.resetsRelative",
                relative.localizedString(for: date, relativeTo: Date())
            ),
            absolute.string(from: date)
        )
    }

    private func displayPlan(_ raw: String) -> String {
        if raw.lowercased() == "prolite" { return "Pro" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func quotaUpdatedLabel(_ date: Date) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: L10n.shared.language.rawValue)
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - 天气趋势条

    private func forecastBar() -> some View {
        let now = Calendar.current.component(.hour, from: Date())
        let slots = selectForecastSlots(currentHour: now)
        let hasForecast = !slots.isEmpty

        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("\(weather.emoji) \(localizedCityName.isEmpty ? weather.cityName : localizedCityName) \(weather.temperature)°C")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if hasForecast {
                    Text(L10n.shared.tr("detail.forecast"))
                        .font(.system(size: 11))
                        .foregroundColor(subtextColor)
                }
            }
            .padding(.horizontal, 12)

            if hasForecast {
                HStack(spacing: 8) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                        VStack(spacing: 2) {
                            Text(formatForecastTime(slot.time))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(subtextColor)
                            Text(slot.emoji)
                                .font(.system(size: 16))
                            Text("\(slot.tempC)°")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(textColor)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 8)
    }

    /// 选取当前 3 小时槽 + 接下来 3 个槽（共 4 个，覆盖 12 小时）
    private func selectForecastSlots(currentHour: Int) -> [HourlyForecast] {
        guard !weather.forecast.isEmpty else { return [] }

        // 计算每个槽对应的小时数
        func slotHour(_ time: String) -> Int {
            if time.count <= 2 { return Int(time) ?? 0 }
            if time.count == 3 { return Int(time.prefix(1)) ?? 0 }
            return Int(time.prefix(2)) ?? 0
        }

        // 找当前小时所在的槽。forecast 已按 API 顺序合并多天，跨日后小时会回到 0，
        // 因此遇到次日时间回卷时停止比较，避免深夜误选到次日末尾。
        var currentIndex = 0
        var previousHour = -1
        for (i, slot) in weather.forecast.enumerated() {
            let h = slotHour(slot.time)
            if previousHour > h { break }
            if h <= currentHour {
                currentIndex = i
            } else {
                break
            }
            previousHour = h
        }

        // 取当前槽 + 接下来 3 个槽
        var result: [HourlyForecast] = []
        for i in 0..<4 {
            let idx = currentIndex + i
            if idx < weather.forecast.count {
                result.append(weather.forecast[idx])
            }
        }
        return result
    }

    /// 将 wttr.in 时间字符串格式化为 "HH:00"
    private func formatForecastTime(_ time: String) -> String {
        let h: Int
        if time.count <= 2 {
            h = Int(time) ?? 0
        } else if time.count == 3 {
            h = Int(time.prefix(1)) ?? 0
        } else {
            h = Int(time.prefix(2)) ?? 0
        }
        return String(format: "%02d:00", h)
    }
}

// MARK: - 可展开的工具行

private struct ToolExpandableRow: View {
    let tool: ToolUsage
    let theme: ClockFaceTheme
    var textColorOverride: Color? = nil
    /// 数值显示模式
    var valueMode: DetailValueMode = .tokens
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    /// 用量口径：true=token 展示包含缓存读
    var usageIncludesCache: Bool = false
    @State private var isExpanded = false

    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        VStack(spacing: 0) {
            // 主行（点击展开/收起）
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 0) {
                    // 展开指示器
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(subtextColor)
                        .frame(width: 14)

                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(primaryValueText(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, cost: tool.todayCost, mode: valueMode, includeCacheRead: usageIncludesCache))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 62, alignment: .trailing)

                    Text(secondaryValueText(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, messages: tool.todayMessages, mode: valueMode, grandTotal: grandTotal, includeCacheRead: usageIncludesCache))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(subtextColor)
                        .frame(width: 36, alignment: .trailing)

                    Text(formatCacheRate(tool.cacheRate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(subtextColor)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 展开的子列表
            if isExpanded && !tool.sessions.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                        .background(theme.dropdownDividerColor.opacity(0.5))
                        .padding(.horizontal, 12)

                    ForEach(tool.sessions) { session in
                        SessionRow(
                            session: session,
                            isOpenClaw: tool.name == "OpenClaw",
                            theme: theme,
                            valueMode: valueMode,
                            grandTotal: grandTotal,
                            usageIncludesCache: usageIncludesCache
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func formatCacheRate(_ rate: Double) -> String {
        if rate <= 0 { return "-" }
        return String(format: "%.0f%%", rate * 100)
    }
}

// MARK: - Session / Agent 子行

private struct SessionRow: View {
    let session: SessionInfo
    let isOpenClaw: Bool
    let theme: ClockFaceTheme
    var textColorOverride: Color? = nil
    /// 数值显示模式
    var valueMode: DetailValueMode = .tokens
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    /// 用量口径：true=token 展示包含缓存读
    var usageIncludesCache: Bool = false

    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        HStack(spacing: 0) {
            // 子行缩进：先留出与主行 chevron 等宽的对齐空间（14），再额外右移，
            // 让 session 子行明显内缩于「工具名」主条目，避免两者在同一垂直线上造成视觉混淆。
            Rectangle()
                .fill(Color.clear)
                .frame(width: 26)

            // 名称区域
            VStack(alignment: .leading, spacing: 1) {
                if isOpenClaw {
                    // OpenClaw：直接显示 agent 名
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // 其他工具：session 标签（+ 来源，仅 Antigravity）+ ID
                    HStack(spacing: 3) {
                        Text("session")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(subtextColor)
                        if let source = session.source, !source.isEmpty {
                            Text("·")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(subtextColor.opacity(0.55))
                            Text(source)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(subtextColor)
                        }
                    }
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                }

                if let detail = session.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundColor(subtextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(primaryValueText(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, cost: session.todayCost, mode: valueMode, includeCacheRead: usageIncludesCache))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 62, alignment: .trailing)

            Text(secondaryValueText(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, messages: session.todayMessages, mode: valueMode, grandTotal: grandTotal, includeCacheRead: usageIncludesCache))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 36, alignment: .trailing)

            // 子行无缓存率列，占位保持对齐
            Rectangle()
                .fill(Color.clear)
                .frame(width: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            session.isActive
                ? textColor.opacity(0.04)
                : Color.clear
        )
    }
}

// MARK: - 按模型分组的可展开行

private struct ModelExpandableRow: View {
    let group: ModelGroup
    let theme: ClockFaceTheme
    var textColorOverride: Color? = nil
    /// 数值显示模式
    var valueMode: DetailValueMode = .tokens
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    /// 用量口径：true=token 展示包含缓存读
    var usageIncludesCache: Bool = false
    @State private var isExpanded = false

    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 0) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(subtextColor)
                        .frame(width: 14)

                    Text("\(group.emoji) \(group.name)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(primaryValueText(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, cost: group.totalCost, mode: valueMode, includeCacheRead: usageIncludesCache))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 62, alignment: .trailing)

                    Text(secondaryValueText(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, messages: group.totalMessages, mode: valueMode, grandTotal: grandTotal, includeCacheRead: usageIncludesCache))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(subtextColor)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && !group.contributions.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                        .background(theme.dropdownDividerColor.opacity(0.5))
                        .padding(.horizontal, 12)

                    ForEach(group.contributions) { c in
                        ModelContributionRow(contribution: c, theme: theme, textColorOverride: textColorOverride, valueMode: valueMode, grandTotal: grandTotal, usageIncludesCache: usageIncludesCache)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - 模型分组下的工具贡献子行

private struct ModelContributionRow: View {
    let contribution: ToolContribution
    let theme: ClockFaceTheme
    var textColorOverride: Color? = nil
    /// 数值显示模式
    var valueMode: DetailValueMode = .tokens
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    /// 用量口径：true=token 展示包含缓存读
    var usageIncludesCache: Bool = false

    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        HStack(spacing: 0) {
            // 子行缩进：对齐 chevron 后额外右移，与 session 子行保持一致
            Rectangle()
                .fill(Color.clear)
                .frame(width: 26)

            Text("\(contribution.emoji) \(contribution.tool)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(primaryValueText(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, cost: contribution.cost, mode: valueMode, includeCacheRead: usageIncludesCache))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 62, alignment: .trailing)

            Text(secondaryValueText(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, messages: contribution.messages, mode: valueMode, grandTotal: grandTotal, includeCacheRead: usageIncludesCache))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
