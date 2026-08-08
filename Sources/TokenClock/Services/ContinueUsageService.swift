import Foundation

/// 从 Continue.dev 本地 JSONL 文件读取 token 使用数据
/// 数据位置: ~/.continue/
///   - dev_data/*.jsonl            开发数据（含 token 信息）
///   - sessions/*.jsonl            会话数据
/// Continue 的 JSONL 每行含 completion 的 prompt/completion 统计
final class ContinueUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var recentEntries: [RecentEntry] = []
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]

    private let fm = FileManager.default
    private let continueHome: String

    init(continueHome: String? = nil) {
        self.continueHome = continueHome ?? PathConfig.continueHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        fileCache.removeAll(); fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll(); fileRecentContrib.removeAll()
        recentEntries = []
        scanAllDirs()
    }

    func incrementalScan() { scanAllDirs() }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        return (d?.tokens ?? 0, d?.messages ?? 0, 0)
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

    private func scanAllDirs() {
        // dev_data 和 sessions 两个目录都扫
        var livePaths = Set<String>()
        for sub in ["dev_data", "sessions"] {
            let dir = continueHome + "/" + sub
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                livePaths.insert(path)
                processJSONL(path)
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
            fileCache.removeValue(forKey: path)
            fileDailyContrib.removeValue(forKey: path)
            fileHourlyContrib.removeValue(forKey: path)
            fileRecentContrib.removeValue(forKey: path)
        }
    }

    private func processJSONL(_ path: String) {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        let cached = fileCache[path]
        if cached != nil && cached?.modDate == modDate { return }

        if let old = fileDailyContrib[path] { subtractDay(old, from: &dailyData) }
        if let old = fileHourlyContrib[path] { subtractHour(old, from: &hourlyData) }

        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newRecent: [RecentEntry] = []

        func process(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = parseEvent(obj) else { return }
            accumulate(result, today: today, daily: &newDaily, hourly: &newHourly, recent: &newRecent)
        }
        guard JSONLLineReader.read(path: path, onLine: process) != nil else { return }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileRecentContrib[path] = newRecent
        fileCache[path] = FileMeta(path: path, modDate: modDate)
    }

    private struct EventResult {
        let tokens: Int
        let dateKey: String
        let hourKey: String
        let timestamp: Date?
    }

    /// Continue.dev JSONL 字段多样，尝试多种可能
    private func parseEvent(_ obj: [String: Any]) -> EventResult? {
        // 模式1: { prompt_tokens, completion_tokens, timestamp }
        // 模式2: { tokens: { input, output }, timestamp }
        // 模式3: { usage: { prompt_tokens, completion_tokens }, timestamp }
        var input = 0, output = 0

        if let tokens = obj["tokens"] as? [String: Any] {
            input = (tokens["input"] as? Int) ?? (tokens["prompt"] as? Int) ?? 0
            output = (tokens["output"] as? Int) ?? (tokens["completion"] as? Int) ?? 0
        } else if let usage = obj["usage"] as? [String: Any] {
            input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
            output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        } else {
            input = (obj["prompt_tokens"] as? Int) ?? (obj["input_tokens"] as? Int) ?? 0
            output = (obj["completion_tokens"] as? Int) ?? (obj["output_tokens"] as? Int) ?? 0
        }

        let total = input + output
        guard total > 0 else { return nil }

        // 时间戳
        let ts = (obj["timestamp"] as? String) ?? ""
        let dateKey: String, hourKey: String, date: Date?
        if ts.isEmpty {
            // 尝试 unix timestamp
            if let unix = (obj["timestamp"] as? Double) ?? (obj["createdAt"] as? Double) {
                let d = Date(timeIntervalSince1970: unix / 1000.0)
                dateKey = DateHelper.dateKey(from: d)
                hourKey = DateHelper.hourKey(from: d)
                date = d
            } else {
                dateKey = DateHelper.todayKey()
                hourKey = DateHelper.currentHourKey()
                date = Date()
            }
        } else {
            dateKey = DateHelper.localDateKey(from: ts)
            hourKey = DateHelper.localHourKey(from: ts)
            date = DateHelper.parseISO8601(ts)
            guard dateKey.count == 10 else { return nil }
        }
        return EventResult(tokens: total, dateKey: dateKey, hourKey: hourKey, timestamp: date)
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

    private func accumulate(_ r: EventResult, today: String,
                            daily: inout [String: DayUsage],
                            hourly: inout [String: HourlyUsage],
                            recent: inout [RecentEntry]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }

        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }

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
        let sessionsDir = continueHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = sessionsDir + "/" + file
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  DateHelper.dateKey(from: modDate) == today else { continue }

            let usage = fileDailyContrib[fullPath]?[today]
            let totalTokens = usage?.tokens ?? 0
            let msgCount = usage?.messages ?? 0
            guard totalTokens > 0 else { continue }
            results.append(SessionInfo(
                rawId: file, displayName: SessionIdDisplay.format(String(file.dropLast(".jsonl".count))), detail: nil,
                todayTokens: totalTokens, todayMessages: msgCount, isActive: true
            ))
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
