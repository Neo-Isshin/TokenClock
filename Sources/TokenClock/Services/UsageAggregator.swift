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

    /// 获取 token 消耗最高的工具（最多2个）
    static func topToolsByTokens(_ tools: [ToolUsage], limit: Int = 2) -> [ToolUsage] {
        tools.sorted { $0.todayTokens > $1.todayTokens }.prefix(limit).map { $0 }
    }

    /// 根据近10分钟 token 消耗判断热力 emoji（比整点累计更灵敏）
    static func rateEmoji(_ tools: [ToolUsage]) -> String {
        let recentTotal = tools.reduce(0) { $0 + $1.recentTokens }
        if recentTotal > 500_000 { return "💥" }   // 爆发
        if recentTotal > 100_000 { return "🔥" }   // 火热
        if recentTotal > 20_000  { return "🏃‍♂️" }  // 活跃
        if recentTotal > 2_000   { return "☕" }    // 悠闲
        return "🛌"                                // 休息
    }

    /// 重置所有工具的 recentTokens（每10分钟调用一次）
    static func resetRecentTokens(tools: inout [ToolUsage]) {
        for i in tools.indices {
            tools[i].recentTokens = 0
        }
    }
}
