import Foundation

/// Windows normal 版的数据层。复用 macOS normal 的 14 个统计服务，只替换 UI 和平台服务。
/// 与 LinuxUsageModel 同构（共享数据层在 Windows 上零改动可编译），仅 platform 标记不同。
/// 注：HourlyForecast 由 Services/WeatherService.swift 提供（Windows 纳入天气服务），此处不再 stub。
final class WindowsUsageModel: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTools: [ToolUsage]
    private var scanning = false
    private var storedNotifications: [TokenClockNotification] = []

    private var openclawService = OpenClawUsageService()
    private var claudeCodeService = ClaudeCodeUsageService()
    private var geminiService = GeminiUsageService()
    private var codexService = CodexUsageService()
    private var hermesService = HermesUsageService()
    private var opencodeService = OpenCodeUsageService()
    private var qwenService = QwenCodeUsageService()
    private var copilotService = CopilotUsageService()
    private var grokService = GrokUsageService()
    private var aiderService = AiderUsageService()
    private var antigravityService = AntigravityUsageService()
    private var clineService = ClineUsageService()
    private var continueService = ContinueUsageService()
    private var cursorAgentService = CursorAgentUsageService()
    private var codeBuddyService: CodeBuddyStatsService?
    private var reloadServicesBeforeNextScan = false

    private static let allToolNames = Set(WindowsProviderCatalog.orderedEntries.map(\.displayName))

    private var _enabledTools: Set<String>
    var enabledTools: Set<String> { _enabledTools }
    /// 速率窗口（分钟）：实时读 UserDefaults，设置面板改了即时生效（无需重启）。
    var rateWindowMinutes: Int {
        let v = UserDefaults.standard.int(for: .rateWindow)
        return v > 0 ? v : 10
    }

    init() {
        let saved = UserDefaults.standard.stringArray(for: .enabledTools)
        _enabledTools = WindowsProviderCatalog.enabledDisplayNames(saved: saved)
        storedTools = MockUsageService.generateInitialData(enabledTools: _enabledTools)

        if !PathConfig.hasRunInitialDetection {
            PathConfig.hasRunInitialDetection = true
            let summary = PathDetector.runFullDetection()
            saveDetectedPaths(summary.results)
            // Service instances capture their paths during construction, which happens before
            // this init body. Recreate them at the next scan after first-run detection saves an
            // environment/alternate path.
            reloadServicesBeforeNextScan = summary.foundCount > 0
        }

        // 每周自动静默刷新价格目录（与 macOS/Linux 一致）
        if PricingService.shared.isStale() {
            Task.detached(priority: .utility) {
                try? await PricingService.shared.refresh()
            }
        }
    }

    /// 设置面板改了启用工具集后立即生效（tools 过滤 + 下次扫描范围都读此集合）。
    func updateEnabledTools(_ tools: Set<String>) { _enabledTools = tools.intersection(Self.allToolNames) }

    /// Settings paths are live: mark all readers for recreation before the next scan instead of
    /// requiring an app restart. The flag is consumed only by the single active scanner.
    func reloadProviderPaths() {
        lock.lock()
        reloadServicesBeforeNextScan = true
        lock.unlock()
    }

    var tools: [ToolUsage] {
        lock.lock()
        defer { lock.unlock() }
        return storedTools
            .filter { enabledTools.contains($0.name) }
            .sorted {
                if $0.measurementUnit != $1.measurementUnit {
                    return $0.measurementUnit == .tokens
                }
                return $0.value > $1.value
            }
    }

    @discardableResult
    func scan(incremental: Bool) -> Bool {
        lock.lock()
        if scanning {
            lock.unlock()
            return false
        }
        scanning = true
        let shouldReload = reloadServicesBeforeNextScan
        reloadServicesBeforeNextScan = false
        lock.unlock()

        if shouldReload { recreateServices() }

        defer {
            lock.lock()
            scanning = false
            lock.unlock()
        }

        if enabledTools.contains("OpenClaw") { incremental ? openclawService.incrementalScan() : openclawService.fullScan() }
        if enabledTools.contains("Claude Code") { incremental ? claudeCodeService.incrementalScan() : claudeCodeService.fullScan() }
        if enabledTools.contains("Gemini CLI") { incremental ? geminiService.incrementalScan() : geminiService.fullScan() }
        if enabledTools.contains("Codex") { incremental ? codexService.incrementalScan() : codexService.fullScan() }
        if enabledTools.contains("Hermes") { incremental ? hermesService.incrementalScan() : hermesService.fullScan() }
        if enabledTools.contains("OpenCode") { incremental ? opencodeService.incrementalScan() : opencodeService.fullScan() }
        if enabledTools.contains("Qwen Code") { incremental ? qwenService.incrementalScan() : qwenService.fullScan() }
        if enabledTools.contains("Copilot") { incremental ? copilotService.incrementalScan() : copilotService.fullScan() }
        if enabledTools.contains("Grok") { incremental ? grokService.incrementalScan() : grokService.fullScan() }
        if enabledTools.contains("Aider") { incremental ? aiderService.incrementalScan() : aiderService.fullScan() }
        if enabledTools.contains("Antigravity") { incremental ? antigravityService.incrementalScan() : antigravityService.fullScan() }
        if enabledTools.contains("Cline") { incremental ? clineService.incrementalScan() : clineService.fullScan() }
        if enabledTools.contains("Continue") { incremental ? continueService.incrementalScan() : continueService.fullScan() }
        if enabledTools.contains("Cursor Agent") { incremental ? cursorAgentService.incrementalScan() : cursorAgentService.fullScan() }
        var codeBuddyUsage: CodeBuddyStatsService.UsageSnapshot?
        if enabledTools.contains("CodeBuddy CLI") {
            if codeBuddyService == nil { codeBuddyService = CodeBuddyStatsService(endpoint: PathConfig.codeBuddyEndpoint()) }
            codeBuddyUsage = codeBuddyService?.currentSessionUsage()
        }

        var results: [String: ScanSnapshot] = [:]
        if enabledTools.contains("OpenClaw") {
            let usage = openclawService.todayUsage()
            results["OpenClaw"] = snapshot(usage, openclawService.recentUsage(minutes: rateWindowMinutes).tokens, openclawService.currentHourTokens(), openclawService.isActive(), openclawService.todaySessions(), measurementValue: nil, measurementScope: .today, openclawService.todayCost(), openclawService.todayCacheReadTokens())
        }
        if enabledTools.contains("Claude Code") {
            let usage = claudeCodeService.todayUsage()
            results["Claude Code"] = snapshot(usage, claudeCodeService.recentUsage(minutes: rateWindowMinutes).tokens, claudeCodeService.currentHourTokens(), claudeCodeService.isActive(), claudeCodeService.todaySessions(), measurementValue: nil, measurementScope: .today, claudeCodeService.todayCost(), claudeCodeService.todayCacheReadTokens())
        }
        if enabledTools.contains("Gemini CLI") {
            let usage = geminiService.todayUsage()
            results["Gemini CLI"] = snapshot(usage, geminiService.recentUsage(minutes: rateWindowMinutes).tokens, geminiService.currentHourTokens(), geminiService.isActive(), geminiService.todaySessions())
        }
        if enabledTools.contains("Codex") {
            let usage = codexService.todayUsage()
            results["Codex"] = snapshot(usage, codexService.recentUsage(minutes: rateWindowMinutes).tokens, codexService.currentHourTokens(), codexService.isActive(), codexService.todaySessions(), measurementValue: nil, measurementScope: .today, codexService.todayCost(), codexService.todayCacheReadTokens())
        }
        if enabledTools.contains("Hermes") {
            let usage = hermesService.todayUsage()
            results["Hermes"] = snapshot(usage, hermesService.recentUsage(minutes: rateWindowMinutes).tokens, hermesService.currentHourTokens(), hermesService.isActive(), hermesService.todaySessions())
        }
        if enabledTools.contains("OpenCode") {
            let usage = opencodeService.todayUsage()
            results["OpenCode"] = snapshot(usage, opencodeService.recentUsage(minutes: rateWindowMinutes).tokens, opencodeService.currentHourTokens(), opencodeService.isActive(), opencodeService.todaySessions())
        }
        if enabledTools.contains("Qwen Code") {
            let usage = qwenService.todayUsage()
            results["Qwen Code"] = snapshot(usage, qwenService.recentUsage(minutes: rateWindowMinutes).tokens, qwenService.currentHourTokens(), qwenService.isActive(), qwenService.todaySessions())
        }
        if enabledTools.contains("Copilot") {
            let usage = copilotService.todayUsage()
            results["Copilot"] = snapshot(usage, copilotService.recentUsage(minutes: rateWindowMinutes).tokens, copilotService.currentHourTokens(), copilotService.isActive(), copilotService.todaySessions())
        }
        if enabledTools.contains("Grok") {
            let usage = grokService.todayUsage()
            results["Grok"] = snapshot(usage, grokService.recentUsage(minutes: rateWindowMinutes).tokens, grokService.currentHourTokens(), grokService.isActive(), grokService.todaySessions())
        }
        if enabledTools.contains("Aider") {
            let usage = aiderService.todayUsage()
            results["Aider"] = snapshot(usage, aiderService.recentUsage(minutes: rateWindowMinutes).tokens, aiderService.currentHourTokens(), aiderService.isActive(), aiderService.todaySessions())
        }
        if enabledTools.contains("Antigravity") {
            let usage = antigravityService.todayUsage()
            results["Antigravity"] = snapshot(usage, antigravityService.recentUsage(minutes: rateWindowMinutes).tokens, antigravityService.currentHourTokens(), antigravityService.isActive(), antigravityService.todaySessions(), measurementValue: nil, measurementScope: .today, antigravityService.todayCost(), antigravityService.todayCacheReadTokens())
        }
        if enabledTools.contains("Cline") {
            let usage = clineService.todayUsage()
            results["Cline"] = snapshot(usage, clineService.recentUsage(minutes: rateWindowMinutes).tokens, clineService.currentHourTokens(), clineService.isActive(), clineService.todaySessions())
        }
        if enabledTools.contains("Continue") {
            let usage = continueService.todayUsage()
            results["Continue"] = snapshot(usage, continueService.recentUsage(minutes: rateWindowMinutes).tokens, continueService.currentHourTokens(), continueService.isActive(), continueService.todaySessions())
        }
        if enabledTools.contains("Cursor Agent") {
            let usage = cursorAgentService.todayUsage()
            results["Cursor Agent"] = snapshot(usage, cursorAgentService.recentUsage(minutes: rateWindowMinutes).tokens, cursorAgentService.currentHourTokens(), cursorAgentService.isActive(), cursorAgentService.todaySessions())
        }
        if enabledTools.contains("CodeBuddy CLI") {
            let value = codeBuddyUsage?.tokens ?? 0
            results["CodeBuddy CLI"] = snapshot(
                (tokens: 0, messages: 0, cacheRate: 0),
                0, 0, value > 0, [],
                measurementValue: codeBuddyUsage?.tokens,
                measurementScope: .currentSession
            )
        }

        lock.lock()
        for (name, result) in results {
            guard let index = storedTools.firstIndex(where: { $0.name == name }) else { continue }
            let old = storedTools[index]
            storedTools[index] = ToolUsage(
                name: old.name,
                abbreviation: old.abbreviation,
                emoji: old.emoji,
                measurementUnit: old.measurementUnit,
                measurementScope: result.measurementScope,
                measurementValue: result.measurementValue,
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
        appendPendingReports()
        return true
    }

    var notifications: [TokenClockNotification] {
        lock.lock(); defer { lock.unlock() }
        return storedNotifications
    }

    var unreadNotificationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedNotifications.filter { !$0.isRead }.count
    }

    func markNotificationsRead() {
        lock.lock(); defer { lock.unlock() }
        storedNotifications = storedNotifications.map { notification in
            var copy = notification
            copy.isRead = true
            return copy
        }
    }

    private func appendPendingReports() {
        let reports = UsageReportScheduler.generatePendingReports()
        guard !reports.isEmpty else { return }
        lock.lock()
        storedNotifications.insert(contentsOf: reports.reversed(), at: 0)
        if storedNotifications.count > 20 { storedNotifications = Array(storedNotifications.prefix(20)) }
        lock.unlock()
    }

    private func recreateServices() {
        // Recreate only readers that can actually scan, avoiding resources for disabled tools.
        // A provider newly enabled in Settings is already present in enabledTools here.
        if enabledTools.contains("OpenClaw") { openclawService = OpenClawUsageService() }
        if enabledTools.contains("Claude Code") { claudeCodeService = ClaudeCodeUsageService() }
        if enabledTools.contains("Gemini CLI") { geminiService = GeminiUsageService() }
        if enabledTools.contains("Codex") { codexService = CodexUsageService() }
        if enabledTools.contains("Hermes") { hermesService = HermesUsageService() }
        if enabledTools.contains("OpenCode") { opencodeService = OpenCodeUsageService() }
        if enabledTools.contains("Qwen Code") { qwenService = QwenCodeUsageService() }
        if enabledTools.contains("Copilot") { copilotService = CopilotUsageService() }
        if enabledTools.contains("Grok") { grokService = GrokUsageService() }
        if enabledTools.contains("Aider") { aiderService = AiderUsageService() }
        if enabledTools.contains("Antigravity") { antigravityService = AntigravityUsageService() }
        if enabledTools.contains("Cline") { clineService = ClineUsageService() }
        if enabledTools.contains("Continue") { continueService = ContinueUsageService() }
        if enabledTools.contains("Cursor Agent") { cursorAgentService = CursorAgentUsageService() }
        if enabledTools.contains("CodeBuddy CLI") {
            codeBuddyService = CodeBuddyStatsService(endpoint: PathConfig.codeBuddyEndpoint())
        }
    }

    func usageJSONObject() -> [String: Any] {
        let current = tools
        var cost = CostEstimate.unavailable
        for tool in current where tool.todayTokens > 0 { cost.merge(tool.todayCost) }
        let includesCache = UserDefaults.standard.bool(for: .usageIncludesCacheRead)
        return [
            "timestamp": Self.utcTimestamp(),
            "totalTokens": UsageAggregator.totalTokens(current),
            "displayTotalTokens": UsageAggregator.totalTokens(current, includingCacheRead: includesCache),
            "usageIncludesCacheRead": includesCache,
            "totalMessages": UsageAggregator.totalMessages(current),
            "totalCost": cost.value,
            "costBasis": "api_equivalent_public_list",
            "costComplete": cost.complete,
            "costAvailable": cost.available,
            "rateEmoji": UsageAggregator.rateEmoji(current),
            "windowMinutes": rateWindowMinutes,
            "variant": "normal",
            "platform": "windows",
            "tools": current.map(Self.usageToolJSONObject),
        ]
    }

    /// Kept internal for the Windows API contract test. Legacy token-named fields remain while
    /// unit/value/scope carry honest semantics for non-today providers.
    static func usageToolJSONObject(_ tool: ToolUsage) -> [String: Any] {
        let declaration = WindowsProviderCatalog.entry(displayName: tool.name)
        let runtimeAvailable: Bool
        if tool.measurementScope == .contractOnly {
            runtimeAvailable = false
        } else if tool.measurementScope == .currentSession {
            runtimeAvailable = tool.measurementValue != nil
        } else {
            runtimeAvailable = declaration?.statisticsSupport != .contractOnly
        }
        let status = runtimeAvailable
            ? (declaration?.statisticsSupport.rawValue ?? "parsed")
            : (tool.measurementScope == .contractOnly ? "contractOnly" : "unavailable")
        return [
            "name": tool.name,
            "emoji": tool.emoji,
            "unit": tool.measurementUnit.rawValue,
            "value": tool.value,
            "scope": tool.measurementScope.rawValue,
            "recentValue": tool.recentValue,
            "hourlyValue": tool.hourlyValue,
            "statisticsAvailable": runtimeAvailable,
            "statisticsStatus": status,
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
                    "unit": tool.measurementUnit.rawValue,
                    "value": $0.todayTokens,
                    "scope": tool.measurementScope.rawValue,
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
    }

    /// ISO-8601 UTC without DateFormatter/ICU. Repeated formatter calls on the Windows
    /// swift-corelibs runtime retain native handles, which is unacceptable on a polled endpoint.
    private static func utcTimestamp(_ date: Date = Date()) -> String {
        let seconds = Int64(date.timeIntervalSince1970)
        let days = seconds / 86_400
        let secondsOfDay = Int(seconds % 86_400)

        // Howard Hinnant's civil_from_days algorithm (days since 1970-01-01 → Gregorian date).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        year += month <= 2 ? 1 : 0

        let hour = secondsOfDay / 3_600
        let minute = (secondsOfDay % 3_600) / 60
        let second = secondsOfDay % 60
        func padded(_ value: Int64, width: Int) -> String {
            let raw = String(value)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }
        return "\(padded(year, width: 4))-\(padded(month, width: 2))-\(padded(day, width: 2))T" +
               "\(padded(Int64(hour), width: 2)):\(padded(Int64(minute), width: 2)):\(padded(Int64(second), width: 2))Z"
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
                        "cost": tool.cost.value,
                        "costComplete": tool.cost.complete,
                        "costAvailable": tool.cost.available,
                        "isActive": tool.isActive,
                    ]
                    if let cache = tool.cacheReadTokens { value["cacheReadTokens"] = cache }
                    if includeSessions {
                        value["sessions"] = tool.sessions.map { session -> [String: Any] in
                            var result: [String: Any] = [
                                "id": session.id, "displayName": session.displayName,
                                "tokens": session.tokens, "messages": session.messages,
                                "cost": session.cost.value,
                                "costComplete": session.cost.complete,
                                "costAvailable": session.cost.available,
                                "isActive": session.isActive,
                            ]
                            if let model = session.model { result["model"] = model }
                            if let cache = session.cacheReadTokens { result["cacheReadTokens"] = cache }
                            return result
                        }
                    }
                    return value
                },
            ]
        }
        return ["windowDays": days, "costBasis": "api_equivalent_public_list", "days": rows]
    }

    private struct ScanSnapshot {
        let tokens: Int
        let messages: Int
        let recent: Int
        let hourly: Int
        let active: Bool
        let cacheRate: Double
        /// 今日估算费用（Claude Code / Codex 分桶计价，其余工具为 .zero）
        var cost: CostEstimate = .unavailable
        /// 今日缓存读 token 数（「包含缓存读」口径展示用）
        var cacheRead: Int = 0
        let sessions: [SessionInfo]
        let measurementValue: Int?
        let measurementScope: UsageMeasurementScope
    }

    private func snapshot(
        _ usage: (tokens: Int, messages: Int, cacheRate: Double),
        _ recent: Int,
        _ hourly: Int,
        _ active: Bool,
        _ sessions: [SessionInfo],
        measurementValue: Int? = nil,
        measurementScope: UsageMeasurementScope = .today,
        _ cost: CostEstimate = .unavailable,
        _ cacheRead: Int = 0
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
            sessions: sessions,
            measurementValue: measurementValue,
            measurementScope: measurementScope
        )
    }

    func persistCurrentUsage() {
        persistToday(tools)
    }

    private func persistToday(_ tools: [ToolUsage]) {
        let snapshots = tools.filter {
            $0.measurementUnit == .tokens && $0.measurementScope == .today
        }.map { tool in
            ToolSnapshot(
                name: tool.name,
                tokens: tool.todayTokens,
                messages: tool.todayMessages,
                cacheRate: tool.cacheRate,
                isActive: tool.isActive,
                cost: tool.todayCost,
                cacheReadTokens: tool.todayCacheReadTokens,
                sessions: tool.sessions.map {
                    SessionSnapshot(
                        id: $0.rawId,
                        displayName: $0.displayName,
                        tokens: $0.todayTokens,
                        messages: $0.todayMessages,
                        isActive: $0.isActive,
                        model: $0.model,
                        cost: $0.todayCost,
                        cacheReadTokens: $0.cacheReadTokens
                    )
                }
            )
        }
        HistoryStore.shared.upsertDay(dateKey: DateHelper.todayKey(), snapshots: snapshots)
    }

    private func saveDetectedPaths(_ results: [PathDetector.DetectionResult]) {
        for result in results where result.exists {
            guard let entry = WindowsProviderCatalog.entry(serviceID: result.service) else { continue }
            WindowsProviderCatalog.setConfiguredSource(result.detectedPath, for: entry.id)
        }
        let found = results.filter(\.exists).count
        print("[TokenClock] Windows path detection: \(found)/\(results.count) data sources found")
    }
}
