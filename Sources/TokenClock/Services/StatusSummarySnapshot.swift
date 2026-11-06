#if !os(macOS)
import Foundation
struct StatusSummarySnapshot {
    let tools: [ToolUsage]
    let includesCache: Bool

    var rankedTools: [ToolUsage] {
        tools.filter {
            $0.measurementUnit == .tokens && $0.measurementScope == .today
                && (tokens(for: $0) > 0 || $0.todayMessages > 0)
        }.sorted {
            let left = tokens(for: $0), right = tokens(for: $1)
            return left == right ? $0.name < $1.name : left > right
        }
    }

    var totalTokens: Int { UsageAggregator.totalTokens(tools, includingCacheRead: includesCache) }
    var totalMessages: Int { UsageAggregator.totalMessages(tools) }
    var cacheReadTokens: Int {
        tools.filter { $0.measurementUnit == .tokens && $0.measurementScope == .today }
            .reduce(0) { $0 + $1.todayCacheReadTokens }
    }
    var cacheShare: Double? {
        let fresh = UsageAggregator.totalTokens(tools)
        guard fresh > 0 || cacheReadTokens > 0 else { return nil }
        return TokenAccounting.cacheReadShare(freshTokens: fresh, cacheRead: cacheReadTokens)
    }
    func tokens(for tool: ToolUsage) -> Int {
        tool.todayTokens + (includesCache ? tool.todayCacheReadTokens : 0)
    }
}
#endif
