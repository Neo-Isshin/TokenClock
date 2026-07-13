import Foundation

/// 从 Claude Code 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.claude/projects/*/
final class ClaudeCodeUsageService: @unchecked Sendable {
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
    private let claudeHome: String

    init() {
        claudeHome = PathConfig.claudeCodeHome()
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
        recentEntries = []
        scanProjectsDir()
    }

    func incrementalScan() { scanProjectsDir() }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let total = d?.tokens ?? 0
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

    private func scanProjectsDir() {
        let projectsDir = claudeHome + "/projects"
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for project in projects {
            let projectPath = projectsDir + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in contents {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = projectPath + "/" + file
                var fIsDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), !fIsDir.boolValue else { continue }

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                // 撤销旧贡献
                if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }
                if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                parseFile(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
        rebuildRecentEntries()
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

    private func parseFile(path: String) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let today = DateHelper.todayKey()
        let bufSize = AppConfig.Scan.jsonlBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("\"assistant\""), let r = parseLine(line) {
                    accumulate(r, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache, recent: &newRecent)
                }
            }
        }
        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\""), let r = parseLine(line) {
            accumulate(r, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache, recent: &newRecent)
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
    }

    private struct R { let dateKey: String; let hourKey: String; let tokens: Int; let cacheTokens: Int; let ts: Date?; let model: String? }

    private func parseLine(_ line: String) -> R? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let tokens = inputTokens + outputTokens + cacheRead
        guard tokens > 0 else { return nil }
        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        guard dateKey.count == 10 else { return nil }
        return R(dateKey: dateKey, hourKey: DateHelper.localHourKey(from: timestamp),
                 tokens: tokens, cacheTokens: cacheRead + cacheCreation,
                 ts: DateHelper.parseISO8601(timestamp),
                 model: msg["model"] as? String)
    }

    private func accumulate(_ r: R, today: String, daily: inout [String: DayUsage],
                            hourly: inout [String: HourlyUsage], cache: inout [String: Int],
                            recent: inout [RecentEntry]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        // cache tokens
        dailyCache[r.dateKey, default: 0] += r.cacheTokens
        cache[r.dateKey, default: 0] += r.cacheTokens
        // recent
        if r.dateKey == today, let ts = r.ts {
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

    // MARK: - 今日活跃 Session 列表

    /// Claude Code session 存储十分零碎：session 元数据在 ~/.claude/sessions/*.json 中，
    /// 实际对话记录在 ~/.claude/projects/<path>/<sessionId>.jsonl 中。
    /// 需要先读取 sessions 目录获取 sessionId，再在 projects 中定位对应文件。
    func todaySessions() -> [SessionInfo] {
        let sessionsDir = claudeHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let sessionFiles = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        let today = DateHelper.todayKey()
        var seen = Set<String>()
        var results: [SessionInfo] = []

        for file in sessionFiles where file.hasSuffix(".json") {
            let metaPath = sessionsDir + "/" + file
            guard let metaData = fm.contents(atPath: metaPath),
                  let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  let sessionId = meta["sessionId"] as? String else { continue }

            guard seen.insert(sessionId).inserted else { continue }

            let (tokens, messages, model) = findSessionTokens(sessionId: sessionId, today: today)
            guard tokens > 0 || messages > 0 else { continue }

            let displayId = SessionIdDisplay.format(sessionId)
            let cwd = meta["cwd"] as? String ?? ""
            let detail = cwd.isEmpty ? nil : cwd

            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: detail,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true,
                model: model
            ))
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

    /// 在 projects 目录中递归查找指定 sessionId 的 .jsonl 文件，并计算今日 token
    private func findSessionTokens(sessionId: String, today: String) -> (tokens: Int, messages: Int, model: String?) {
        let projectsDir = claudeHome + "/projects"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir, isDirectory: &isDir), isDir.boolValue else { return (0, 0, nil) }

        // session 文件名就是 sessionId + ".jsonl"
        let targetFile = sessionId + ".jsonl"

        // 递归查找
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return (0, 0, nil) }
        for project in projects {
            let projectPath = projectsDir + "/" + project
            var pIsDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &pIsDir), pIsDir.boolValue else { continue }

            // 检查当前目录
            let filePath = projectPath + "/" + targetFile
            var fIsDir: ObjCBool = false
            if fm.fileExists(atPath: filePath, isDirectory: &fIsDir), !fIsDir.boolValue {
                return parseSessionFileToday(path: filePath, today: today)
            }

            // 深度递归（Claude projects 可能有子目录）
            if let found = findSessionFileRecursive(dir: projectPath, targetFile: targetFile, today: today) {
                return found
            }
        }
        return (0, 0, nil)
    }

    private func findSessionFileRecursive(dir: String, targetFile: String, today: String) -> (tokens: Int, messages: Int, model: String?)? {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for item in contents {
            let fullPath = dir + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let found = findSessionFileRecursive(dir: fullPath, targetFile: targetFile, today: today) {
                    return found
                }
            } else if item == targetFile {
                return parseSessionFileToday(path: fullPath, today: today)
            }
        }
        return nil
    }

    /// 解析单个 session 文件的今日数据（复用现有解析逻辑）
    private func parseSessionFileToday(path: String, today: String) -> (tokens: Int, messages: Int, model: String?) {
        guard let stream = InputStream(fileAtPath: path) else { return (0, 0, nil) }
        stream.open()
        defer { stream.close() }

        let bufSize = AppConfig.Scan.jsonlBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var tokens = 0, messages = 0
        // 取该 session 出现过的模型（最后一条 assistant turn 的 message.model）
        var model: String?

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("\"assistant\""), let r = parseLine(line), r.dateKey == today {
                    tokens += r.tokens
                    messages += 1
                    if let m = r.model { model = m }
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\""), let r = parseLine(line), r.dateKey == today {
            tokens += r.tokens
            messages += 1
            if let m = r.model { model = m }
        }

        return (tokens, messages, model)
    }
}
