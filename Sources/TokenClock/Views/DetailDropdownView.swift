import SwiftUI

/// 将 token 数格式化为「占总数百分比」字符串：0 → "-"，(0%,1%) → "<1%"，其余取整（与缓存率风格一致）。
private func formatPercent(_ tokens: Int, of total: Int) -> String {
    if tokens <= 0 || total <= 0 { return "-" }
    let pct = Double(tokens) / Double(total) * 100
    if pct < 1 { return "<1%" }
    return String(format: "%.0f%%", pct)
}

/// 展开态详情列表（主题感知，支持 session/agent 展开）
struct DetailDropdownView: View {
    let tools: [ToolUsage]
    var theme: ClockFaceTheme = .classic
    /// 下拉面板主文字色覆写（nil = 跟随主题）。来自右键「表盘外观 → 详情面板文字色」。
    var dropdownTextColorOverride: Color? = nil
    var weather: WeatherInfo = WeatherInfo()
    var localizedCityName: String = ""
    /// 首次数据读取中：为 true 时用加载提示取代（基于 mock 的）工具列表，避免误导
    var isLoading: Bool = false

    /// 当前分组模式（按会话 / 按模型）
    var groupingMode: GroupingMode = .session
    /// 分组模式切换回调
    var onGroupingChange: ((GroupingMode) -> Void)? = nil

    /// 用量列是否以「占总数百分比」显示（true=百分比，false=绝对 token）
    var showPercentage: Bool = false
    /// 百分比显示切换回调
    var onShowPercentageChange: ((Bool) -> Void)? = nil

    /// 实际面板主文字色：有覆写则用覆写，否则用主题色。
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

    /// 百分比分母：所有工具当日 token 总和。未激活工具 todayTokens 为 0，
    /// 故该值与「仅活跃工具之和」「各模型分组之和」三者一致，两种分组模式可共用。
    private var grandTotal: Int {
        tools.reduce(0) { $0 + $1.todayTokens }
    }

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
                // 分组切换胶囊 [按会话 | 按模型]
                // 自定义胶囊替代系统 segmented：字号更小、配色更克制，不抢占列表视觉焦点。
                // 外层胶囊用 dropdownTextColor 低透明叠层（与面板底色略微区分），选中段加一层略浓的圆角块。
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
                .padding(.top, 6)
                .padding(.bottom, 2)

                // 百分比显示开关：置于分组胶囊正下方，切换用量列在「绝对 token」与「占总数百分比」之间。
                // 复用胶囊同款圆角块高亮表示选中态，与上方分段视觉一致。
                HStack {
                    Spacer()
                    Button { onShowPercentageChange?(!showPercentage) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "percent")
                            Text(L10n.shared.tr("detail.percent"))
                        }
                        .font(.system(size: 9, weight: showPercentage ? .semibold : .regular))
                        .foregroundColor(showPercentage ? textColor : subtextColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(textColor.opacity(showPercentage ? 0.12 : 0))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.shared.tr("detail.percent"))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

                // 表头
                HStack(spacing: 0) {
                    Text(L10n.shared.tr(groupingMode == .model ? "detail.model" : "detail.instance"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.shared.tr(showPercentage ? "detail.share" : "detail.todayUsage"))
                        .frame(width: 62, alignment: .trailing)
                    Text(L10n.shared.tr("detail.messages"))
                        .frame(width: 36, alignment: .trailing)
                    if groupingMode == .session {
                        Text(L10n.shared.tr("detail.cacheRate"))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(headerColor)
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
                                ToolExpandableRow(tool: tool, theme: theme, textColorOverride: dropdownTextColorOverride, showPercentage: showPercentage, grandTotal: grandTotal)
                            }
                        } else {
                            ForEach(Array(modelGroups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 {
                                    Divider()
                                        .background(theme.dropdownDividerColor)
                                }
                                ModelExpandableRow(group: group, theme: theme, textColorOverride: dropdownTextColorOverride, showPercentage: showPercentage, grandTotal: grandTotal)
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
    /// 面板主文字色覆写（nil = 跟随主题）。
    var textColorOverride: Color? = nil
    /// 用量列是否显示百分比
    var showPercentage: Bool = false
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }
    @State private var isExpanded = false

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

                    Text(showPercentage ? formatPercent(tool.todayTokens, of: grandTotal) : tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 62, alignment: .trailing)

                    Text("\(tool.todayMessages)")
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
                            textColorOverride: textColorOverride,
                            showPercentage: showPercentage,
                            grandTotal: grandTotal
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
    /// 面板主文字色覆写（nil = 跟随主题）。
    var textColorOverride: Color? = nil
    /// 用量列是否显示百分比
    var showPercentage: Bool = false
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        HStack(spacing: 0) {
            // 缩进
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)

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

            Text(showPercentage ? formatPercent(session.todayTokens, of: grandTotal) : session.formattedTokens)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 62, alignment: .trailing)

            Text("\(session.todayMessages)")
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
    /// 面板主文字色覆写（nil = 跟随主题）。
    var textColorOverride: Color? = nil
    /// 用量列是否显示百分比
    var showPercentage: Bool = false
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }
    @State private var isExpanded = false

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

                    Text(showPercentage ? formatPercent(group.totalTokens, of: grandTotal) : group.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 62, alignment: .trailing)

                    Text("\(group.totalMessages)")
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
                        ModelContributionRow(contribution: c, theme: theme, textColorOverride: textColorOverride, showPercentage: showPercentage, grandTotal: grandTotal)
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
    /// 面板主文字色覆写（nil = 跟随主题）。
    var textColorOverride: Color? = nil
    /// 用量列是否显示百分比
    var showPercentage: Bool = false
    /// 百分比分母（所有工具当日 token 总和）
    var grandTotal: Int = 0
    private var textColor: Color { textColorOverride ?? theme.dropdownTextColor }
    private var subtextColor: Color { textColorOverride.map { $0.opacity(0.65) } ?? theme.dropdownSubtextColor }
    private var headerColor: Color { textColorOverride.map { $0.opacity(0.7) } ?? theme.dropdownHeaderColor }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)

            Text("\(contribution.emoji) \(contribution.tool)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(showPercentage ? formatPercent(contribution.tokens, of: grandTotal) : TokenFormat.compact(contribution.tokens))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 62, alignment: .trailing)

            Text("\(contribution.messages)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(subtextColor)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
