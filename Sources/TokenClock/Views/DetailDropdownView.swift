import SwiftUI

/// 展开态详情列表（主题感知，支持 session/agent 展开）
struct DetailDropdownView: View {
    let tools: [ToolUsage]
    var theme: ClockFaceTheme = .classic
    var weather: WeatherInfo = WeatherInfo()

    /// 过滤掉今日消耗为 0 的工具
    private var activeTools: [ToolUsage] {
        tools.filter { $0.todayTokens > 0 }
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

            // 表头
            HStack(spacing: 0) {
                Text(L10n.shared.tr("detail.instance"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.shared.tr("detail.todayUsage"))
                    .frame(width: 68, alignment: .trailing)
                Text(L10n.shared.tr("detail.messages"))
                    .frame(width: 40, alignment: .trailing)
                Text(L10n.shared.tr("detail.cacheRate"))
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(theme.dropdownHeaderColor)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 工具列表（过滤消耗为 0 的）
            ForEach(Array(activeTools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .background(theme.dropdownDividerColor)
                }

                ToolExpandableRow(tool: tool, theme: theme)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.dropdownBgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dropdownBorderColor, lineWidth: 1.5)
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
                Text("\(weather.emoji) \(weather.cityName) \(weather.temperature)°C")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.dropdownTextColor)
                Spacer()
                if hasForecast {
                    Text(L10n.shared.tr("detail.forecast"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.dropdownSubtextColor)
                }
            }
            .padding(.horizontal, 12)

            if hasForecast {
                HStack(spacing: 0) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                        if idx > 0 {
                            Spacer()
                        }
                        VStack(spacing: 2) {
                            Text(formatForecastTime(slot.time))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.dropdownSubtextColor)
                            Text(slot.emoji)
                                .font(.system(size: 16))
                            Text("\(slot.tempC)°")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.dropdownTextColor)
                        }
                        .frame(minWidth: 44)
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

        // 找当前小时所在的槽（最大的 <= currentHour 的槽）
        var currentIndex = 0
        for (i, slot) in weather.forecast.enumerated() {
            let h = slotHour(slot.time)
            if h <= currentHour {
                currentIndex = i
            } else {
                break
            }
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
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 主行（点击展开/收起）
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 0) {
                    // 展开指示器
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 14)

                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.dropdownTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.dropdownTextColor)
                        .frame(width: 68, alignment: .trailing)

                    Text("\(tool.todayMessages)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 40, alignment: .trailing)

                    Text(formatCacheRate(tool.cacheRate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 44, alignment: .trailing)
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
                            theme: theme
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
                        .foregroundColor(theme.dropdownTextColor)
                } else {
                    // 其他工具：session 标签 + ID
                    Text("session")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(theme.dropdownSubtextColor)
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.dropdownTextColor)
                }

                if let detail = session.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.formattedTokens)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.dropdownSubtextColor)
                .frame(width: 68, alignment: .trailing)

            Text("\(session.todayMessages)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.dropdownSubtextColor)
                .frame(width: 40, alignment: .trailing)

            // 子行无缓存率列，占位保持对齐
            Rectangle()
                .fill(Color.clear)
                .frame(width: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            session.isActive
                ? theme.dropdownTextColor.opacity(0.04)
                : Color.clear
        )
    }
}
