import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    /// 叠加文字颜色（浅色表盘上用深色文字）
    private let textPrimary = Color(red: 0.2, green: 0.2, blue: 0.22)
    private let textSecondary = Color(red: 0.4, green: 0.4, blue: 0.42)

    var body: some View {
        ZStack {
            // 表盘
            ClockFaceView(
                hours: viewModel.hours,
                minutes: viewModel.minutes,
                seconds: viewModel.seconds,
                onTap: { viewModel.isExpanded.toggle() }
            )
            .frame(width: 240, height: 240)

            // 叠加信息：位于中心到边缘中点位置
            VStack(spacing: 0) {
                // 上方：日期 + 天气（中心到上部中点）
                VStack(spacing: 3) {
                    Text(viewModel.dateString)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textSecondary)
                    Text(viewModel.weatherString)
                        .font(.system(size: 13))
                        .foregroundColor(textPrimary)
                }
                .padding(.top, 55)

                Spacer()

                // 下方：tokens + 消息数（中心到下部中点）
                VStack(spacing: 3) {
                    Text(viewModel.totalTokensFormatted)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(textPrimary)
                    Text(viewModel.totalMessagesFormatted)
                        .font(.system(size: 11))
                        .foregroundColor(textSecondary)
                }
                .padding(.bottom, 58)
            }

            // 左侧：活跃工具标签（中心到左侧中点）
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(viewModel.activeToolsList) { tool in
                        Text("\(tool.emoji) \(tool.abbreviation)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(textPrimary.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.5))
                            )
                    }
                }
                .padding(.leading, 30)
                Spacer()
            }

            // 右侧：速率 emoji（中心到右侧中点）
            HStack {
                Spacer()
                Text(viewModel.rateEmoji)
                    .font(.system(size: 20))
                    .padding(.trailing, 30)
            }
        }
        .frame(width: 240, height: 240)
    }
}
