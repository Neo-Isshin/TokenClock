import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        // 外层：流动柔光在底，圆形玻璃盘体在上。
        // `.clear` 玻璃会透出 / 折射底层柔光，呈现晶莹剔透 + 微微流动的质感，
        // 不依赖桌面壁纸是否有内容。
        ZStack {
            GlassAurora(theme: viewModel.selectedTheme, enhanced: viewModel.selectedTheme == .glacier)
                .frame(width: 240, height: 240)

            ZStack {
                // 表盘
                ClockFaceView(
                    hours: viewModel.hours,
                    minutes: viewModel.minutes,
                    seconds: viewModel.seconds,
                    theme: viewModel.selectedTheme,
                    role: .face
                )
                .frame(width: 240, height: 240)

                // 叠加信息：位于中心到边缘中点位置
                VStack(spacing: 0) {
                    // 上方：日期 + 天气（中心到上部中点）
                    VStack(spacing: 3) {
                        Text(viewModel.dateString)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                        Text(viewModel.weatherString)
                            .font(.system(size: 13))
                            .foregroundColor(viewModel.selectedTheme.textPrimaryColor)
                    }
                    .padding(.top, 55)

                    Spacer()

                    // 下方：tokens + 消息数（中心到下部中点）
                    VStack(spacing: 2) {
                        Text(L10n.shared.tr("clock.todayTokens"))
                            .font(.system(size: 9))
                            .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                        Text(viewModel.totalTokensFormatted)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(viewModel.selectedTheme.textPrimaryColor)
                        Text(viewModel.totalMessagesFormatted)
                            .font(.system(size: 10))
                            .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                    }
                    .padding(.bottom, 48)
                }

                // 左侧：活跃工具标签
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.activeToolsList) { tool in
                            Text("\(tool.emoji) \(tool.abbreviation)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(viewModel.selectedTheme.textPrimaryColor)
                        }
                    }
                    .padding(.leading, 28)
                    Spacer()
                }

                // 右侧：速率 emoji
                HStack {
                    Spacer()
                    Text(viewModel.rateEmoji)
                        .font(.system(size: 28))
                        .padding(.trailing, 28)
                }

                // 指针置于文字之上：单独一层只渲染指针 + 中心点
                ClockFaceView(
                    hours: viewModel.hours,
                    minutes: viewModel.minutes,
                    seconds: viewModel.seconds,
                    theme: viewModel.selectedTheme,
                    role: .hands
                )
                .frame(width: 240, height: 240)
            }
            .frame(width: 240, height: 240)
            // glacier 主题：跳过 .glassEffect（macOS 26 的 .clear 仍有最低档 backdrop blur，
            // glacier 想要"完全无磨砂"必须走纯色背景 + 圆形裁剪 + 依赖 GlassAurora 流动光）。
            // 其他主题保持 .glassEffect(.clear.tint(...)) 以享受系统 glass 高光 / 折射。
            .modifier(DialGlassModifier(theme: viewModel.selectedTheme))
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.isExpanded.toggle()
            }
        }
        .frame(width: 240, height: 240)
    }
}

/// 主盘玻璃修饰：glacier 主题走纯色背景（无 backdrop blur，零磨砂感），
/// 其他主题保留 `.glassEffect(.clear.tint(_:).interactive())` 享受系统 liquid glass 高光 / 折射。
struct DialGlassModifier: ViewModifier {
    let theme: ClockFaceTheme

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
            content
                .glassEffect(
                    .clear.tint(theme.glassTint).interactive(),
                    in: .circle
                )
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
