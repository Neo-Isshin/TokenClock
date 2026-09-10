import SwiftUI
import AppKit

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject private var clockTicker: ClockTicker
    @State private var hoveredQuotaLabel: String?
    let onNotificationClick: () -> Void
    let onClockDragStart: () -> Void

    init(
        viewModel: ViewModel,
        onNotificationClick: @escaping () -> Void = {},
        onClockDragStart: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onNotificationClick = onNotificationClick
        self.onClockDragStart = onClockDragStart
        self._clockTicker = ObservedObject(wrappedValue: viewModel.clockTicker)
        self._hoveredQuotaLabel = State(initialValue: nil)
    }

    var body: some View {
        // 表盘大小随用户设置缩放：d = 直径，s = 相对中档(240)的缩放比。
        let d = viewModel.clockSize.diameter
        let s = viewModel.clockSize.scale
        let quotaIndicators = viewModel.dialQuotaIndicators

        ZStack {
            // 表盘
            ClockFaceView(
                hours: viewModel.hours,
                minutes: viewModel.minutes,
                seconds: viewModel.seconds,
                theme: viewModel.selectedTheme,
                numberColorOverride: viewModel.effectiveDialNumberColor,
                scale: s
            )
            .frame(width: d, height: d)

            // 叠加信息：位于中心到边缘中点位置
            VStack(spacing: 0) {
                // 上方：日期 + 天气（中心到上部中点）
                VStack(spacing: 3) {
                    Text(viewModel.dateString)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundColor(viewModel.effectiveDialSecondary)
                    Color.clear.frame(height: 16 * s)
                }
                .padding(.top, 55 * s)

                Spacer()

                // 下方：tokens + 消息数（中心到下部中点）
                VStack(spacing: 2) {
                    HStack(spacing: 3 * s) {
                        Text(L10n.shared.tr("clock.todayTokens"))
                        Text(viewModel.rateEmoji)
                            .font(.system(size: 10 * s))
                            .baselineOffset(0.5 * s)
                            .scaleEffect(1.5)
                    }
                    .font(.system(size: 9 * s))
                    .foregroundColor(viewModel.effectiveDialSecondary)
                    Text(viewModel.totalTokensFormatted)
                        .font(.system(size: 20 * s, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.effectiveDialPrimary)
                    Text(viewModel.totalMessagesFormatted)
                        .font(.system(size: 10 * s))
                        .foregroundColor(viewModel.effectiveDialSecondary)
                }
                .padding(.bottom, 48 * s)
            }

            // 左侧：活跃工具标签
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.activeToolsList) { tool in
                        HStack(alignment: .firstTextBaseline, spacing: 0.5 * s) {
                            Text(tool.emoji)
                                .font(.system(size: 13 * s))
                                .baselineOffset(0.5 * s)
                                .frame(width: 16 * s, alignment: .trailing)
                            Text(tool.abbreviation)
                                .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 24 * s, alignment: .trailing)
                        }
                        .foregroundColor(viewModel.effectiveDialPrimary.opacity(0.75))
                    }
                }
                .padding(.leading, 32 * s)
                Spacer()
            }

            // 右侧：最多两个订阅工具额度环
            HStack {
                Spacer()
                if quotaIndicators.count == 1, let indicator = quotaIndicators.first {
                    quotaRing(indicator, size: 35 * s, lineWidth: 3 * s, fontSize: 8.5 * s)
                        .padding(.trailing, 36 * s)
                } else if quotaIndicators.count == 2 {
                    VStack(alignment: .trailing, spacing: 5 * s) {
                        ForEach(quotaIndicators) { indicator in
                            quotaRing(indicator, size: 29 * s, lineWidth: 2.5 * s, fontSize: 7.2 * s)
                        }
                    }
                    .padding(.trailing, 28 * s)
                }
            }

            // SwiftUI 的 tap 手势会吞掉「窗口背景拖拽」的鼠标序列（normal 版曾因此拖不动表盘）。
            // 点击/拖动改由 AppKit 层分发：>3pt 位移 = 拖动窗口，否则 = 点击展开详情。
            ClockInteractionLayer(
                tooltipRegions: quotaTooltipRegions(quotaIndicators, diameter: d, scale: s),
                onClick: { viewModel.isExpanded.toggle() },
                onDragStart: {
                    viewModel.isExpanded = false
                    onClockDragStart()
                },
                onTooltipHover: { hoveredQuotaLabel = $0 }
            )
            .frame(width: d, height: d)
            .accessibilityHidden(true)

            if let hoveredQuotaLabel, !quotaIndicators.isEmpty {
                Text(hoveredQuotaLabel)
                    .font(.system(size: 8.5 * s, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1 * s)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 6 * s)
                    .padding(.vertical, 3 * s)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5 * s)
                    }
                    .shadow(color: Color.black.opacity(0.16), radius: 2 * s, y: 1 * s)
                    .position(quotaTooltipPosition(
                        label: hoveredQuotaLabel,
                        indicators: quotaIndicators,
                        diameter: d,
                        scale: s
                    ))
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                HStack(spacing: 4 * s) {
                    Text(viewModel.weatherString)
                        .font(.system(size: 13 * s))
                        .foregroundColor(viewModel.effectiveDialPrimary)
                        .allowsHitTesting(false)
                    if viewModel.unreadNotificationCount > 0 {
                        notificationButton(scale: s)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 70 * s)
                Spacer()
            }
        }
        .frame(width: d, height: d)
        // 无障碍：表盘是纯视觉（指针/emoji/格式化数字），VoiceOver 读不出含义。
        // 收拢成单一元素，朗读「时间 + 今日用量」摘要；保留按钮特性（点按展开）。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(L10n.shared.tr("a11y.clockHint")))
        .accessibilityAddTraits(.isButton)
    }

    private func quotaRing(
        _ indicator: DialQuotaIndicator,
        size: CGFloat,
        lineWidth: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        let outer = min(100, max(0, indicator.outerRemainingPercent))
        let inner = indicator.innerRemainingPercent.map { min(100, max(0, $0)) }
        let scale = size / 30
        let innerInset = 5.25 * scale
        let innerLineWidth = 1.7 * scale
        let accent = viewModel.selectedTheme.dialQuotaColor(
            for: indicator.provider,
            contrastColor: viewModel.effectiveDialPrimary
        )
        return ZStack {
            Circle()
                .fill(quotaRingSurfaceColor)
                .shadow(color: Color.black.opacity(0.14), radius: 1.6 * scale, y: 0.8 * scale)
            Circle()
                .strokeBorder(viewModel.effectiveDialSecondary.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: outer / 100)
                .stroke(
                    accent.opacity(0.82),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
            if let inner {
                Circle()
                    .inset(by: innerInset)
                    .stroke(viewModel.effectiveDialSecondary.opacity(0.10), lineWidth: innerLineWidth)
                Circle()
                    .inset(by: innerInset)
                    .trim(from: 0, to: inner / 100)
                    .stroke(
                        accent.opacity(0.52),
                        style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            HStack(spacing: 0) {
                Text(String(format: "%.0f", outer))
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                Text("%")
                    .font(.system(size: fontSize, weight: .regular, design: .rounded))
            }
            .foregroundColor(quotaPercentColor(outer))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(width: size, height: size)
    }

    private var quotaRingSurfaceColor: Color {
        switch viewModel.selectedTheme {
        case .glass: return Color.black.opacity(0.20)
        case .midnight, .luxe: return Color.black.opacity(0.12)
        case .sky: return Color.white.opacity(0.16)
        case .custom: return viewModel.effectiveDialPrimary.opacity(0.035)
        default: return Color.white.opacity(0.32)
        }
    }

    private func quotaPercentColor(_ remaining: Double) -> Color {
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return viewModel.effectiveDialPrimary
    }

    private func quotaTooltipRegions(
        _ indicators: [DialQuotaIndicator],
        diameter: CGFloat,
        scale s: CGFloat
    ) -> [ClockTooltipRegion] {
        guard indicators.count == 1 || indicators.count == 2 else { return [] }
        let ringSize = (indicators.count == 1 ? 35 : 29) * s
        let trailing = (indicators.count == 1 ? 36 : 28) * s
        let spacing = 5 * s
        let totalHeight = ringSize * CGFloat(indicators.count)
            + spacing * CGFloat(max(0, indicators.count - 1))
        let top = (diameter - totalHeight) / 2
        let x = diameter - trailing - ringSize
        return indicators.enumerated().map { index, indicator in
            let swiftUITop = top + CGFloat(index) * (ringSize + spacing)
            let appKitY = diameter - swiftUITop - ringSize
            return ClockTooltipRegion(
                rect: NSRect(x: x, y: appKitY, width: ringSize, height: ringSize)
                    .insetBy(dx: -3 * s, dy: -3 * s),
                text: quotaTooltipText(for: indicator)
            )
        }
    }

    private func quotaTooltipText(for indicator: DialQuotaIndicator) -> String {
        var lines = ["\(indicator.provider.emoji) \(indicator.provider.displayName)"]
        for detail in indicator.details {
            lines.append(
                "\(L10n.shared.tr(detail.labelKey)) \(String(format: "%.0f%%", detail.remainingPercent))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func quotaTooltipPosition(
        label: String,
        indicators: [DialQuotaIndicator],
        diameter: CGFloat,
        scale s: CGFloat
    ) -> CGPoint {
        let count = indicators.count
        let ringSize = (count == 1 ? 35 : 29) * s
        let trailing = (count == 1 ? 36 : 28) * s
        let spacing = 5 * s
        let totalHeight = ringSize * CGFloat(count) + spacing * CGFloat(max(0, count - 1))
        let top = (diameter - totalHeight) / 2
        guard let index = indicators.firstIndex(where: { quotaTooltipText(for: $0) == label }) else {
            return CGPoint(x: diameter / 2, y: diameter / 2)
        }
        let centerY = top + CGFloat(index) * (ringSize + spacing) + ringSize / 2
        let ringLeft = diameter - trailing - ringSize
        return CGPoint(x: max(43 * s, ringLeft - 47 * s), y: centerY)
    }

    /// VoiceOver 朗读摘要：时间 + 今日 token + 消息数（已随语言本地化）。
    private var accessibilitySummary: String {
        let time = String(format: "%d:%02d", viewModel.hours, viewModel.minutes)
        let summary = L10n.shared.tr("a11y.clockSummary",
                                     viewModel.dateString,
                                     time,
                                     viewModel.totalTokensFormatted,
                                     viewModel.totalMessagesFormatted)
        let quotas = viewModel.dialQuotaIndicators.map {
            L10n.shared.tr(
                "quota.dialAccessibility",
                $0.provider.displayName,
                Int($0.outerRemainingPercent.rounded())
            )
        }
        guard !quotas.isEmpty else { return summary }
        return summary + ", " + quotas.joined(separator: ", ")
    }

    @ViewBuilder
    private func notificationButton(scale s: CGFloat) -> some View {
        Button(action: onNotificationClick) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: viewModel.unreadNotificationCount > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 14 * s, weight: .semibold))
                    .foregroundColor(viewModel.effectiveDialPrimary.opacity(
                        viewModel.unreadNotificationCount > 0 ? 0.95 : 0.62
                    ))
                    .frame(width: 20 * s, height: 20 * s)
                    .contentShape(Circle())

                if viewModel.unreadNotificationCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6 * s, height: 6 * s)
                        .overlay(Circle().stroke(viewModel.selectedTheme.dialColor, lineWidth: 1 * s))
                        .offset(x: -2 * s, y: 2 * s)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L10n.shared.tr("notification.open"))
        .accessibilityLabel(Text(L10n.shared.tr("notification.open")))
    }
}

extension SubscriptionProvider {
    var defaultDialQuotaColor: Color {
        switch self {
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .claude: return Color(red: 0.85, green: 0.40, blue: 0.28)
        case .antigravity: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .cursor: return Color(red: 0.10, green: 0.62, blue: 0.92)
        case .grokBot: return Color(red: 0.39, green: 0.40, blue: 0.95)
        case .zhipu: return .black
        }
    }
}

extension ClockFaceTheme {
    func dialQuotaColor(for provider: SubscriptionProvider, contrastColor: Color) -> Color {
        switch self {
        case .classic, .glacier, .gufeng, .railgun:
            return provider.defaultDialQuotaColor
        case .glass, .midnight, .luxe, .sky, .custom:
            return contrastColor
        }
    }
}
