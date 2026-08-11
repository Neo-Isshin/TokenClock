import Foundation

/// 从 Gemini CLI 本地 session 文件读取 token 使用数据
/// 支持两种格式：
/// - JSON 格式: ~/.gemini/tmp/*/chats/session-*.json （旧版）
/// - JSONL 格式: ~/.gemini/tmp/*/chats/session-*.jsonl （新版，优先）
final class GeminiUsageService: @unchecked Sendable {
    private static let jsonlLineNeedles = [
        Data("\"gemini\"".utf8),
        Data("\"sessionId\"".utf8),
    ]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]
    private var fileLastModel: [String: [String: String]] = [:]
    private var fileSessionId: [String: String] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let geminiHome: String

    init(geminiHome: String? = nil) {
        self.geminiHome = geminiHome ?? PathConfig.geminiHome()
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
        fileRecentContrib.removeAll()
        fileLastModel.removeAll()
        fileSessionId.removeAll()
        recentEntries = []
        scanSessionsDir()
    }

    func incrementalScan() { scanSessionsDir() }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let total = d?.tokens ?? 0
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let rate = TokenAccounting.cacheReadShare(freshTokens: total, cacheRead: cache)
        return (total, d?.messages ?? 0, rate)
    }

    func currentHourTokens() -> Int {
        hourlyData[DateHelper.currentHourKey()]?.tokens ?? 0
    }

    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        var tokens = 0, messages = 0
        for entry in recentEntries {
            if entry.timestamp >= cutoff { tokens += entry.tokens; messages += 1 }
        }
        return (tokens, messages)
    }

    func isActive() -> Bool {
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanSessionsDir() {
        let tmpDir = geminiHome + "/tmp"
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: tmpDir) else {
            evictFiles(notIn: [])
            rebuildRecentEntries()
            return
        }

        var livePaths = Set<String>()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(AppConfig.Scan.geminiSessionLookbackDays - 1),
            to: startOfToday
        ) ?? startOfToday

        for project in projectDirs {
            let chatsDir = tmpDir + "/" + project + "/chats"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            // 记录有 JSONL 版本的 session，优先使用 JSONL 以避免重复计数
            var jsonlSessions = Set<String>()
            for file in files where file.hasPrefix("session-") && file.hasSuffix(".jsonl") {
                jsonlSessions.insert(String(file.dropLast(".jsonl".count)))
            }

            for file in files {
                guard file.hasPrefix("session-") else { continue }
                let isJSON = file.hasSuffix(".json")
                let isJSONL = file.hasSuffix(".jsonl")
                guard isJSON || isJSONL else { continue }

                // JSONL 优先：如果同 session 有 JSONL 版本，跳过 JSON
                if isJSON {
                    let base = String(file.dropLast(".json".count))
                    if jsonlSessions.contains(base) { continue }
                }

                let fullPath = chatsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate >= cutoff else { continue }
                livePaths.insert(fullPath)

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }
                if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                if isJSONL {
                    parseSessionFileJSONL(path: fullPath)
                } else {
                    parseSessionFile(path: fullPath)
                }
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
        evictFiles(notIn: livePaths)
        rebuildRecentEntries()
    }

    private func evictFiles(notIn livePaths: Set<String>) {
        let removed = Set(fileCache.keys).subtracting(livePaths)
        for path in removed {
            if let old = fileDailyContrib[path] { subtractDaily(old) }
            if let old = fileHourlyContrib[path] { subtractHourly(old) }
            if let old = fileCacheContrib[path] { subtractCache(old) }
            fileCache.removeValue(forKey: path)
            fileDailyContrib.removeValue(forKey: path)
            fileHourlyContrib.removeValue(forKey: path)
            fileCacheContrib.removeValue(forKey: path)
            fileRecentContrib.removeValue(forKey: path)
            fileLastModel.removeValue(forKey: path)
            fileSessionId.removeValue(forKey: path)
        }
    }

    private func subtractDaily(_ contrib: [String: DayUsage]) {
        for (k, u) in contrib {
            if var e = dailyData[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { dailyData.removeValue(forKey: k) }
                else { dailyData[k] = e }
            }
        }
    }

    private func subtractHourly(_ contrib: [String: HourlyUsage]) {
        for (k, u) in contrib {
            if var e = hourlyData[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { hourlyData.removeValue(forKey: k) }
                else { hourlyData[k] = e }
            }
        }
    }

    private func subtractCache(_ contrib: [String: Int]) {
        for (k, v) in contrib {
            if var e = dailyCache[k] {
                e -= v
                if e <= 0 { dailyCache.removeValue(forKey: k) }
                else { dailyCache[k] = e }
            }
        }
    }

    // MARK: - JSON 格式解析（旧版）

    private func parseSessionFile(path: String) {
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return }

        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []
        var newLastModels: [String: String] = [:]

        for msg in messages {
            guard let result = parseGeminiEvent(msg) else { continue }
            accumulateResult(result, today: today,
                             daily: &newDaily, hourly: &newHourly, cache: &newCache,
                             recent: &newRecent, lastModels: &newLastModels)
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
        fileLastModel[path] = newLastModels
        fileSessionId[path] = (obj["sessionId"] as? String) ?? (obj["id"] as? String) ?? ""
    }

    // MARK: - JSONL 格式解析（新版）

    private func parseSessionFileJSONL(path: String) {
        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []
        var newLastModels: [String: String] = [:]
        var sessionId = ""

        func process(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if sessionId.isEmpty, let value = obj["sessionId"] as? String { sessionId = value }
            if let result = parseGeminiEvent(obj) {
                accumulateResult(result, today: today,
                                 daily: &newDaily, hourly: &newHourly, cache: &newCache,
                                 recent: &newRecent, lastModels: &newLastModels)
            }
        }

        guard let result = JSONLLineReader.read(
            path: path,
            matchingAny: Self.jsonlLineNeedles,
            onLine: process
        ) else { return }
        _ = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData, onLine: process)

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
        fileLastModel[path] = newLastModels
        fileSessionId[path] = sessionId
    }

    // MARK: - 共享解析与累加

    /// 从 gemini 事件中提取 token 数据
    private struct GeminiEvent {
        let tokens: Int
        let cachedTokens: Int
        let dateKey: String
        let hourKey: String
        let timestamp: Date?
        let model: String?
    }

    private func parseGeminiEvent(_ msg: [String: Any]) -> GeminiEvent? {
        guard msg["type"] as? String == "gemini",
              let tokens = msg["tokens"] as? [String: Any] else { return nil }
        let input = tokens["input"] as? Int ?? 0
        let output = tokens["output"] as? Int ?? 0
        let cached = tokens["cached"] as? Int ?? 0
        // Gemini CLI 的 input(promptTokenCount) 已含 cached(cachedContentTokenCount)，
        // 同 Codex：cached 再加会双计。thought 为推理 token，单列计入（字段名兼容 thought/thoughts）。
        let thought = (tokens["thought"] as? Int) ?? (tokens["thoughts"] as? Int) ?? 0
        let total = TokenAccounting.excludingCacheRead(
            inclusiveInput: input, cacheRead: cached, output: output, additional: [thought]
        )
        guard total > 0 else { return nil }

        let timestamp = msg["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        let hourKey = DateHelper.localHourKey(from: timestamp)
        guard dateKey.count == 10 else { return nil }

        return GeminiEvent(tokens: total, cachedTokens: cached,
                           dateKey: dateKey, hourKey: hourKey,
                           timestamp: DateHelper.parseISO8601(timestamp),
                           model: msg["model"] as? String)
    }

    private func accumulateResult(_ r: GeminiEvent, today: String,
                                  daily: inout [String: DayUsage],
                                  hourly: inout [String: HourlyUsage],
                                  cache: inout [String: Int],
                                  recent: inout [RecentEntry],
                                  lastModels: inout [String: String]) {
        // daily
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        // hourly
        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        // cache
        dailyCache[r.dateKey, default: 0] += r.cachedTokens
        cache[r.dateKey, default: 0] += r.cachedTokens
        // recent
        if r.dateKey == today, let ts = r.timestamp {
            recent.append(RecentEntry(timestamp: ts, tokens: r.tokens))
        }
        if let model = r.model, !model.isEmpty {
            lastModels[r.dateKey] = model
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

    // MARK: - 今日活跃 Session 列表

    /// Gemini CLI session 位于 ~/.gemini/tmp/<project>/chats/session-*.json(l)
    func todaySessions() -> [SessionInfo] {
        let tmpDir = geminiHome + "/tmp"
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: tmpDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for project in projectDirs {
            let chatsDir = tmpDir + "/" + project + "/chats"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            // JSONL 优先
            var jsonlSessions = Set<String>()
            for file in files where file.hasPrefix("session-") && file.hasSuffix(".jsonl") {
                jsonlSessions.insert(String(file.dropLast(".jsonl".count)))
            }

            for file in files {
                guard file.hasPrefix("session-") else { continue }
                let isJSON = file.hasSuffix(".json")
                let isJSONL = file.hasSuffix(".jsonl")
                guard isJSON || isJSONL else { continue }

                if isJSON {
                    let base = String(file.dropLast(".json".count))
                    if jsonlSessions.contains(base) { continue }
                }

                let fullPath = chatsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                guard DateHelper.dateKey(from: modDate) == today else { continue }

                let usage = fileDailyContrib[fullPath]?[today]
                let tokens = usage?.tokens ?? 0
                let messages = usage?.messages ?? 0
                let sessionId = fileSessionId[fullPath] ?? ""
                let model = fileLastModel[fullPath]?[today]
                guard tokens > 0 else { continue }

                let displayId = sessionId.isEmpty ? SessionIdDisplay.format(String(file.dropFirst("session-".count))) : SessionIdDisplay.format(sessionId)
                results.append(SessionInfo(
                    rawId: sessionId,
                    displayName: displayId,
                    detail: project,
                    todayTokens: tokens,
                    todayMessages: messages,
                    isActive: true,
                    model: model
                ))
            }
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

}
