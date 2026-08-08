import Foundation

/// 从 Qwen Code 本地 session JSONL 文件读取 token 使用数据
/// Qwen Code 是 Gemini CLI 的 fork，session 格式与 Gemini CLI 相同
/// 数据位置: ~/.qwen/projects/{PROJECT_PATH}/chats/{CHAT_ID}.jsonl
final class QwenCodeUsageService: @unchecked Sendable {
    private static let usageLineNeedles = [
        Data("\"gemini\"".utf8),
        Data("\"usageMetadata\"".utf8),
    ]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let qwenHome: String

    init(qwenHome: String? = nil) {
        self.qwenHome = qwenHome ?? PathConfig.qwenHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll(); dailyCache.removeAll()
        fileCache.removeAll(); fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll(); fileCacheContrib.removeAll()
        fileRecentContrib.removeAll()
        recentEntries = []
        scanSessionsDir()
    }

    func incrementalScan() { scanSessionsDir() }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let total = d?.tokens ?? 0
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let rate = total > 0 ? Double(cache) / Double(total) : 0
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
        let projectsDir = qwenHome + "/projects"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir, isDirectory: &isDir), isDir.boolValue,
              let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            evictFiles(notIn: [])
            rebuildRecentEntries()
            return
        }

        var livePaths = Set<String>()

        for project in projectDirs {
            let chatsDir = projectsDir + "/" + project + "/chats"
            var cIsDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &cIsDir), cIsDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = chatsDir + "/" + file
                livePaths.insert(fullPath)
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[fullPath] { subtractDay(old, from: &dailyData) }
                if let old = fileHourlyContrib[fullPath] { subtractHour(old, from: &hourlyData) }
                if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                parseJSONL(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
        evictFiles(notIn: livePaths)
        rebuildRecentEntries()
    }

    private func evictFiles(notIn livePaths: Set<String>) {
        let removed = Set(fileCache.keys).subtracting(livePaths)
        for path in removed {
            if let old = fileDailyContrib[path] { subtractDay(old, from: &dailyData) }
            if let old = fileHourlyContrib[path] { subtractHour(old, from: &hourlyData) }
            if let old = fileCacheContrib[path] { subtractCache(old) }
            fileCache.removeValue(forKey: path)
            fileDailyContrib.removeValue(forKey: path)
            fileHourlyContrib.removeValue(forKey: path)
            fileCacheContrib.removeValue(forKey: path)
            fileRecentContrib.removeValue(forKey: path)
        }
    }

    private func subtractDay(_ contrib: [String: DayUsage], from data: inout [String: DayUsage]) {
        for (k, u) in contrib {
            if var e = data[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { data.removeValue(forKey: k) }
                else { data[k] = e }
            }
        }
    }

    private func subtractHour(_ contrib: [String: HourlyUsage], from data: inout [String: HourlyUsage]) {
        for (k, u) in contrib {
            if var e = data[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { data.removeValue(forKey: k) }
                else { data[k] = e }
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

    private func parseJSONL(path: String) {
        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []

        func process(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = parseEvent(obj) else { return }
            accumulate(result, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache, recent: &newRecent)
        }
        guard let result = JSONLLineReader.read(
            path: path,
            matchingAny: Self.usageLineNeedles,
            onLine: process
        ) else { return }
        _ = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData, onLine: process)

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
    }

    private struct Event {
        let tokens: Int
        let cachedTokens: Int
        let dateKey: String
        let hourKey: String
        let timestamp: Date?
    }

    private func parseEvent(_ msg: [String: Any]) -> Event? {
        // Gemini CLI fork 格式: { "type": "gemini", "tokens": { "input": N, "output": N, "cached": N }, "timestamp": "..." }
        if msg["type"] as? String == "gemini",
           let tokens = msg["tokens"] as? [String: Any] {
            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            // input(promptTokenCount) 已含 cached → cached 不可再加（双计）。thought 为推理 token。
            let thought = (tokens["thought"] as? Int) ?? (tokens["thoughts"] as? Int) ?? 0
            let total = input + output + thought
            guard total > 0 else { return nil }

            let ts = msg["timestamp"] as? String ?? ""
            let dateKey = DateHelper.localDateKey(from: ts)
            let hourKey = DateHelper.localHourKey(from: ts)
            guard dateKey.count == 10 else { return nil }

            return Event(tokens: total, cachedTokens: cached, dateKey: dateKey, hourKey: hourKey,
                         timestamp: DateHelper.parseISO8601(ts))
        }

        // Gemini API usageMetadata 格式: { "usageMetadata": { "promptTokenCount": N, "candidatesTokenCount": N, "cachedContentTokenCount": N }, "timestamp": "..." }
        if let usage = msg["usageMetadata"] as? [String: Any] {
            let prompt = usage["promptTokenCount"] as? Int ?? 0
            let candidates = usage["candidatesTokenCount"] as? Int ?? 0
            let thoughts = usage["thoughtsTokenCount"] as? Int ?? 0
            let cached = usage["cachedContentTokenCount"] as? Int ?? 0
            // promptTokenCount 已含 cachedContentTokenCount → cached 不可再加（双计）。
            let total = prompt + candidates + thoughts
            guard total > 0 else { return nil }

            let ts = msg["timestamp"] as? String ?? ""
            let dateKey = ts.isEmpty ? DateHelper.todayKey() : DateHelper.localDateKey(from: ts)
            let hourKey = ts.isEmpty ? DateHelper.currentHourKey() : DateHelper.localHourKey(from: ts)
            guard dateKey.count == 10 else { return nil }

            return Event(tokens: total, cachedTokens: cached, dateKey: dateKey, hourKey: hourKey,
                         timestamp: ts.isEmpty ? Date() : DateHelper.parseISO8601(ts))
        }

        return nil
    }

    private func accumulate(_ r: Event, today: String,
                            daily: inout [String: DayUsage],
                            hourly: inout [String: HourlyUsage],
                            cache: inout [String: Int],
                            recent: inout [RecentEntry]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }

        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }

        dailyCache[r.dateKey, default: 0] += r.cachedTokens
        cache[r.dateKey, default: 0] += r.cachedTokens

        if r.dateKey == today, let ts = r.timestamp {
            recent.append(RecentEntry(timestamp: ts, tokens: r.tokens))
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

    func todaySessions() -> [SessionInfo] {
        let projectsDir = qwenHome + "/projects"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for project in projectDirs {
            let chatsDir = projectsDir + "/" + project + "/chats"
            var cIsDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &cIsDir), cIsDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = chatsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                guard DateHelper.dateKey(from: modDate) == today else { continue }

                let usage = fileDailyContrib[fullPath]?[today]
                let tokens = usage?.tokens ?? 0
                let messages = usage?.messages ?? 0
                guard tokens > 0 else { continue }

                let displayId = SessionIdDisplay.format(String(file.dropLast(".jsonl".count)))
                let dirName = (project as NSString).lastPathComponent
                results.append(SessionInfo(
                    rawId: file, displayName: displayId, detail: dirName,
                    todayTokens: tokens, todayMessages: messages, isActive: true
                ))
            }
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

}
