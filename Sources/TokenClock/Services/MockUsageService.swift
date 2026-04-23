import Foundation

/// 模拟 AI 工具 token 消耗数据
final class MockUsageService {
    /// 初始化4个工具的随机数据
    static func generateInitialData() -> [ToolUsage] {
        let tools: [(name: String, abbr: String, emoji: String)] = [
            ("OpenClaw", "OC", "🦞"),
            ("Gemini CLI", "GC", "✨"),
            ("Claude Code", "CC", "✳️"),
            ("Hermes", "HM", "⚕️"),
            ("Codex", "CX", "🤖"),
        ]

        return tools.map { tool in
            ToolUsage(
                name: tool.name,
                abbreviation: tool.abbr,
                emoji: tool.emoji,
                todayTokens: Int.random(in: 50_000...500_000),
                todayMessages: Int.random(in: 50...500),
                isActive: Bool.random(),
                recentTokens: 0,
                hourlyTokens: 0
            )
        }
    }

    /// 模拟增量：随机增加 tokens 和消息数
    static func simulateIncrement(tools: inout [ToolUsage]) {
        let activeCount = Int.random(in: 1...3)
        let indices = Array(0..<tools.count).shuffled().prefix(activeCount)

        for i in indices {
            let increment = Int.random(in: 500...8_000)
            let msgIncrement = Int.random(in: 1...5)
            tools[i].todayTokens += increment
            tools[i].todayMessages += msgIncrement
            tools[i].recentTokens += increment
            tools[i].isActive = true
        }

        // 标记不活跃的工具
        let activeSet = Set(indices)
        for i in 0..<tools.count where !activeSet.contains(i) {
            // 概率性地设为不活跃
            if Bool.random() {
                tools[i].isActive = false
            }
        }
    }
}
