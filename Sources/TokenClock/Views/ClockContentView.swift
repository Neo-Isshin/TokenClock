import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        // 外层：流动柔光在底，圆形玻璃盘体在上。
        // `.clear` 玻璃会透出 / 折射底层柔光，呈现晶莹剔透 + 微微流动的质感，
        // 不依赖桌面壁纸是否有内容。
        ZStack {
            GlassAurora(theme: viewModel.selectedTheme)
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
            .glassEffect(
                .clear.tint(viewModel.selectedTheme.glassTint).interactive(),
                in: .circle
            )
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.isExpanded.toggle()
            }
        }
        .frame(width: 240, height: 240)
    }
}

/// 玻璃背后的流动柔光：低饱和度、随主题着色、缓慢漂移。
/// 为 `.clear` 玻璃盘体提供可折射 / 透出的丰富内容，使时钟在任何壁纸上都呈晶莹质感。
struct GlassAurora: View {
    let theme: ClockFaceTheme
    var size: CGFloat = 240
    var animates: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotate = false

    private var sheen: [Color] {
        let accent = theme.glassTint ?? Color(red: 0.62, green: 0.72, blue: 0.88)
        return [
            accent.opacity(0.0),
            Color.white.opacity(0.42),
            accent.opacity(0.30),
            accent.opacity(0.0)
        ]
    }

    var body: some View {
        LinearGradient(
            colors: sheen,
            startPoint: .top,
            endPoint: .bottom
        )
        .rotationEffect(.degrees(rotate ? 65 : -65))
        .blur(radius: size * 0.075)
        .clipShape(.circle)
        .onAppear {
            guard animates && !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                rotate = true
            }
        }
    }
}
