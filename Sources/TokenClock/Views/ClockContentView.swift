import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        ZStack {
            // 表盘
            ClockFaceView(
                hours: viewModel.hours,
                minutes: viewModel.minutes,
                seconds: viewModel.seconds,
                theme: viewModel.selectedTheme
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
                            .foregroundColor(viewModel.selectedTheme.textPrimaryColor.opacity(0.75))
                    }
                }
                .padding(.leading, 22)
                Spacer()
            }

            // 右侧：速率 emoji
            HStack {
                Spacer()
                Text(viewModel.rateEmoji)
                    .font(.system(size: 28))
                    .padding(.trailing, 22)
            }
        }
        .frame(width: 240, height: 240)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.isExpanded.toggle()
        }
    }
}
