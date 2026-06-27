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

    /// 根据近 N 分钟 token 消耗判断热力 emoji（阈值可自定义）
    static func rateEmoji(_ tools: [ToolUsage]) -> String {
        let recentTotal = tools.reduce(0) { $0 + $1.recentTokens }
        let burst = UserDefaults.standard.int(for: .rateBurst, default: 0)
        let hot = UserDefaults.standard.int(for: .rateHot, default: 0)
        let active = UserDefaults.standard.int(for: .rateActive, default: 0)
        let calm = UserDefaults.standard.int(for: .rateCalm, default: 0)

        let b = burst > 0 ? burst : 500_000
        let h = hot > 0 ? hot : 100_000
        let a = active > 0 ? active : 20_000
        let c = calm > 0 ? calm : 2_000

        if recentTotal > b { return "💥" }
        if recentTotal > h { return "🔥" }
        if recentTotal > a { return "🏃‍♂️" }
        if recentTotal > c { return "☕" }
        return "🛌"
    }

    /// 重置所有工具的 recentTokens（每10分钟调用一次）
    static func resetRecentTokens(tools: inout [ToolUsage]) {
        for i in tools.indices {
            tools[i].recentTokens = 0
        }
    }
}
