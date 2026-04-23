import Foundation

/// 聚合计算工具使用数据
enum UsageAggregator {
    /// 计算所有工具的 token 总数
    static func totalTokens(_ tools: [ToolUsage]) -> Int {
        tools.reduce(0) { $0 + $1.todayTokens }
    }

    /// 计算所有工具的消息总数
    static func totalMessages(_ tools: [ToolUsage]) -> Int {
        tools.reduce(0) { $0 + $1.todayMessages }
    }

    /// 获取活跃工具（最多2个）
    static func activeTools(_ tools: [ToolUsage], limit: Int = 2) -> [ToolUsage] {
        tools.filter(\.isActive).prefix(limit).map { $0 }
    }

    /// 根据近10分钟 tokens 判断速率 emoji
    static func rateEmoji(_ tools: [ToolUsage]) -> String {
        let recentTotal = tools.reduce(0) { $0 + $1.recentTokens }
        if recentTotal > 50_000 { return "💥" }
        if recentTotal > 10_000 { return "🔥" }
        if recentTotal > 1_000  { return "🌿" }
        return "🌙"
    }

    /// 重置所有工具的 recentTokens（每10分钟调用一次）
    static func resetRecentTokens(tools: inout [ToolUsage]) {
        for i in tools.indices {
            tools[i].recentTokens = 0
        }
    }
}
