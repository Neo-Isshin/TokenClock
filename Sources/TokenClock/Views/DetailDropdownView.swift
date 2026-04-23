import SwiftUI

/// 展开态详情列表
struct DetailDropdownView: View {
    let tools: [ToolUsage]

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("今日消耗")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 8)
                .padding(.bottom, 6)

            // 工具列表
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .background(.white.opacity(0.1))
                }

                HStack {
                    // 工具名
                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    // Token 数
                    Text(tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 60, alignment: .trailing)

                    // 消息数
                    Text("\(tool.todayMessages)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.4))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}
