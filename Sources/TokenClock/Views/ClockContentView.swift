import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel

    /// 叠加文字颜色（浅色表盘上用深色文字）
    private let textPrimary = Color(red: 0.18, green: 0.18, blue: 0.20)
    private let textSecondary = Color(red: 0.45, green: 0.45, blue: 0.48)

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
                VStack(spacing: 2) {
                    Text("今日Tokens")
                        .font(.system(size: 9))
                        .foregroundColor(textSecondary)
                    Text(viewModel.totalTokensFormatted)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(textPrimary)
                    Text("消息数：\(viewModel.totalMessagesCount)条")
                        .font(.system(size: 10))
                        .foregroundColor(textSecondary)
                }
                .padding(.bottom, 48)
            }

            // 左侧：活跃工具标签（中心到左侧中点，无背景）
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.activeToolsList) { tool in
                        Text("\(tool.emoji) \(tool.abbreviation)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(textPrimary.opacity(0.75))
                    }
                }
                .padding(.leading, 22)
                Spacer()
            }

            // 右侧：速率 emoji（中心到右侧中点，调大）
            HStack {
                Spacer()
                Text(viewModel.rateEmoji)
                    .font(.system(size: 28))
                    .padding(.trailing, 22)
            }
        }
        .frame(width: 240, height: 240)
    }
}
