import Foundation

/// 首启占位数据：让 UI 知道有哪些 AI 工具可统计。
///
/// 仅在首次启动、真实扫描结果到达前作为零值脚手架。token / message 全为 0，
/// 真实数据通过 `ViewModel.applySnapshot` 覆盖。**不再生成随机假数据**，避免误导新用户。
final class MockUsageService {
    /// 为全部已知工具生成零值占位。
    /// `enabledTools` 保留参数以兼容旧调用点，但不再影响数据（一律返回 0）。
    static func generateInitialData(enabledTools: Set<String> = .init()) -> [ToolUsage] {
        _ = enabledTools
        let tools: [(name: String, abbr: String, emoji: String)] = [
            ("OpenClaw", "OC", "🦞"),
            ("Gemini CLI", "GC", "✨"),
            ("Claude Code", "CC", "✳️"),
            ("Hermes", "HM", "⚕️"),
            ("Codex", "CX", "🤖"),
            ("OpenCode", "OD", "🐙"),
            ("Qwen Code", "QW", "🟣"),
            ("Copilot", "CP", "🐙"),
            ("Grok", "GK", "⚡"),
            ("Aider", "AI", "🤝"),
            ("Antigravity", "AG", "🛡️"),
            ("Cline", "CL", "🤖"),
            ("Continue", "CN", "▶️"),
            ("Cursor Agent", "CA", "🖱️"),
        ]

        return tools.map { tool in
            ToolUsage(
                name: tool.name,
                abbreviation: tool.abbr,
                emoji: tool.emoji,
                todayTokens: 0,
                todayMessages: 0,
                isActive: false,
                recentTokens: 0,
                hourlyTokens: 0
            )
        }
    }
}
