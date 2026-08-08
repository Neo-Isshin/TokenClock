import Foundation

/// 从 Grok Build CLI 本地 session 文件读取 token 使用数据
/// 数据位置: ~/.grok/sessions/*/*/updates.jsonl
/// 格式: JSONL，含 totalTokens 字段（无 input/output 拆分）
final class GrokUsageService: @unchecked Sendable {
    private static let tokenLineNeedle = [Data("\"totalTokens\"".utf8)]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let grokHome: String

    init(grokHome: String? = nil) {
        self.grokHome = grokHome ?? PathConfig.grokHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        fileCache.removeAll(); fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileRecentContrib.removeAll()
        recentEntries = []
        scanSessionsDir()
    }

    func incrementalScan() { scanSessionsDir() }

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

    private func scanSessionsDir() {
        let sessionsDir = grokHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue,
              let level1 = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            evictFiles(notIn: [])
            rebuildRecentEntries()
            return
        }

        var livePaths = Set<String>()

        for dir1 in level1 {
            let path1 = sessionsDir + "/" + dir1
            var d1: ObjCBool = false
            guard fm.fileExists(atPath: path1, isDirectory: &d1), d1.boolValue else { continue }
            guard let level2 = try? fm.contentsOfDirectory(atPath: path1) else { continue }

            for dir2 in level2 {
                let updatesPath = path1 + "/" + dir2 + "/updates.jsonl"
                var isFile: ObjCBool = false
                guard fm.fileExists(atPath: updatesPath, isDirectory: &isFile), !isFile.boolValue else { continue }
                livePaths.insert(updatesPath)

                guard let attrs = try? fm.attributesOfItem(atPath: updatesPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[updatesPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[updatesPath] { subtractDay(old, from: &dailyData) }
                if let old = fileHourlyContrib[updatesPath] { subtractHour(old, from: &hourlyData) }

                parseJSONL(path: updatesPath)
                fileCache[updatesPath] = FileMeta(path: updatesPath, modDate: modDate)
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

    private func parseJSONL(path: String) {
        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newRecent: [RecentEntry] = []

        func process(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let totalTokens = obj["totalTokens"] as? Int ?? 0
            guard totalTokens > 0 else { return }

            let ts = obj["timestamp"] as? String ?? obj["time"] as? String ?? ""
            let dateKey = ts.isEmpty ? DateHelper.todayKey() : DateHelper.localDateKey(from: ts)
            let hourKey = ts.isEmpty ? DateHelper.currentHourKey() : DateHelper.localHourKey(from: ts)
            guard dateKey.count == 10 else { return }

            if var e = dailyData[dateKey] { e.tokens += totalTokens; e.messages += 1; dailyData[dateKey] = e }
            else { dailyData[dateKey] = DayUsage(tokens: totalTokens, messages: 1) }
            if var e = newDaily[dateKey] { e.tokens += totalTokens; e.messages += 1; newDaily[dateKey] = e }
            else { newDaily[dateKey] = DayUsage(tokens: totalTokens, messages: 1) }

            if var e = hourlyData[hourKey] { e.tokens += totalTokens; e.messages += 1; hourlyData[hourKey] = e }
            else { hourlyData[hourKey] = HourlyUsage(tokens: totalTokens, messages: 1) }
            if var e = newHourly[hourKey] { e.tokens += totalTokens; e.messages += 1; newHourly[hourKey] = e }
            else { newHourly[hourKey] = HourlyUsage(tokens: totalTokens, messages: 1) }

            if dateKey == today {
                let date = ts.isEmpty ? Date() : (DateHelper.parseISO8601(ts) ?? Date())
                newRecent.append(RecentEntry(timestamp: date, tokens: totalTokens))
            }
        }
        guard JSONLLineReader.read(
            path: path,
            matchingAny: Self.tokenLineNeedle,
            onLine: process
        ) != nil else { return }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileRecentContrib[path] = newRecent
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
        let sessionsDir = grokHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []
        guard let level1 = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        for dir1 in level1 {
            let path1 = sessionsDir + "/" + dir1
            var d1: ObjCBool = false
            guard fm.fileExists(atPath: path1, isDirectory: &d1), d1.boolValue else { continue }
            guard let level2 = try? fm.contentsOfDirectory(atPath: path1) else { continue }

            for dir2 in level2 {
                let updatesPath = path1 + "/" + dir2 + "/updates.jsonl"
                var isFile: ObjCBool = false
                guard fm.fileExists(atPath: updatesPath, isDirectory: &isFile), !isFile.boolValue else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: updatesPath),
                      let modDate = attrs[.modificationDate] as? Date,
                      DateHelper.dateKey(from: modDate) == today else { continue }

                let usage = fileDailyContrib[updatesPath]?[today]
                let totalTokens = usage?.tokens ?? 0
                let msgCount = usage?.messages ?? 0
                guard totalTokens > 0 else { continue }

                results.append(SessionInfo(
                    rawId: dir2, displayName: SessionIdDisplay.format(dir2), detail: dir1,
                    todayTokens: totalTokens, todayMessages: msgCount, isActive: true
                ))
            }
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
