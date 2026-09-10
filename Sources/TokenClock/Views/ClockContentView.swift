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

        // 外层：流动柔光在底，圆形玻璃盘体在上。
        // `.clear` 玻璃会透出 / 折射底层柔光，呈现晶莹剔透 + 微微流动的质感，
        // 不依赖桌面壁纸是否有内容。
        ZStack {
            GlassAurora(theme: viewModel.selectedTheme,
                        size: d,
                        enhanced: viewModel.selectedTheme == .glacier)
                .frame(width: d, height: d)

            ZStack {
                // 表盘
                ClockFaceView(
                    hours: viewModel.hours,
                    minutes: viewModel.minutes,
                    seconds: viewModel.seconds,
                    theme: viewModel.selectedTheme,
                    role: .face,
                    scale: s,
                    numberColorOverride: viewModel.effectiveDialNumberColor
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
                                .scaleEffect(1.5)
                                .baselineOffset(0.5 * s)
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
                            .foregroundColor(viewModel.effectiveDialPrimary)
                        }
                    }
                    .padding(.leading, 28 * s)
                    Spacer()
                }

                // 右侧：所选订阅工具的剩余额度
                HStack {
                    Spacer()
                    if quotaIndicators.count == 1, let indicator = quotaIndicators.first {
                        quotaRing(
                            provider: indicator.provider,
                            outerRemaining: indicator.outerRemainingPercent,
                            innerRemaining: indicator.innerRemainingPercent,
                            size: 35 * s,
                            lineWidth: 3 * s,
                            fontSize: 8.5 * s
                        )
                            .padding(.trailing, 36 * s)
                    } else if quotaIndicators.count == 2 {
                        VStack(alignment: .trailing, spacing: 5 * s) {
                            ForEach(quotaIndicators) { indicator in
                                quotaRing(
                                    provider: indicator.provider,
                                    outerRemaining: indicator.outerRemainingPercent,
                                    innerRemaining: indicator.innerRemainingPercent,
                                    size: 29 * s,
                                    lineWidth: 2.5 * s,
                                    fontSize: 7.2 * s
                                )
                            }
                        }
                        .padding(.trailing, 28 * s)
                    }
                }

                // 指针置于文字之上：单独一层只渲染指针 + 中心点
                ClockFaceView(
                    hours: viewModel.hours,
                    minutes: viewModel.minutes,
                    seconds: viewModel.seconds,
                    theme: viewModel.selectedTheme,
                    role: .hands,
                    scale: s
                )
                .frame(width: d, height: d)
            }
            .frame(width: d, height: d)
            // glacier 主题：跳过 .glassEffect（.clear/.regular 都有 backdrop blur，
            // glacier 想要"完全无磨砂"必须走纯色背景 + 圆形裁剪 + 依赖 GlassAurora 流动光）。
            // 其他主题用 .glassEffect(.regular.tint(...))：macOS 27 Beta 上 .clear 会把 tint
            // 渲染成近不透明实心色（bug），.regular 在 26/27 都正常（与下拉面板一致）。
            .modifier(DialGlassModifier(
                theme: viewModel.selectedTheme,
                diameter: d,
                glassVariant: viewModel.glassMaterialVariant,
                glassTintHex: viewModel.glassTintHex,
                glassEnabled: viewModel.glassRefractionEnabled,
                glassBackingAlpha: viewModel.glassBackingAlpha
            ))

            // SwiftUI's tap recognizer consumes the window-drag mouse sequence on recent
            // runtimes. Keep the glass visuals intact and route click/drag through AppKit.
            ClockInteractionLayer(
                tooltipRegions: quotaTooltipRegions(
                    quotaIndicators,
                    diameter: d,
                    scale: s
                ),
                onClick: {
                    viewModel.isExpanded.toggle()
                },
                onDragStart: {
                    viewModel.isExpanded = false
                    onClockDragStart()
                },
                onTooltipHover: { label in
                    hoveredQuotaLabel = label
                }
            )
            .frame(width: d, height: d)
            .accessibilityHidden(true)

            if let hoveredQuotaLabel, !quotaIndicators.isEmpty {
                Text(hoveredQuotaLabel)
                    .font(.system(size: 8.5 * s, weight: .semibold, design: .rounded))
                    .foregroundColor(viewModel.effectiveDialPrimary)
                    .padding(.horizontal, 6 * s)
                    .padding(.vertical, 3 * s)
                    .background(
                        Capsule()
                            .fill(viewModel.selectedTheme.dialColor.opacity(0.88))
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(viewModel.effectiveDialPrimary.opacity(0.10), lineWidth: 0.5 * s)
                    }
                    .shadow(color: Color.black.opacity(0.13), radius: 2 * s, y: 1 * s)
                    .position(quotaTooltipPosition(
                        indicatorCount: quotaIndicators.count,
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
        provider: SubscriptionProvider,
        outerRemaining: Double,
        innerRemaining: Double?,
        size: CGFloat,
        lineWidth: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        let outer = min(100, max(0, outerRemaining))
        let inner = innerRemaining.map { min(100, max(0, $0)) }
        let scale = size / 30
        let innerInset = 5.25 * scale
        let innerLineWidth = 1.7 * scale
        let accent = provider.dialQuotaColor
        let outerGradient = AngularGradient(
            colors: [accent.opacity(0.46), accent.opacity(0.76), accent.opacity(0.58)],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
        let innerGradient = AngularGradient(
            colors: [accent.opacity(0.28), accent.opacity(0.52), accent.opacity(0.36)],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.13),
                            viewModel.effectiveDialPrimary.opacity(0.025),
                            Color.black.opacity(0.045),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.24),
                                    viewModel.effectiveDialPrimary.opacity(0.07),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.65 * scale
                        )
                }
                .shadow(
                    color: Color.black.opacity(0.10),
                    radius: 2 * scale,
                    x: 0,
                    y: 1.1 * scale
                )
            Circle()
                .strokeBorder(viewModel.effectiveDialSecondary.opacity(0.11), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: outer / 100)
                .stroke(
                    outerGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .shadow(color: accent.opacity(0.16), radius: 1.3 * scale, y: 0.5 * scale)
            if let inner {
                Circle()
                    .inset(by: innerInset)
                    .stroke(viewModel.effectiveDialSecondary.opacity(0.08), lineWidth: innerLineWidth)
                Circle()
                    .inset(by: innerInset)
                    .trim(from: 0, to: inner / 100)
                    .stroke(
                        innerGradient,
                        style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: accent.opacity(0.10), radius: 0.8 * scale)
            }
            Text(String(format: "%.0f%%", outer))
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundColor(quotaPercentColor(outer))
                .minimumScaleFactor(0.75)
                .shadow(color: Color.white.opacity(0.15), radius: 0.45 * scale, y: -0.25 * scale)
        }
        .frame(width: size, height: size)
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
                text: "\(indicator.provider.emoji) \(indicator.provider.displayName)"
            )
        }
    }

    private func quotaTooltipPosition(
        indicatorCount: Int,
        diameter: CGFloat,
        scale s: CGFloat
    ) -> CGPoint {
        let ringSize = (indicatorCount == 1 ? 35 : 29) * s
        let spacing = 5 * s
        let totalHeight = ringSize * CGFloat(indicatorCount)
            + spacing * CGFloat(max(0, indicatorCount - 1))
        let clusterTop = (diameter - totalHeight) / 2
        return CGPoint(x: diameter - 62 * s, y: max(12 * s, clusterTop - 9 * s))
    }

    private func quotaPercentColor(_ remaining: Double) -> Color {
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return viewModel.effectiveDialSecondary
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
    var dialQuotaColor: Color {
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

/// 主盘玻璃修饰：glacier 主题走纯色背景（无 backdrop blur，零磨砂感），
/// 其他主题用 `.glassEffect(.regular.tint(_:).interactive())`（macOS 27 Beta 的 .clear 会渲染成实心）。
struct DialGlassModifier: ViewModifier {
    let theme: ClockFaceTheme
    let diameter: CGFloat
    /// 私有 NSGlassEffectView 材质配方（set_variant:）。改变时 .id 触发重建。
    let glassVariant: Int
    /// 私有玻璃底色 #RRGGBB（nil = 纯净玻璃）。
    let glassTintHex: String?
    /// 液态玻璃折射总开关（false = 回退公开 .clear 玻璃，无折射但稳定）。
    let glassEnabled: Bool
    /// 折射玻璃下层毛玻璃底板透明度 0…1（0=无底板）。公开 NSVisualEffectView.alphaValue。
    let glassBackingAlpha: Double

    func body(content: Content) -> some View {
        switch theme {
        case .glacier:
            // 完全跳过 .glassEffect。15% 透明度冰青给玻璃"色温"但不模糊，
            // 配合 GlassAurora 流动光层即可呈现"清澈透亮"质感。
            content
                .background(theme.glassTint?.opacity(0.15) ?? Color.clear, in: .circle)
                // 极细高亮 + 内阴影塑形：1px 白线描边 + 1.5px 内嵌白线形成"玻璃边缘"
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                }
                .overlay {
                    // 内阴影模拟：稍偏内的白线 + 模糊 → 给"压边"质感
                    Circle()
                        .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
                        .blur(radius: 1.2)
                        .padding(1.5)
                        .blendMode(.overlay)
                }
        default:
            if glassEnabled {
                // 私有 API 折射玻璃（NSGlassEffectView set_variant:/set_contentLensing:）。
                // 折射玻璃锁 variant 2（非 dock + max 折射会变形）；下层叠公开毛玻璃底板，调透明度。
                let tintNS = glassTintHex.flatMap { CodableColor(hex: $0) }?.nsColor
                content
                    .background(
                        LiquidGlassDial(diameter: diameter, variant: 2, tintColor: tintNS)
                            .id(glassVariant)
                    )
                    .background(
                        // 毛玻璃底板在折射玻璃下层；alpha 连续可调（updateNSView 原位改 alphaValue）。
                        VibrancyBacking(diameter: diameter, alpha: glassBackingAlpha)
                    )
            } else {
                // 回退：公开 .clear 玻璃（无折射但稳定；macOS 27 Beta 上 .clear 不带 tint 是清透的）。
                content
                    .glassEffect(.clear.interactive(), in: .circle)
            }
        }
    }
}

/// 玻璃背后的流动柔光：低饱和度、随主题着色、缓慢漂移。
/// 为 `.clear` 玻璃盘体提供可折射 / 透出的丰富内容，使时钟在任何壁纸上都呈晶莹质感。
struct GlassAurora: View {
    let theme: ClockFaceTheme
    var size: CGFloat = 240
    var animates: Bool = true
    /// glacier 主题开启：双层反向旋转 + 更强 sheen + radial glow，让"流动感"更明显。
    var enhanced: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// glacier 专属外圈径向 glow：玻璃盘外的柔光晕
    @ViewBuilder
    private var glowOverlay: some View {
        if enhanced {
            let accent = theme.glassTint ?? Color(red: 0.62, green: 0.72, blue: 0.88)
            RadialGradient(
                colors: [accent.opacity(0.30), accent.opacity(0.0)],
                center: .center,
                startRadius: size * 0.30,
                endRadius: size * 0.65
            )
            .blur(radius: size * 0.08)
        }
    }

    var body: some View {
        ZStack {
            // Core Animation 在合成进程中执行旋转，不再逐帧触发 SwiftUI ViewGraph 重算。
            AuroraGradientLayerView(
                colors: primaryColors,
                startPoint: CGPoint(x: 0.5, y: 0),
                endPoint: CGPoint(x: 0.5, y: 1),
                startAngle: -65,
                endAngle: 65,
                duration: 18,
                animates: animates && !reduceMotion
            )
                .blur(radius: size * 0.075)

            // glacier 专属：第二层反向旋转（向前 -65°）→ 制造"交织"流动感
            if enhanced {
                AuroraGradientLayerView(
                    colors: [
                        NSColor.white.withAlphaComponent(0.0),
                        NSColor.white.withAlphaComponent(0.42),
                        accentNSColor.withAlphaComponent(0.0),
                        NSColor.white.withAlphaComponent(0.28),
                        NSColor.white.withAlphaComponent(0.0)
                    ],
                    startPoint: CGPoint(x: 0, y: 0.5),
                    endPoint: CGPoint(x: 1, y: 0.5),
                    startAngle: 65,
                    endAngle: -65,
                    duration: 22,
                    animates: animates && !reduceMotion
                )
                .blur(radius: size * 0.10)
            }
        }
        .overlay { glowOverlay }
        .clipShape(.circle)
    }

    private var primaryColors: [NSColor] {
        let whiteHi = enhanced ? 0.58 : 0.42
        let accentMid = enhanced ? 0.42 : 0.30
        return [
            accentNSColor.withAlphaComponent(0.0),
            NSColor.white.withAlphaComponent(whiteHi),
            accentNSColor.withAlphaComponent(accentMid),
            accentNSColor.withAlphaComponent(0.0)
        ]
    }

    private var accentNSColor: NSColor {
        NSColor(accentColor)
    }

    private var accentColor: Color {
        theme.glassTint ?? Color(red: 0.62, green: 0.72, blue: 0.88)
    }
}
