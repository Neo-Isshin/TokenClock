import SwiftUI

/// 展开态详情列表
struct DetailDropdownView: View {
    let tools: [ToolUsage]

    private let bgColor = Color(red: 0.94, green: 0.94, blue: 0.95)
    private let headerColor = Color(red: 0.55, green: 0.55, blue: 0.58)
    private let textColor = Color(red: 0.18, green: 0.18, blue: 0.20)
    private let subtextColor = Color(red: 0.45, green: 0.45, blue: 0.48)

    var body: some View {
        VStack(spacing: 0) {
            // 表头
            HStack(spacing: 0) {
                Text("实例")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("今日消耗")
                    .frame(width: 68, alignment: .trailing)
                Text("消息数")
                    .frame(width: 40, alignment: .trailing)
                Text("缓存率")
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(headerColor)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 工具列表
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .background(Color(white: 0.85))
                }

                HStack(spacing: 0) {
                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(width: 68, alignment: .trailing)

                    Text("\(tool.todayMessages)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(subtextColor)
                        .frame(width: 40, alignment: .trailing)

                    Text(formatCacheRate(tool.cacheRate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(subtextColor)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 16)
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

    private func formatCacheRate(_ rate: Double) -> String {
        if rate <= 0 { return "-" }
        return String(format: "%.0f%%", rate * 100)
    }
}
