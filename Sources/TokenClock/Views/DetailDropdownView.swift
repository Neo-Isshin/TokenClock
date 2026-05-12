import SwiftUI

/// 展开态详情列表（主题感知，支持 session/agent 展开）
struct DetailDropdownView: View {
    let tools: [ToolUsage]
    var theme: ClockFaceTheme = .classic

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
            .foregroundColor(theme.dropdownHeaderColor)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 工具列表
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .background(theme.dropdownDividerColor)
                }

                ToolExpandableRow(tool: tool, theme: theme)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.dropdownBgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dropdownBorderColor, lineWidth: 1.5)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - 可展开的工具行

private struct ToolExpandableRow: View {
    let tool: ToolUsage
    let theme: ClockFaceTheme
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 主行（点击展开/收起）
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 0) {
                    // 展开指示器
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 14)

                    Text("\(tool.emoji) \(tool.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.dropdownTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(tool.formattedTokens)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.dropdownTextColor)
                        .frame(width: 68, alignment: .trailing)

                    Text("\(tool.todayMessages)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 40, alignment: .trailing)

                    Text(formatCacheRate(tool.cacheRate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 展开的子列表
            if isExpanded && !tool.sessions.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                        .background(theme.dropdownDividerColor.opacity(0.5))
                        .padding(.horizontal, 12)

                    ForEach(tool.sessions) { session in
                        SessionRow(
                            session: session,
                            isOpenClaw: tool.name == "OpenClaw",
                            theme: theme
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func formatCacheRate(_ rate: Double) -> String {
        if rate <= 0 { return "-" }
        return String(format: "%.0f%%", rate * 100)
    }
}

// MARK: - Session / Agent 子行

private struct SessionRow: View {
    let session: SessionInfo
    let isOpenClaw: Bool
    let theme: ClockFaceTheme

    var body: some View {
        HStack(spacing: 0) {
            // 缩进
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)

            // 名称区域
            VStack(alignment: .leading, spacing: 1) {
                if isOpenClaw {
                    // OpenClaw：直接显示 agent 名
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.dropdownTextColor)
                } else {
                    // 其他工具：session 标签 + ID
                    Text("session")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(theme.dropdownSubtextColor)
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.dropdownTextColor)
                }

                if let detail = session.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundColor(theme.dropdownSubtextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.formattedTokens)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.dropdownSubtextColor)
                .frame(width: 68, alignment: .trailing)

            Text("\(session.todayMessages)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.dropdownSubtextColor)
                .frame(width: 40, alignment: .trailing)

            // 子行无缓存率列，占位保持对齐
            Rectangle()
                .fill(Color.clear)
                .frame(width: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            session.isActive
                ? theme.dropdownTextColor.opacity(0.04)
                : Color.clear
        )
    }
}
