import Foundation

/// 从 Codex CLI 本地 rollout JSONL 读取 token 使用数据
/// 日志位置: ~/.codex/sessions/rollout-*.jsonl
final class CodexUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let codexHome: String

    init() {
        codexHome = PathConfig.codexHome()
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
        let sessionsDir = codexHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return }

        // 新版 Codex 按 YYYY/MM/DD 分层存储，递归扫描所有子目录
        scanDirectoryRecursive(sessionsDir)
    }

    /// 递归扫描目录中的 rollout-*.jsonl 文件
    private func scanDirectoryRecursive(_ dirPath: String) {
        guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

        for item in contents {
            let fullPath = dirPath + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // 递归子目录
                scanDirectoryRecursive(fullPath)
            } else if item.hasPrefix("rollout-") && item.hasSuffix(".jsonl") {
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }
                if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                parseFile(path: fullPath)
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

    private func parseFile(path: String) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let today = DateHelper.todayKey()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("turn.completed"), let r = parseLine(line) {
                    accumulate(r, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache)
                }
            }
        }
        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("turn.completed"), let r = parseLine(line) {
            accumulate(r, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache)
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
    }

    private struct R { let dateKey: String; let hourKey: String; let tokens: Int; let cacheTokens: Int; let ts: Date? }

    private func parseLine(_ line: String) -> R? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Codex rollout 事件: type == "turn.completed", usage 在顶层
        guard obj["type"] as? String == "turn.completed",
              let usage = obj["usage"] as? [String: Any] else { return nil }
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cachedTokens = usage["cached_input_tokens"] as? Int ?? 0
        let tokens = inputTokens + outputTokens + cachedTokens
        guard tokens > 0 else { return nil }
        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        guard dateKey.count == 10 else { return nil }
        return R(dateKey: dateKey, hourKey: DateHelper.localHourKey(from: timestamp),
                 tokens: tokens, cacheTokens: cachedTokens, ts: DateHelper.parseISO8601(timestamp))
    }

    private func accumulate(_ r: R, today: String, daily: inout [String: DayUsage],
                            hourly: inout [String: HourlyUsage], cache: inout [String: Int]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        dailyCache[r.dateKey, default: 0] += r.cacheTokens
        cache[r.dateKey, default: 0] += r.cacheTokens
        if r.dateKey == today, let ts = r.ts { recentEntries.append(RecentEntry(timestamp: ts, tokens: r.tokens)) }
    }

    // MARK: - 今日活跃 Session 列表

    /// Codex session 位于 ~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl
    func todaySessions() -> [SessionInfo] {
        let sessionsDir = codexHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return [] }

        let today = DateHelper.todayKey()
        let todayDir = sessionsDir + "/" + today.replacingOccurrences(of: "-", with: "/")
        var results: [SessionInfo] = []

        // 如果今日目录存在，直接扫描
        var tIsDir: ObjCBool = false
        if fm.fileExists(atPath: todayDir, isDirectory: &tIsDir), tIsDir.boolValue {
            results = scanSessionsDir(todayDir, today: today)
        } else {
            // 回退：递归扫描所有子目录找今日文件
            results = scanAllSessionsForToday(dir: sessionsDir, today: today)
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

    private func scanSessionsDir(_ dir: String, today: String) -> [SessionInfo] {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var results: [SessionInfo] = []

        for item in contents where item.hasPrefix("rollout-") && item.hasSuffix(".jsonl") {
            let fullPath = dir + "/" + item
            var fIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), !fIsDir.boolValue else { continue }

            // 从文件名提取 session ID：rollout-<timestamp>-<id>.jsonl
            let id = extractSessionId(from: item)
            let displayId = String(id.prefix(7))
            let (tokens, messages) = parseSessionFileToday(path: fullPath, today: today)
            guard tokens > 0 else { continue }

            results.append(SessionInfo(
                rawId: id,
                displayName: displayId,
                detail: nil,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true
            ))
        }
        return results
    }

    private func scanAllSessionsForToday(dir: String, today: String) -> [SessionInfo] {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var results: [SessionInfo] = []

        for item in contents {
            let fullPath = dir + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let sub = scanAllSessionsForToday(dir: fullPath, today: today)
                results.append(contentsOf: sub)
            } else if item.hasPrefix("rollout-") && item.hasSuffix(".jsonl") {
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date,
                      DateHelper.dateKey(from: modDate) == today else { continue }

                let id = extractSessionId(from: item)
                let displayId = String(id.prefix(7))
                let (tokens, messages) = parseSessionFileToday(path: fullPath, today: today)
                guard tokens > 0 else { continue }

                results.append(SessionInfo(
                    rawId: id,
                    displayName: displayId,
                    detail: nil,
                    todayTokens: tokens,
                    todayMessages: messages,
                    isActive: true
                ))
            }
        }
        return results
    }

    /// 从 rollout 文件名提取 session ID
    private func extractSessionId(from filename: String) -> String {
        // rollout-YYYY-MM-DDTHH-MM-SS-<id>.jsonl
        let base = filename.dropFirst("rollout-".count).dropLast(".jsonl".count)
        // 去掉时间戳部分（前 19 字符 "YYYY-MM-DDTHH-MM-SS"）
        let idPart = base.dropFirst(20)
        return String(idPart)
    }

    /// 解析单个 rollout 文件的今日数据
    private func parseSessionFileToday(path: String, today: String) -> (tokens: Int, messages: Int) {
        guard let stream = InputStream(fileAtPath: path) else { return (0, 0) }
        stream.open()
        defer { stream.close() }

        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var tokens = 0, messages = 0

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("turn.completed"), let r = parseLine(line), r.dateKey == today {
                    tokens += r.tokens
                    messages += 1
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("turn.completed"), let r = parseLine(line), r.dateKey == today {
            tokens += r.tokens
            messages += 1
        }

        return (tokens, messages)
    }
}
