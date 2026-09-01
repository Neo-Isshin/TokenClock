import Foundation

enum UsageOverviewGrouping: String, CaseIterable, Sendable {
    case tool
    case model
}

struct UsageOverviewMetrics: Sendable {
    let tokens: Int
    let messages: Int
    let cacheReadTokens: Int
    let cost: CostEstimate
    /// false 表示区间内至少有一条旧记录没有精确缓存读数，缓存率含估算。
    let cacheIsExact: Bool

    var averageCacheRate: Double {
        let denominator = tokens + cacheReadTokens
        return denominator > 0 ? Double(cacheReadTokens) / Double(denominator) : 0
    }

    func displayedTokens(includingCacheRead: Bool) -> Int {
        tokens + (includingCacheRead ? cacheReadTokens : 0)
    }

    static let zero = UsageOverviewMetrics(
        tokens: 0, messages: 0, cacheReadTokens: 0,
        cost: .unavailable, cacheIsExact: true
    )
}

struct UsageOverviewRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let emoji: String
    let metrics: UsageOverviewMetrics
}

struct UsageOverviewDay: Identifiable, Sendable {
    var id: String { dateKey }
    let dateKey: String
    let metrics: UsageOverviewMetrics
    /// 当天按当前 grouping 聚合的明细，供 30 天热力格悬停展示。
    let rows: [UsageOverviewRow]
}

struct UsageOverviewData: Sendable {
    let startDate: Date
    let endDate: Date
    let summary: UsageOverviewMetrics
    let days: [UsageOverviewDay]
    let rows: [UsageOverviewRow]
    let containsLegacyCacheEstimate: Bool
    let containsUnavailableCost: Bool
    let containsUnknownModel: Bool
}

enum UsageOverviewBuilder {
    private static let unknownModel = "Unknown"

    static func load(
        startDate: Date,
        endDate: Date,
        grouping: UsageOverviewGrouping,
        includingCacheRead: Bool = false,
        store: HistoryStore = .shared
    ) -> UsageOverviewData {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        let snapshots = store.query(
            from: DateHelper.dateKey(from: start),
            through: DateHelper.dateKey(from: end)
        )
        return make(
            startDate: start, endDate: end, snapshots: snapshots,
            grouping: grouping, includingCacheRead: includingCacheRead
        )
    }

    static func make(
        startDate: Date,
        endDate: Date,
        snapshots: [DaySnapshot],
        grouping: UsageOverviewGrouping,
        includingCacheRead: Bool = false
    ) -> UsageOverviewData {
        var summary = Accumulator()
        var dayMetrics: [String: UsageOverviewMetrics] = [:]
        var dayRows: [String: [UsageOverviewRow]] = [:]
        var grouped: [String: Accumulator] = [:]
        var unknownModel = false

        for day in snapshots {
            var dayTotal = Accumulator()
            var dayGrouped: [String: Accumulator] = [:]
            for tool in day.tools {
                summary.add(tool: tool)
                dayTotal.add(tool: tool)
                switch grouping {
                case .tool:
                    grouped[tool.name, default: Accumulator()].add(tool: tool)
                    dayGrouped[tool.name, default: Accumulator()].add(tool: tool)
                case .model:
                    unknownModel = addModels(from: tool, to: &grouped) || unknownModel
                    unknownModel = addModels(from: tool, to: &dayGrouped) || unknownModel
                }
            }
            dayMetrics[day.date] = dayTotal.metrics
            dayRows[day.date] = makeRows(
                from: dayGrouped, grouping: grouping,
                includingCacheRead: includingCacheRead
            )
        }

        let days = dateKeys(from: startDate, through: endDate).map { key in
            UsageOverviewDay(
                dateKey: key,
                metrics: dayMetrics[key] ?? .zero,
                rows: dayRows[key] ?? []
            )
        }
        let rows = makeRows(
            from: grouped, grouping: grouping,
            includingCacheRead: includingCacheRead
        )
        let finalSummary = summary.metrics
        return UsageOverviewData(
            startDate: startDate,
            endDate: endDate,
            summary: finalSummary,
            days: days,
            rows: rows,
            containsLegacyCacheEstimate: !finalSummary.cacheIsExact,
            containsUnavailableCost: finalSummary.displayedTokens(includingCacheRead: includingCacheRead) > 0 &&
                (!finalSummary.cost.available || !finalSummary.cost.complete),
            containsUnknownModel: grouping == .model && unknownModel
        )
    }

    private static func makeRows(
        from grouped: [String: Accumulator],
        grouping: UsageOverviewGrouping,
        includingCacheRead: Bool
    ) -> [UsageOverviewRow] {
        grouped.map { name, accumulator in
            UsageOverviewRow(
                name: name,
                emoji: grouping == .tool ? toolEmoji(name) : ModelEmoji.emoji(for: name),
                metrics: accumulator.metrics
            )
        }.filter {
            $0.metrics.tokens > 0 || $0.metrics.messages > 0 ||
            $0.metrics.cacheReadTokens > 0 || $0.metrics.cost.value > 0
        }.sorted {
            let lhs = $0.metrics.displayedTokens(includingCacheRead: includingCacheRead)
            let rhs = $1.metrics.displayedTokens(includingCacheRead: includingCacheRead)
            if lhs == rhs { return $0.name < $1.name }
            return lhs > rhs
        }
    }

