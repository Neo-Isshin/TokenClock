import Foundation

/// `WeatherInfo` 的跨平台字段类型；Linux normal 暂不发起定位/天气网络请求。
struct HourlyForecast: Sendable {
    let time: String
    let tempC: Int
    let emoji: String
    let description: String
}

/// Linux normal 版的数据层。复用 macOS normal 的 14 个统计服务，只替换 UI 和平台服务。
final class LinuxUsageModel: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTools: [ToolUsage]
    private var storedEnabledTools: Set<String>
    private var storedRateWindowMinutes: Int
    private var scanning = false

    // Construct parsers only after init-time Linux catalog detection has saved
    // any alternate path. Otherwise an alternate would take effect only after
    // restarting TokenClock because parser homes are captured in init().
    private lazy var openclawService = OpenClawUsageService()
    private lazy var claudeCodeService = ClaudeCodeUsageService()
    private lazy var geminiService = GeminiUsageService()
    private lazy var codexService = CodexUsageService()
    private lazy var hermesService = HermesUsageService()
    private lazy var opencodeService = OpenCodeUsageService()
    private lazy var qwenService = QwenCodeUsageService()
    private lazy var copilotService = CopilotUsageService()
    private lazy var grokService = GrokUsageService()
    private lazy var aiderService = AiderUsageService()
    private lazy var antigravityService = AntigravityUsageService()
    private lazy var clineService = ClineUsageService()
    private lazy var continueService = ContinueUsageService()
    private lazy var cursorAgentService = CursorAgentUsageService()

    static let allToolNames = Set([
        "OpenClaw", "Claude Code", "Gemini CLI", "Codex", "Hermes", "OpenCode",
        "Qwen Code", "Copilot", "Grok", "Aider", "Antigravity", "Cline",
        "Continue", "Cursor Agent",
    ])

    init() {
        let saved = UserDefaults.standard.stringArray(for: .enabledTools)
        let enabled = Set(saved ?? Array(Self.allToolNames))
        let savedWindow = UserDefaults.standard.int(for: .rateWindow)
        let rateWindow = savedWindow > 0 ? savedWindow : 10
        storedEnabledTools = enabled
        storedRateWindowMinutes = rateWindow
        storedTools = MockUsageService.generateInitialData(enabledTools: enabled)

        if !PathConfig.hasRunInitialDetection {
            PathConfig.hasRunInitialDetection = true
            let summary = PathDetector.runFullDetection()
            saveDetectedPaths(summary.results)
        }
        if PricingService.shared.isStale() {
            Task.detached(priority: .utility) { [weak self] in
                do {
                    try await PricingService.shared.refresh()
                    _ = self?.scan(incremental: true)
                } catch {}
            }
        }
    }

    var tools: [ToolUsage] {
        lock.lock()
        defer { lock.unlock() }
        return storedTools
            .filter { storedEnabledTools.contains($0.name) }
            .sorted { $0.todayTokens > $1.todayTokens }
    }

    var enabledTools: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storedEnabledTools
    }

    var rateWindowMinutes: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRateWindowMinutes
    }

    var usageIncludesCacheRead: Bool {
        UserDefaults.standard.bool(for: .usageIncludesCacheRead)
    }

    func setUsageIncludesCacheRead(_ value: Bool) {
        UserDefaults.standard.setBool(value, for: .usageIncludesCacheRead)
    }

    func applyPreferences(enabledTools: Set<String>, rateWindowMinutes: Int) {
        let normalizedTools = enabledTools.intersection(Self.allToolNames)
        let normalizedWindow = [10, 30, 60].contains(rateWindowMinutes)
            ? rateWindowMinutes : 10
        lock.lock()
        storedEnabledTools = normalizedTools
        storedRateWindowMinutes = normalizedWindow
        lock.unlock()
        UserDefaults.standard.setStringArray(Array(normalizedTools), for: .enabledTools)
        UserDefaults.standard.setInt(normalizedWindow, for: .rateWindow)
    }

    @discardableResult
    func scan(incremental: Bool) -> Bool {
        lock.lock()
        if scanning {
            lock.unlock()
            return false
        }
        scanning = true
        let enabled = storedEnabledTools
        let rateWindow = storedRateWindowMinutes
        lock.unlock()

        defer {
            lock.lock()
            scanning = false
            lock.unlock()
        }

        if enabled.contains("OpenClaw") { incremental ? openclawService.incrementalScan() : openclawService.fullScan() }
        if enabled.contains("Claude Code") { incremental ? claudeCodeService.incrementalScan() : claudeCodeService.fullScan() }
        if enabled.contains("Gemini CLI") { incremental ? geminiService.incrementalScan() : geminiService.fullScan() }
        if enabled.contains("Codex") { incremental ? codexService.incrementalScan() : codexService.fullScan() }
        if enabled.contains("Hermes") { incremental ? hermesService.incrementalScan() : hermesService.fullScan() }
        if enabled.contains("OpenCode") { incremental ? opencodeService.incrementalScan() : opencodeService.fullScan() }
        if enabled.contains("Qwen Code") { incremental ? qwenService.incrementalScan() : qwenService.fullScan() }
        if enabled.contains("Copilot") { incremental ? copilotService.incrementalScan() : copilotService.fullScan() }
        if enabled.contains("Grok") { incremental ? grokService.incrementalScan() : grokService.fullScan() }
        if enabled.contains("Aider") { incremental ? aiderService.incrementalScan() : aiderService.fullScan() }
        if enabled.contains("Antigravity") { incremental ? antigravityService.incrementalScan() : antigravityService.fullScan() }
        if enabled.contains("Cline") { incremental ? clineService.incrementalScan() : clineService.fullScan() }
        if enabled.contains("Continue") { incremental ? continueService.incrementalScan() : continueService.fullScan() }
        if enabled.contains("Cursor Agent") { incremental ? cursorAgentService.incrementalScan() : cursorAgentService.fullScan() }

        var results: [String: ScanSnapshot] = [:]
        if enabled.contains("OpenClaw") {
            let usage = openclawService.todayUsage()
            results["OpenClaw"] = snapshot(usage, openclawService.recentUsage(minutes: rateWindow).tokens, openclawService.currentHourTokens(), openclawService.isActive(), openclawService.todaySessions())
        }
        if enabled.contains("Claude Code") {
            let usage = claudeCodeService.todayUsage()
            results["Claude Code"] = snapshot(usage, claudeCodeService.recentUsage(minutes: rateWindow).tokens, claudeCodeService.currentHourTokens(), claudeCodeService.isActive(), claudeCodeService.todaySessions(), cost: claudeCodeService.todayCost(), cacheRead: claudeCodeService.todayCacheReadTokens())
        }
        if enabled.contains("Gemini CLI") {
            let usage = geminiService.todayUsage()
            results["Gemini CLI"] = snapshot(usage, geminiService.recentUsage(minutes: rateWindow).tokens, geminiService.currentHourTokens(), geminiService.isActive(), geminiService.todaySessions())
        }
        if enabled.contains("Codex") {
            let usage = codexService.todayUsage()
            results["Codex"] = snapshot(usage, codexService.recentUsage(minutes: rateWindow).tokens, codexService.currentHourTokens(), codexService.isActive(), codexService.todaySessions(), cost: codexService.todayCost(), cacheRead: codexService.todayCacheReadTokens())
        }
        if enabled.contains("Hermes") {
            let usage = hermesService.todayUsage()
            results["Hermes"] = snapshot(usage, hermesService.recentUsage(minutes: rateWindow).tokens, hermesService.currentHourTokens(), hermesService.isActive(), hermesService.todaySessions())
        }
        if enabled.contains("OpenCode") {
            let usage = opencodeService.todayUsage()
            results["OpenCode"] = snapshot(usage, opencodeService.recentUsage(minutes: rateWindow).tokens, opencodeService.currentHourTokens(), opencodeService.isActive(), opencodeService.todaySessions())
        }
        if enabled.contains("Qwen Code") {
            let usage = qwenService.todayUsage()
            results["Qwen Code"] = snapshot(usage, qwenService.recentUsage(minutes: rateWindow).tokens, qwenService.currentHourTokens(), qwenService.isActive(), qwenService.todaySessions())
        }
        if enabled.contains("Copilot") {
            let usage = copilotService.todayUsage()
            results["Copilot"] = snapshot(usage, copilotService.recentUsage(minutes: rateWindow).tokens, copilotService.currentHourTokens(), copilotService.isActive(), copilotService.todaySessions())
        }
        if enabled.contains("Grok") {
            let usage = grokService.todayUsage()
            results["Grok"] = snapshot(usage, grokService.recentUsage(minutes: rateWindow).tokens, grokService.currentHourTokens(), grokService.isActive(), grokService.todaySessions())
        }
        if enabled.contains("Aider") {
            let usage = aiderService.todayUsage()
            results["Aider"] = snapshot(usage, aiderService.recentUsage(minutes: rateWindow).tokens, aiderService.currentHourTokens(), aiderService.isActive(), aiderService.todaySessions())
        }
        if enabled.contains("Antigravity") {
            let usage = antigravityService.todayUsage()
            results["Antigravity"] = snapshot(usage, antigravityService.recentUsage(minutes: rateWindow).tokens, antigravityService.currentHourTokens(), antigravityService.isActive(), antigravityService.todaySessions())
        }
        if enabled.contains("Cline") {
            let usage = clineService.todayUsage()
            results["Cline"] = snapshot(usage, clineService.recentUsage(minutes: rateWindow).tokens, clineService.currentHourTokens(), clineService.isActive(), clineService.todaySessions())
        }
        if enabled.contains("Continue") {
            let usage = continueService.todayUsage()
            results["Continue"] = snapshot(usage, continueService.recentUsage(minutes: rateWindow).tokens, continueService.currentHourTokens(), continueService.isActive(), continueService.todaySessions())
        }
        if enabled.contains("Cursor Agent") {
            let usage = cursorAgentService.todayUsage()
            results["Cursor Agent"] = snapshot(usage, cursorAgentService.recentUsage(minutes: rateWindow).tokens, cursorAgentService.currentHourTokens(), cursorAgentService.isActive(), cursorAgentService.todaySessions())
        }

        lock.lock()
        for (name, result) in results {
            guard let index = storedTools.firstIndex(where: { $0.name == name }) else { continue }
            let old = storedTools[index]
            storedTools[index] = ToolUsage(
                name: old.name,
                abbreviation: old.abbreviation,
                emoji: old.emoji,
                todayTokens: result.tokens,
                todayMessages: result.messages,
                isActive: result.active,
                cacheRate: result.cacheRate,
                recentTokens: result.recent,
                hourlyTokens: result.hourly,
                todayCost: result.cost,
                todayCacheReadTokens: result.cacheRead,
                sessions: result.sessions
            )
        }
        let current = storedTools
        lock.unlock()

        persistToday(current)
        return true
    }

    func usageJSONObject() -> [String: Any] {
        let current = tools
        let includesCache = usageIncludesCacheRead
        var totalCost = CostEstimate.unavailable
        for tool in current where tool.todayTokens > 0 { totalCost.merge(tool.todayCost) }
        return [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "totalTokens": UsageAggregator.totalTokens(current),
            "displayTotalTokens": UsageAggregator.totalTokens(current, includingCacheRead: includesCache),
            "usageIncludesCacheRead": includesCache,
            "totalMessages": UsageAggregator.totalMessages(current),
            "totalCost": totalCost.value,
            "costComplete": totalCost.complete,
            "costAvailable": totalCost.available,
            "rateEmoji": UsageAggregator.rateEmoji(current),
            "windowMinutes": rateWindowMinutes,
            "variant": "normal",
            "platform": "linux",
            "tools": current.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "emoji": tool.emoji,
                    "todayTokens": tool.todayTokens,
                    "todayCacheReadTokens": tool.todayCacheReadTokens,
                    "todayMessages": tool.todayMessages,
                    "todayCost": tool.todayCost.value,
                    "costComplete": tool.todayCost.complete,
                    "costAvailable": tool.todayCost.available,
                    "isActive": tool.isActive,
                    "cacheRate": tool.cacheRate,
                    "recentTokens": tool.recentTokens,
                    "hourlyTokens": tool.hourlyTokens,
                    "sessions": tool.sessions.map {
                        [
                            "id": $0.rawId,
                            "displayName": $0.displayName,
                            "todayTokens": $0.todayTokens,
                            "todayCacheReadTokens": $0.cacheReadTokens,
                            "todayMessages": $0.todayMessages,
                            "todayCost": $0.todayCost.value,
                            "costComplete": $0.todayCost.complete,
                            "costAvailable": $0.todayCost.available,
                            "isActive": $0.isActive,
                        ] as [String: Any]
                    },
                ]
            },
        ]
    }

    func historyJSONObject(days requestedDays: Int, includeSessions: Bool) -> [String: Any] {
        let days = min(AppConfig.History.retentionDays, max(1, requestedDays))
        let snapshots = HistoryStore.shared.queryRecent(days: days)
        let calendar = Calendar.current
        let rows: [[String: Any]] = (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = DateHelper.dateKey(from: date)
            guard let snapshot = snapshots.first(where: { $0.date == key }) else {
                return ["date": key, "totalTokens": 0, "totalMessages": 0, "tools": []]
            }
            return [
                "date": snapshot.date,
                "totalTokens": snapshot.totalTokens,
                "totalMessages": snapshot.totalMessages,
                "tools": snapshot.tools.map { tool -> [String: Any] in
                    var value: [String: Any] = [
                        "name": tool.name,
                        "tokens": tool.tokens,
                        "messages": tool.messages,
                        "cacheRate": tool.cacheRate,
                        "isActive": tool.isActive,
                    ]
                    if includeSessions {
                        value["sessions"] = tool.sessions.map {
                            [
                                "id": $0.id,
                                "displayName": $0.displayName,
                                "tokens": $0.tokens,
                                "messages": $0.messages,
                                "isActive": $0.isActive,
                            ] as [String: Any]
                        }
                    }
                    return value
                },
            ]
        }
        return ["windowDays": days, "days": rows]
    }

    private struct ScanSnapshot {
        let tokens: Int
        let messages: Int
        let recent: Int
        let hourly: Int
        let active: Bool
        let cacheRate: Double
        var cost: CostEstimate = .unavailable
        var cacheRead: Int = 0
        let sessions: [SessionInfo]
    }

    private func snapshot(
        _ usage: (tokens: Int, messages: Int, cacheRate: Double),
        _ recent: Int,
        _ hourly: Int,
        _ active: Bool,
        _ sessions: [SessionInfo],
        cost: CostEstimate = .unavailable,
        cacheRead: Int = 0
    ) -> ScanSnapshot {
        ScanSnapshot(
            tokens: usage.tokens,
            messages: usage.messages,
            recent: recent,
            hourly: hourly,
            active: active,
            cacheRate: usage.cacheRate,
            cost: cost,
            cacheRead: cacheRead,
            sessions: sessions
        )
    }

    private func persistToday(_ tools: [ToolUsage]) {
        let snapshots = tools.map { tool in
            ToolSnapshot(
                name: tool.name,
                tokens: tool.todayTokens,
                messages: tool.todayMessages,
                cacheRate: tool.cacheRate,
                isActive: tool.isActive,
                sessions: tool.sessions.map {
                    SessionSnapshot(
                        id: $0.rawId,
                        displayName: $0.displayName,
                        tokens: $0.todayTokens,
                        messages: $0.todayMessages,
                        isActive: $0.isActive
                    )
                }
            )
        }
        HistoryStore.shared.upsertDay(dateKey: DateHelper.todayKey(), snapshots: snapshots)
    }

    private func saveDetectedPaths(_ results: [PathDetector.DetectionResult]) {
        for result in results where result.exists {
            switch result.service {
            case "openclaw": PathConfig.setOpenclawPath(result.detectedPath)
            case "claudeCode": PathConfig.setClaudeCodePath(result.detectedPath)
            case "gemini": PathConfig.setGeminiPath(result.detectedPath)
            case "codex": PathConfig.setCodexPath(result.detectedPath)
            case "hermes": PathConfig.setHermesPath(result.detectedPath)
            case "opencode": PathConfig.setOpenCodePath(result.detectedPath)
            case "qwen": PathConfig.setQwenPath(result.detectedPath)
            case "copilot": PathConfig.setCopilotPath(result.detectedPath)
            case "grok": PathConfig.setGrokPath(result.detectedPath)
            case "aider": PathConfig.setAiderPath(result.detectedPath)
            case "antigravity": PathConfig.setAntigravityPath(result.detectedPath)
            case "cline": PathConfig.setClinePath(result.detectedPath)
            case "continue": PathConfig.setContinuePath(result.detectedPath)
            case "cursorAgent": PathConfig.setCursorAgentPath(result.detectedPath)
            default: break
            }
        }
        let found = results.filter(\.exists).count
        print("[TokenClock] Linux path detection: \(found)/\(results.count) data sources found")
    }
}
