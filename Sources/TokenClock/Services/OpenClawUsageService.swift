import Foundation

/// 从 OpenClaw 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.openclaw/agents/*/sessions/
final class OpenClawUsageService: @unchecked Sendable {
    private static let assistantLineNeedle = [Data("\"assistant\"".utf8)]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]
    private var fileModelContrib: [String: [String: [String: Int]]] = [:]
    /// path → date → model → billable token buckets.
    private var fileModelBucketContrib: [String: [String: [String: ModelBuckets]]] = [:]
    private var fileAgentNames: [String: String] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let openclawHome: String

    init(openclawHome: String? = nil) {
        if let openclawHome {
            self.openclawHome = openclawHome
        } else if let xdg = ProcessInfo.processInfo.environment["OPENCLAW_HOME"] {
            self.openclawHome = xdg
        } else {
            self.openclawHome = PathConfig.openclawHome()
        }
    }

    // MARK: - 公开接口

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
        fileRecentContrib.removeAll()
        fileModelContrib.removeAll()
        fileModelBucketContrib.removeAll()
        fileAgentNames.removeAll()
        recentEntries = []
        scanAgentDirectories()
    }

    func incrementalScan() {
        scanAgentDirectories()
    }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let total = d?.tokens ?? 0
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let rate = TokenAccounting.cacheReadShare(freshTokens: total, cacheRead: cache)
        return (total, d?.messages ?? 0, rate)
    }

    /// 当前小时的 token 消耗（用于热力计算）
    func currentHourTokens() -> Int {
        let key = DateHelper.currentHourKey()
        return hourlyData[key]?.tokens ?? 0
    }

    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        var tokens = 0, messages = 0
        for entry in recentEntries {
            if entry.timestamp >= cutoff {
                tokens += entry.tokens
                messages += 1
            }
        }
        return (tokens, messages)
    }

    func isActive() -> Bool {
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanAgentDirectories() {
        let agentsDir = openclawHome + "/agents"
        guard let agentNames = try? fm.contentsOfDirectory(atPath: agentsDir) else {
            evictFiles(notIn: [])
            rebuildRecentEntries()
            return
        }

        var livePaths = Set<String>()

        for name in agentNames {
            let sessionsDir = agentsDir + "/" + name + "/sessions"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { continue }

            for file in files {
                if file.contains(".checkpoint.") || file.contains(".trajectory.") || file.hasSuffix(".lock") || file == "sessions.json" { continue }
                guard file.hasSuffix(".jsonl") else { continue }

                let fullPath = sessionsDir + "/" + file
                livePaths.insert(fullPath)
                fileAgentNames[fullPath] = name
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                // 增量：减旧贡献
                if let oldContrib = fileDailyContrib[fullPath] {
                    subtractDailyContributions(oldContrib)
                }
                if let oldContrib = fileHourlyContrib[fullPath] {
                    subtractHourlyContributions(oldContrib)
                }
                if let oldContrib = fileCacheContrib[fullPath] {
                    subtractCacheContributions(oldContrib)
                }

                // 跳过 cron 触发的 session
                if isCronSession(path: fullPath) {
                    fileDailyContrib.removeValue(forKey: fullPath)
                    fileHourlyContrib.removeValue(forKey: fullPath)
                    fileCacheContrib.removeValue(forKey: fullPath)
                    fileRecentContrib.removeValue(forKey: fullPath)
                    fileModelContrib.removeValue(forKey: fullPath)
                    fileModelBucketContrib.removeValue(forKey: fullPath)
                    fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
                    continue
                }

                parseFile(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
        evictFiles(notIn: livePaths)
        rebuildRecentEntries()
    }

    private func evictFiles(notIn livePaths: Set<String>) {
        let removed = Set(fileCache.keys).subtracting(livePaths)
        for path in removed {
            if let old = fileDailyContrib[path] { subtractDailyContributions(old) }
            if let old = fileHourlyContrib[path] { subtractHourlyContributions(old) }
            if let old = fileCacheContrib[path] { subtractCacheContributions(old) }
            fileCache.removeValue(forKey: path)
            fileDailyContrib.removeValue(forKey: path)
            fileHourlyContrib.removeValue(forKey: path)
            fileCacheContrib.removeValue(forKey: path)
            fileRecentContrib.removeValue(forKey: path)
            fileModelContrib.removeValue(forKey: path)
            fileModelBucketContrib.removeValue(forKey: path)
            fileAgentNames.removeValue(forKey: path)
        }
    }

    private func subtractCacheContributions(_ contrib: [String: Int]) {
        for (dateKey, count) in contrib {
            if var existing = dailyCache[dateKey] {
                existing -= count
                if existing <= 0 {
                    dailyCache.removeValue(forKey: dateKey)
                } else {
                    dailyCache[dateKey] = existing
                }
            }
        }
    }

    private func subtractDailyContributions(_ contrib: [String: DayUsage]) {
        for (dateKey, usage) in contrib {
            if var existing = dailyData[dateKey] {
                existing.tokens -= usage.tokens
                existing.messages -= usage.messages
                if existing.tokens <= 0 && existing.messages <= 0 {
                    dailyData.removeValue(forKey: dateKey)
                } else {
                    dailyData[dateKey] = existing
                }
            }
        }
    }

    private func subtractHourlyContributions(_ contrib: [String: HourlyUsage]) {
        for (hourKey, usage) in contrib {
            if var existing = hourlyData[hourKey] {
                existing.tokens -= usage.tokens
                existing.messages -= usage.messages
                if existing.tokens <= 0 && existing.messages <= 0 {
                    hourlyData.removeValue(forKey: hourKey)
                } else {
                    hourlyData[hourKey] = existing
                }
            }
        }
    }

    private func parseFile(path: String) {
        let today = DateHelper.todayKey()
        var newDailyContrib: [String: DayUsage] = [:]
        var newHourlyContrib: [String: HourlyUsage] = [:]
        var newCacheContrib: [String: Int] = [:]
        var newRecent: [RecentEntry] = []
        var newModels: [String: [String: Int]] = [:]
        var newModelBuckets: [String: [String: ModelBuckets]] = [:]

        guard let readResult = JSONLLineReader.read(path: path, matchingAny: Self.assistantLineNeedle, onLine: { line in
            if line.contains("\"assistant\""), let result = parseAssistantLine(line) {
                accumulate(result, today: today,
                           dailyContrib: &newDailyContrib,
                           hourlyContrib: &newHourlyContrib,
                           cacheContrib: &newCacheContrib, recent: &newRecent,
                           models: &newModels, modelBuckets: &newModelBuckets)
            }
        }) else { return }
        _ = JSONLLineReader.consumeCompleteTrailingLine(readResult.trailingData) { line in
            if line.contains("\"assistant\""), let result = parseAssistantLine(line) {
                accumulate(result, today: today,
                           dailyContrib: &newDailyContrib,
                           hourlyContrib: &newHourlyContrib,
                           cacheContrib: &newCacheContrib, recent: &newRecent,
                           models: &newModels, modelBuckets: &newModelBuckets)
            }
        }

        fileDailyContrib[path] = newDailyContrib
        fileHourlyContrib[path] = newHourlyContrib
        fileCacheContrib[path] = newCacheContrib
        fileRecentContrib[path] = newRecent
        fileModelContrib[path] = newModels
        fileModelBucketContrib[path] = newModelBuckets
    }

    private struct ParseResult {
        let dateKey: String
        let hourKey: String
        let tokens: Int
        let cacheTokens: Int
        let timestamp: Date?
        let model: String?
        let buckets: ModelBuckets
    }

    private func parseAssistantLine(_ line: String) -> ParseResult? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        guard msg["role"] as? String == "assistant" else { return nil }
        guard let usage = msg["usage"] as? [String: Any] else { return nil }

        let input = usage["input"] as? Int ?? 0
        let output = usage["output"] as? Int ?? 0
        let cacheRead = usage["cacheRead"] as? Int ?? 0
        let cacheWrite = usage["cacheWrite"] as? Int ?? 0
        // OpenClaw persists input/output/cacheRead/cacheWrite as independent usage fields.
        let tokens = TokenAccounting.separateCacheFields(
            input: input, cacheWrite: cacheWrite, output: output
        )
        let cacheTokens = cacheRead
        guard tokens > 0 else { return nil }

        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        let hourKey = DateHelper.localHourKey(from: timestamp)
        guard !dateKey.isEmpty else { return nil }

        return ParseResult(dateKey: dateKey, hourKey: hourKey,
                          tokens: tokens, cacheTokens: cacheTokens,
                          timestamp: DateHelper.parseISO8601(timestamp),
                          model: (obj["model"] as? String) ?? (msg["model"] as? String),
                          buckets: ModelBuckets(
                            input: input, output: output,
                            cacheRead: cacheRead, cacheWrite: cacheWrite
                          ))
    }

    private func accumulate(_ result: ParseResult, today: String,
                            dailyContrib: inout [String: DayUsage],
                            hourlyContrib: inout [String: HourlyUsage],
                            cacheContrib: inout [String: Int],
                            recent: inout [RecentEntry],
                            models: inout [String: [String: Int]],
                            modelBuckets: inout [String: [String: ModelBuckets]]) {
        // daily
        if var existing = dailyData[result.dateKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            dailyData[result.dateKey] = existing
        } else {
            dailyData[result.dateKey] = DayUsage(tokens: result.tokens, messages: 1)
        }
        if var existing = dailyContrib[result.dateKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            dailyContrib[result.dateKey] = existing
        } else {
            dailyContrib[result.dateKey] = DayUsage(tokens: result.tokens, messages: 1)
        }
        // hourly
        if var existing = hourlyData[result.hourKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            hourlyData[result.hourKey] = existing
        } else {
            hourlyData[result.hourKey] = HourlyUsage(tokens: result.tokens, messages: 1)
        }
        if var existing = hourlyContrib[result.hourKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            hourlyContrib[result.hourKey] = existing
        } else {
            hourlyContrib[result.hourKey] = HourlyUsage(tokens: result.tokens, messages: 1)
        }
        // cache
        dailyCache[result.dateKey, default: 0] += result.cacheTokens
        cacheContrib[result.dateKey, default: 0] += result.cacheTokens
        // recentEntries（只记录今日）
        if result.dateKey == today, let ts = result.timestamp {
            recent.append(RecentEntry(timestamp: ts, tokens: result.tokens))
        }
        if let model = result.model, !model.isEmpty {
            models[result.dateKey, default: [:]][model, default: 0] += result.tokens
            modelBuckets[result.dateKey, default: [:]][model, default: ModelBuckets()]
                .merge(result.buckets)
        }
    }

    /// recentEntries 是各文件 recent 贡献的派生聚合：每轮扫描从 fileRecentContrib 重建，
    /// 而非在逐行累加时直接 append —— 否则增量重读已变化文件时 recent 会双计。
    private func rebuildRecentEntries() {
        recentEntries = fileRecentContrib.values.flatMap { $0 }
        if recentEntries.count > 64 {
            let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
            recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
        }
    }

    // MARK: - 今日活跃 Agent 列表

    func todayModelBuckets() -> [String: ModelBuckets] {
        let today = DateHelper.todayKey()
        var result: [String: ModelBuckets] = [:]
        for dates in fileModelBucketContrib.values {
            for (model, buckets) in dates[today] ?? [:] {
                result[model, default: ModelBuckets()].merge(buckets)
            }
        }
        return result
    }

    func todayCost() -> CostEstimate {
        PricingService.shared.cost(of: todayModelBuckets())
    }

    func todayCacheReadTokens() -> Int {
        dailyCache[DateHelper.todayKey()] ?? 0
    }

    /// 返回今日每个活跃 agent 的数据（用于展开展示）
    func todaySessions() -> [SessionInfo] {
        let today = DateHelper.todayKey()
        var agents: [String: (tokens: Int, messages: Int, models: [String: Int])] = [:]
        var agentBuckets: [String: [String: ModelBuckets]] = [:]
        for (path, dates) in fileDailyContrib {
            guard let usage = dates[today], let agentName = fileAgentNames[path] else { continue }
            var summary = agents[agentName] ?? (0, 0, [:])
            summary.tokens += usage.tokens
            summary.messages += usage.messages
            for (model, tokens) in fileModelContrib[path]?[today] ?? [:] {
                summary.models[model, default: 0] += tokens
            }
            for (model, buckets) in fileModelBucketContrib[path]?[today] ?? [:] {
                agentBuckets[agentName, default: [:]][model, default: ModelBuckets()].merge(buckets)
            }
            agents[agentName] = summary
        }
        return agents.compactMap { agentName, summary in
            guard summary.tokens > 0 else { return nil }
            return SessionInfo(
                rawId: agentName,
                displayName: agentName,
                detail: nil,
                todayTokens: summary.tokens,
                todayMessages: summary.messages,
                isActive: true,
                model: summary.models.max(by: { $0.value < $1.value })?.key,
                todayCost: PricingService.shared.cost(of: agentBuckets[agentName] ?? [:]),
                cacheReadTokens: (agentBuckets[agentName] ?? [:]).values.reduce(0) { $0 + $1.cacheRead }
            )
        }.sorted { $0.todayTokens > $1.todayTokens }
    }

    /// 检测 session 是否由 cron 触发
    /// OpenClaw 的 cron 任务会在 session 开始时注入一条用户消息，text 以 `[cron:<UUID> <task_name>]` 开头
    private func isCronSession(path: String) -> Bool {
        guard let stream = InputStream(fileAtPath: path) else { return false }
        stream.open()
        defer { stream.close() }

        let bufSize = AppConfig.Scan.jsonlBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)

            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                if let line = String(data: lineData, encoding: .utf8),
                   line.contains("\"user\""),
                   let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = obj["message"] as? [String: Any],
                   msg["role"] as? String == "user",
                   let content = msg["content"] as? [[String: Any]],
                   let firstText = content.first?["text"] as? String {
                    return firstText.hasPrefix("[cron:")
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"user\""),
           let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? [String: Any],
           msg["role"] as? String == "user",
           let content = msg["content"] as? [[String: Any]],
           let firstText = content.first?["text"] as? String {
            return firstText.hasPrefix("[cron:")
        }

        return false
    }

}