    /// model 行以 session 为数据源，tool 总量是权威边界；不能归属的残差放进 Unknown。
    private static func addModels(
        from tool: DaySnapshot.Tool,
        to grouped: inout [String: Accumulator]
    ) -> Bool {
        guard !tool.sessions.isEmpty else {
            grouped[unknownModel, default: Accumulator()].add(tool: tool)
            return tool.tokens > 0 || tool.messages > 0
        }

        var sessionTokens = 0
        var sessionMessages = 0
        var sessionCache = 0
        var sessionCost = CostEstimate.unavailable
        var allSessionCostsAvailable = true
        var foundUnknown = false

        for session in tool.sessions {
            let normalizedModel = tool.name == "Cursor Agent"
                ? CursorAgentUsageService.normalizeDashboardModel(session.model)
                : ModelNormalizer.normalize(session.model)
            let name = normalizedModel ?? unknownModel
            foundUnknown = foundUnknown || name == unknownModel
            grouped[name, default: Accumulator()].add(
                tokens: session.tokens,
                messages: session.messages,
                cacheReadTokens: session.cacheReadTokens,
                fallbackCacheRate: tool.cacheRate,
                cost: session.cost
            )
            sessionTokens += session.tokens
            sessionMessages += session.messages
            if let cache = session.cacheReadTokens { sessionCache += cache }
            if session.cost.available {
                sessionCost.merge(session.cost)
            } else if session.tokens > 0 {
                allSessionCostsAvailable = false
            }
        }

        let residualTokens = max(0, tool.tokens - sessionTokens)
        let residualMessages = max(0, tool.messages - sessionMessages)
        let residualCache = tool.cacheReadTokens.map { max(0, $0 - sessionCache) }
        var residualCost = CostEstimate.unavailable
        if tool.cost.available, allSessionCostsAvailable, sessionCost.available {
            residualCost = CostEstimate(
                value: max(0, tool.cost.value - sessionCost.value),
                complete: tool.cost.complete && sessionCost.complete,
                available: true
            )
        }
        if residualTokens > 0 || residualMessages > 0 || (residualCache ?? 0) > 0 || residualCost.value > 0 {
            grouped[unknownModel, default: Accumulator()].add(
                tokens: residualTokens,
                messages: residualMessages,
                cacheReadTokens: residualCache,
                fallbackCacheRate: tool.cacheRate,
                cost: residualCost
            )
            foundUnknown = true
        }
        return foundUnknown
    }

    private static func dateKeys(from start: Date, through end: Date) -> [String] {
        var result: [String] = []
        var cursor = Calendar.current.startOfDay(for: start)
        let last = Calendar.current.startOfDay(for: end)
        while cursor <= last {
            result.append(DateHelper.dateKey(from: cursor))
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private static func toolEmoji(_ name: String) -> String {
        switch name {
        case "OpenClaw": return "🦞"
        case "Claude Code": return "✳️"
        case "Gemini CLI": return "✨"
        case "Codex": return "🤖"
        case "Hermes": return "⚕️"
        case "OpenCode": return "🐙"
        case "Qwen Code": return "🟣"
        case "Copilot": return "🛩️"
        case "Grok": return "⚡"
        case "Aider": return "🤝"
        case "Antigravity": return "🛡️"
        case "Cline": return "🤖"
        case "Continue": return "▶️"
        case "Cursor Agent": return "🖱️"
        default: return "🧰"
        }
    }

    private struct Accumulator {
        var tokens = 0
        var messages = 0
        var cacheReadTokens = 0
        var cacheIsExact = true
        var cost = CostEstimate.unavailable
        var missingCost = false

        mutating func add(tool: DaySnapshot.Tool) {
            add(
                tokens: tool.tokens,
                messages: tool.messages,
                cacheReadTokens: tool.cacheReadTokens,
                fallbackCacheRate: tool.cacheRate,
                cost: tool.cost
            )
        }

        mutating func add(
            tokens: Int,
            messages: Int,
            cacheReadTokens exactCache: Int?,
            fallbackCacheRate: Double,
            cost incomingCost: CostEstimate
        ) {
            self.tokens += max(0, tokens)
            self.messages += max(0, messages)
            if let exactCache {
                cacheReadTokens += max(0, exactCache)
            } else if tokens > 0 || fallbackCacheRate > 0 {
                let rate = min(0.999_999, max(0, fallbackCacheRate))
                if rate > 0, tokens > 0 {
                    cacheReadTokens += Int((Double(tokens) * rate / (1 - rate)).rounded())
                }
                cacheIsExact = false
            }
            if incomingCost.available, tokens > 0 || incomingCost.value > 0 {
                cost.merge(incomingCost)
            } else if tokens > 0 {
                missingCost = true
            }
        }

        var metrics: UsageOverviewMetrics {
            var finalCost = cost
            if finalCost.available && missingCost { finalCost.complete = false }
            return UsageOverviewMetrics(
                tokens: tokens,
                messages: messages,
                cacheReadTokens: cacheReadTokens,
                cost: finalCost,
                cacheIsExact: cacheIsExact
            )
        }
    }
}
