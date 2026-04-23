import SwiftUI

/// 展开态详情列表
struct DetailDropdownView: View {
    let tools: [ToolUsage]

    /// 与表盘一致的背景色
    private let bgColor = Color(red: 0.94, green: 0.94, blue: 0.95)

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("今日消耗")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.48))
                .padding(.top, 8)
                .padding(.bottom, 6)

            // 工具列表
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .background(Color(white: 0.85))
                }

                HStack {
                    // 工具名
                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.18, green: 0.18, blue: 0.20))

                    Spacer()

                    // Token 数
                    Text(tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.18, green: 0.18, blue: 0.20))
                        .frame(width: 60, alignment: .trailing)

                    // 消息数
                    Text("\(tool.todayMessages)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.48))
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.82), lineWidth: 1.5)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}
