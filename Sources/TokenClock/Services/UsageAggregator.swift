import Foundation

/// 聚合计算工具使用数据
enum UsageAggregator {
    /// 计算所有工具的 token 总数
    /// - Parameter includingCacheRead: true 时返回「包含缓存读」口径（todayTokens + 缓存读）
    static func totalTokens(_ tools: [ToolUsage], includingCacheRead: Bool = false) -> Int {
        tools.reduce(0) {
            $0 + $1.todayTokens + (includingCacheRead ? $1.todayCacheReadTokens : 0)
        }
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

    /// 跨所有工具，按归一化模型名归并 session，产出「按模型」视图数据。
    /// - Parameters:
    ///   - tools: 全部工具（今日消耗为 0 的会跳过）。
    ///   - unknownLabel: 取不到模型名时占位桶的显示名（由调用方从 L10n 取）。
    /// - Returns: 模型分组，按 totalTokens 降序，「未知」桶固定垫底。
    static func groupedByModel(_ tools: [ToolUsage], unknownLabel: String) -> [ModelGroup] {
        var bucket: [String: ModelGroup] = [:]
        for tool in tools {
            guard tool.todayTokens > 0 || tool.todayMessages > 0 else { continue }
            for session in tool.sessions {
                let name = ModelNormalizer.normalize(session.model) ?? unknownLabel
                var group = bucket[name] ?? ModelGroup(
                    name: name,
                    emoji: name == unknownLabel ? "❓" : ModelEmoji.emoji(for: name))
                group.totalTokens += session.todayTokens
                group.totalMessages += session.todayMessages
                group.totalCost.merge(session.todayCost)
                group.totalCacheReadTokens += session.cacheReadTokens
                if let idx = group.contributions.firstIndex(where: { $0.tool == tool.name }) {
                    group.contributions[idx].tokens += session.todayTokens
                    group.contributions[idx].messages += session.todayMessages
                    group.contributions[idx].cost.merge(session.todayCost)
                    group.contributions[idx].cacheReadTokens += session.cacheReadTokens
                } else {
                    var contribution = ToolContribution(
                        tool: tool.name, emoji: tool.emoji,
                        tokens: session.todayTokens, messages: session.todayMessages)
                    contribution.cost = session.todayCost
                    contribution.cacheReadTokens = session.cacheReadTokens
                    group.contributions.append(contribution)
                }
                bucket[name] = group
            }
        }
        var result = bucket.values.map { g -> ModelGroup in
            var g = g
            g.contributions.sort { $0.tokens > $1.tokens }
            return g
        }
        result.sort { lhs, rhs in
            if (lhs.name == unknownLabel) != (rhs.name == unknownLabel) {
                return lhs.name != unknownLabel
            }
            return lhs.totalTokens > rhs.totalTokens
        }
        return result
    }
}

/// 「按模型」视图：某个模型下，各工具对其的消耗贡献
struct ModelGroup: Identifiable, Hashable {
    var id: String { name }
    /// 归一化后的模型名（或「未知」占位名）
    let name: String
    /// 模型对应的 emoji 前缀（未知桶用 ❓，其余由 ModelEmoji 匹配，无命中 🧠）
    var emoji: String = "🧠"
    var totalTokens: Int = 0
    var totalMessages: Int = 0
    /// 该模型今日的估算费用（各 session 费用之和；「未知」桶必然查不到价 → 恒为 ≈ 前缀或 0）
    var totalCost: CostEstimate = .zero
    /// 该模型今日的缓存读 token 数（「包含缓存读」口径用）
    var totalCacheReadTokens: Int = 0
    /// 该模型下每个工具的贡献（按 token 降序）
    var contributions: [ToolContribution] = []

    var formattedTokens: String { TokenFormat.compact(totalTokens) }
    var formattedCost: String {
        totalTokens > 0 ? CostFormat.estimate(totalCost) : "—"
    }
}

/// 单个工具对某个模型的贡献
struct ToolContribution: Identifiable, Hashable {
    var id: String { tool }
    let tool: String
    let emoji: String
    var tokens: Int = 0
    var messages: Int = 0
    /// 该工具对该模型的今日估算费用
    var cost: CostEstimate = .zero
    /// 该工具对该模型的今日缓存读 token 数（「包含缓存读」口径用）
    var cacheReadTokens: Int = 0

    var formattedCost: String {
        tokens > 0 ? CostFormat.estimate(cost) : "—"
    }
}
