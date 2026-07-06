import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        // 表盘大小随用户设置缩放：d = 直径，s = 相对中档(240)的缩放比。
        let d = viewModel.clockSize.diameter
        let s = viewModel.clockSize.scale

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
                        Text(viewModel.weatherString)
                            .font(.system(size: 13 * s))
                            .foregroundColor(viewModel.effectiveDialPrimary)
                    }
                    .padding(.top, 55 * s)

                    Spacer()

                    // 下方：tokens + 消息数（中心到下部中点）
                    VStack(spacing: 2) {
                        Text(L10n.shared.tr("clock.todayTokens"))
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
                            Text("\(tool.emoji) \(tool.abbreviation)")
                                .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                                .foregroundColor(viewModel.effectiveDialPrimary)
                        }
                    }
                    .padding(.leading, 28 * s)
                    Spacer()
                }

                // 右侧：速率 emoji
                HStack {
                    Spacer()
                    Text(viewModel.rateEmoji)
                        .font(.system(size: 28 * s))
                        .padding(.trailing, 28 * s)
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
                glassTintHex: viewModel.glassTintHex
            ))
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.isExpanded.toggle()
            }
        }
        .frame(width: d, height: d)
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
            if UserDefaults.standard.bool(forKey: "TC_GLASS_PROBE") {
                // SPIKE：私有 API 折射探针（NSGlassEffectView set_variant:/set_contentLensing:）。
                // 见 LiquidGlassDial.swift。材质=variant、折射=lensing(锁6)、底色=tintColor。
                // .id(glassVariant)：换材质时重建 NSGlassEffectView（variant 会重建内部子层，比 in-place 改更可靠）。
                let tintNS = glassTintHex.flatMap { CodableColor(hex: $0) }?.nsColor
                content
                    .background(
                        LiquidGlassDial(diameter: diameter, variant: glassVariant, tintColor: tintNS)
                            .id(glassVariant)
                    )
            } else {
                // macOS 27 Beta：.clear.tint(_:) 会把 tint 渲染成实心色（bug），故单用 .clear
                // 拿最清透的液态玻璃，表盘着色交给背后 GlassAurora 流光。
                content
                    .glassEffect(
                        .clear.interactive(),
                        in: .circle
                    )
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
    @State private var rotate = false
    @State private var rotateReverse = false

    private var sheen: [Color] {
        let accent = theme.glassTint ?? Color(red: 0.62, green: 0.72, blue: 0.88)
        // glacier 加强：白色高光从 0.42 → 0.58，accent 透明度从 0.30 → 0.42
        let whiteHi = enhanced ? 0.58 : 0.42
        let accentMid = enhanced ? 0.42 : 0.30
        return [
            accent.opacity(0.0),
            Color.white.opacity(whiteHi),
            accent.opacity(accentMid),
            accent.opacity(0.0)
        ]
    }

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
        Group {
            // 主流动层（向后旋转 65°）
            LinearGradient(colors: sheen, startPoint: .top, endPoint: .bottom)
                .rotationEffect(.degrees(rotate ? 65 : -65))
                .blur(radius: size * 0.075)

            // glacier 专属：第二层反向旋转（向前 -65°）→ 制造"交织"流动感
            if enhanced {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        Color.white.opacity(0.42),
                        accentColor.opacity(0.0),
                        Color.white.opacity(0.28),
                        Color.white.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(rotateReverse ? -65 : 65))
                .blur(radius: size * 0.10)
            }
        }
        .overlay { glowOverlay }
        .clipShape(.circle)
        .onAppear {
            guard animates && !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                rotate = true
            }
            if enhanced {
                withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) {
                    rotateReverse = true
                }
            }
        }
    }

    private var accentColor: Color {
        theme.glassTint ?? Color(red: 0.62, green: 0.72, blue: 0.88)
    }
}
