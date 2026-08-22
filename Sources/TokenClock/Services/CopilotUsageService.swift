import Foundation

/// 从 GitHub Copilot CLI 本地 session 文件读取 token 使用数据
/// 支持两种数据源：
/// - OTel JSONL: ~/.copilot/otel/*.jsonl（需设置环境变量，完整 token 细分）
/// - Session events: ~/.copilot/session-state/{id}/events.jsonl（始终写入，但 token 字段有限）
final class CopilotUsageService: @unchecked Sendable {
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
    private let copilotHome: String

    init(copilotHome: String? = nil) {
        self.copilotHome = copilotHome ?? PathConfig.copilotHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll(); dailyCache.removeAll()
        fileCache.removeAll(); fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll(); fileCacheContrib.removeAll()
        fileRecentContrib.removeAll()
        recentEntries = []
        scanAllFiles()
    }

    func incrementalScan() {
        scanAllFiles()
    }

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

    private func scanAllFiles() {
        var livePaths = Set<String>()
        var isDir: ObjCBool = false
#if os(Linux)
        if let directFile = PathConfig.copilotOtelFile(),
           fm.fileExists(atPath: directFile, isDirectory: &isDir), !isDir.boolValue {
            livePaths.insert(directFile)
            processJSONLFile(directFile, parser: parseOtelEvent)
        }
#endif
        let otelDir = copilotHome + "/otel"
        if fm.fileExists(atPath: otelDir, isDirectory: &isDir), isDir.boolValue,
           let files = try? fm.contentsOfDirectory(atPath: otelDir) {
            for file in files where file.hasSuffix(".jsonl") {
                let path = otelDir + "/" + file
                livePaths.insert(path)
                processJSONLFile(path, parser: parseOtelEvent)
            }
        }

        let stateDir = copilotHome + "/session-state"
        if fm.fileExists(atPath: stateDir, isDirectory: &isDir), isDir.boolValue,
           let sessionDirs = try? fm.contentsOfDirectory(atPath: stateDir) {
            for session in sessionDirs {
                let path = stateDir + "/" + session + "/events.jsonl"
                var isFile: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isFile), !isFile.boolValue else { continue }
                livePaths.insert(path)
                processJSONLFile(path, parser: parseSessionEvent)
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

    // MARK: - 通用 JSONL 文件处理

    private func processJSONLFile(_ path: String, parser: ([String: Any]) -> EventResult?) {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        let cached = fileCache[path]
        if cached != nil && cached?.modDate == modDate { return }

        if let old = fileDailyContrib[path] { subtractDay(old, from: &dailyData) }
        if let old = fileHourlyContrib[path] { subtractHour(old, from: &hourlyData) }
        if let old = fileCacheContrib[path] { subtractCache(old) }

        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []

        let today = DateHelper.todayKey()

        func process(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = parser(obj) else { return }
            accumulate(result, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache, recent: &newRecent)
        }
        guard JSONLLineReader.read(path: path, onLine: process) != nil else { return }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
        fileCache[path] = FileMeta(path: path, modDate: modDate)
    }

    // MARK: - 事件解析

    private struct EventResult {
        let tokens: Int
        let cachedTokens: Int
        let dateKey: String
        let hourKey: String
        let timestamp: Date?
    }

    /// OTel 格式: attributes 中有 gen_ai.usage.* 字段
    private func parseOtelEvent(_ obj: [String: Any]) -> EventResult? {
        guard let attrs = obj["attributes"] as? [String: Any] else { return nil }
        let input = attrs["gen_ai.usage.input_tokens"] as? Int ?? 0
        let output = attrs["gen_ai.usage.output_tokens"] as? Int ?? 0
        let cacheRead = attrs["gen_ai.usage.cache_read.input_tokens"] as? Int ?? 0
        _ = attrs["gen_ai.usage.cache_creation.input_tokens"] as? Int ?? 0
        let total = TokenAccounting.excludingCacheRead(
            inclusiveInput: input, cacheRead: cacheRead, output: output
        )
        guard total > 0 else { return nil }

        let ts = obj["startTime"] as? String ?? obj["timestamp"] as? String ?? ""
        let dateKey = ts.isEmpty ? DateHelper.todayKey() : DateHelper.localDateKey(from: ts)
        let hourKey = ts.isEmpty ? DateHelper.currentHourKey() : DateHelper.localHourKey(from: ts)
        guard dateKey.count == 10 else { return nil }

        return EventResult(tokens: total, cachedTokens: cacheRead, dateKey: dateKey, hourKey: hourKey,
                           timestamp: ts.isEmpty ? Date() : DateHelper.parseISO8601(ts))
    }

    /// Session events 格式: { "type": "assistant.usage", "usage": { "inputTokens": N, "outputTokens": N } }
    private func parseSessionEvent(_ obj: [String: Any]) -> EventResult? {
        guard obj["type"] as? String == "assistant.usage",
              let usage = obj["usage"] as? [String: Any] else { return nil }
        let input = usage["inputTokens"] as? Int ?? 0
        let output = usage["outputTokens"] as? Int ?? 0
        let cacheRead = usage["cacheReadTokens"] as? Int ?? 0
        _ = usage["cacheWriteTokens"] as? Int ?? 0
        let total = TokenAccounting.excludingCacheRead(
            inclusiveInput: input, cacheRead: cacheRead, output: output
        )
        guard total > 0 else { return nil }

        let ts = obj["timestamp"] as? String ?? ""
        let dateKey = ts.isEmpty ? DateHelper.todayKey() : DateHelper.localDateKey(from: ts)
        let hourKey = ts.isEmpty ? DateHelper.currentHourKey() : DateHelper.localHourKey(from: ts)
        guard dateKey.count == 10 else { return nil }

        return EventResult(tokens: total, cachedTokens: cacheRead, dateKey: dateKey, hourKey: hourKey,
                           timestamp: ts.isEmpty ? Date() : DateHelper.parseISO8601(ts))
    }

    // MARK: - 累加与减去

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

    private func accumulate(_ r: EventResult, today: String,
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
        let stateDir = copilotHome + "/session-state"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: stateDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: stateDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for session in sessionDirs {
            let eventsPath = stateDir + "/" + session + "/events.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: eventsPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  DateHelper.dateKey(from: modDate) == today else { continue }

            let usage = fileDailyContrib[eventsPath]?[today]
            let totalTokens = usage?.tokens ?? 0
            let msgCount = usage?.messages ?? 0

            guard totalTokens > 0 else { continue }
            results.append(SessionInfo(
                rawId: session, displayName: SessionIdDisplay.format(session), detail: nil,
                todayTokens: totalTokens, todayMessages: msgCount, isActive: true
            ))
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
