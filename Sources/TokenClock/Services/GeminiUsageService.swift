import Foundation

/// 从 Gemini CLI 本地 session JSON 读取 token 使用数据
/// 日志位置: ~/.gemini/tmp/*/chats/session-*.json
final class GeminiUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let geminiHome: String

    init() {
        geminiHome = PathConfig.geminiHome()
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
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
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanSessionsDir() {
        let tmpDir = geminiHome + "/tmp"
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }

        for project in projectDirs {
            let chatsDir = tmpDir + "/" + project + "/chats"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files {
                guard file.hasSuffix(".json") else { continue }
                let fullPath = chatsDir + "/" + file

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }
                if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                parseSessionFile(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
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

    private func parseSessionFile(path: String) {
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return }

        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]

        for msg in messages {
            guard msg["type"] as? String == "gemini",
                  let tokens = msg["tokens"] as? [String: Any] else { continue }
            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            let total = input + output + cached
            guard total > 0 else { continue }

            let timestamp = msg["timestamp"] as? String ?? ""
            let dateKey = DateHelper.localDateKey(from: timestamp)
            let hourKey = DateHelper.localHourKey(from: timestamp)
            guard dateKey.count == 10 else { continue }
            let ts = DateHelper.parseISO8601(timestamp)

            // daily
            if var e = dailyData[dateKey] { e.tokens += total; e.messages += 1; dailyData[dateKey] = e }
            else { dailyData[dateKey] = DayUsage(tokens: total, messages: 1) }
            if var e = newDaily[dateKey] { e.tokens += total; e.messages += 1; newDaily[dateKey] = e }
            else { newDaily[dateKey] = DayUsage(tokens: total, messages: 1) }
            // hourly
            if var e = hourlyData[hourKey] { e.tokens += total; e.messages += 1; hourlyData[hourKey] = e }
            else { hourlyData[hourKey] = HourlyUsage(tokens: total, messages: 1) }
            if var e = newHourly[hourKey] { e.tokens += total; e.messages += 1; newHourly[hourKey] = e }
            else { newHourly[hourKey] = HourlyUsage(tokens: total, messages: 1) }
            // cache
            dailyCache[dateKey, default: 0] += cached
            newCache[dateKey, default: 0] += cached
            // recent
            if dateKey == today, let ts = ts { recentEntries.append(RecentEntry(timestamp: ts, tokens: total)) }
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
    }

    // MARK: - 今日活跃 Session 列表

    /// Gemini CLI session 位于 ~/.gemini/tmp/<project>/chats/session-*.json
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

            for file in files where file.hasSuffix(".json") {
                let fullPath = chatsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                // 只处理今日修改的文件
                guard DateHelper.dateKey(from: modDate) == today else { continue }

                let (tokens, messages, sessionId) = parseSessionFile(path: fullPath, today: today)
                guard tokens > 0 else { continue }

                let displayId = String(sessionId.prefix(7))
                results.append(SessionInfo(
                    rawId: sessionId,
                    displayName: displayId,
                    detail: project,
                    todayTokens: tokens,
                    todayMessages: messages,
                    isActive: true
                ))
            }
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

    private func parseSessionFile(path: String, today: String) -> (tokens: Int, messages: Int, sessionId: String) {
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0, "") }

        let sessionId = (obj["sessionId"] as? String) ?? (obj["id"] as? String) ?? ""
        guard let messages = obj["messages"] as? [[String: Any]] else { return (0, 0, sessionId) }

        var totalTokens = 0
        var msgCount = 0

        for msg in messages {
            guard msg["type"] as? String == "gemini",
                  let tokens = msg["tokens"] as? [String: Any] else { continue }
            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            let total = input + output + cached
            guard total > 0 else { continue }

            let timestamp = msg["timestamp"] as? String ?? ""
            let dateKey = DateHelper.localDateKey(from: timestamp)
            guard dateKey == today else { continue }

            totalTokens += total
            msgCount += 1
        }

        return (totalTokens, msgCount, sessionId)
    }
}
