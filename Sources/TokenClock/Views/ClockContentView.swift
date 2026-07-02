import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        // 表盘大小随用户设置缩放：d = 直径，s = 相对中档(240)的缩放比。
        let d = viewModel.clockSize.diameter
        let s = viewModel.clockSize.scale

        ZStack {
            // 表盘
            ClockFaceView(
                hours: viewModel.hours,
                minutes: viewModel.minutes,
                seconds: viewModel.seconds,
                theme: viewModel.selectedTheme,
                scale: s
            )
            .frame(width: d, height: d)

            // 叠加信息：位于中心到边缘中点位置
            VStack(spacing: 0) {
                // 上方：日期 + 天气（中心到上部中点）
                VStack(spacing: 3) {
                    Text(viewModel.dateString)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                    Text(viewModel.weatherString)
                        .font(.system(size: 13 * s))
                        .foregroundColor(viewModel.selectedTheme.textPrimaryColor)
                }
                .padding(.top, 55 * s)

                Spacer()

                // 下方：tokens + 消息数（中心到下部中点）
                VStack(spacing: 2) {
                    Text(L10n.shared.tr("clock.todayTokens"))
                        .font(.system(size: 9 * s))
                        .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                    Text(viewModel.totalTokensFormatted)
                        .font(.system(size: 20 * s, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.selectedTheme.textPrimaryColor)
                    Text(viewModel.totalMessagesFormatted)
                        .font(.system(size: 10 * s))
                        .foregroundColor(viewModel.selectedTheme.textSecondaryColor)
                }
                .padding(.bottom, 48 * s)
            }

            // 左侧：活跃工具标签
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.activeToolsList) { tool in
                        Text("\(tool.emoji) \(tool.abbreviation)")
                            .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                            .foregroundColor(viewModel.selectedTheme.textPrimaryColor.opacity(0.75))
                    }
                }
                .padding(.leading, 22 * s)
                Spacer()
            }

            // 右侧：速率 emoji
            HStack {
                Spacer()
                Text(viewModel.rateEmoji)
                    .font(.system(size: 28 * s))
                    .padding(.trailing, 22 * s)
            }
        }
        .frame(width: d, height: d)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.isExpanded.toggle()
        }
    }
}
