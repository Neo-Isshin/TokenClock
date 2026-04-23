import Foundation

/// 从 Claude Code 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.claude/projects/*/
final class ClaudeCodeUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let claudeHome: String

    init() {
        claudeHome = NSHomeDirectory() + "/.claude"
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        recentEntries = []
        scanProjectsDir()
    }

    func incrementalScan() { scanProjectsDir() }

    func todayUsage() -> (tokens: Int, messages: Int) {
        let d = dailyData[DateHelper.todayKey()]
        return (d?.tokens ?? 0, d?.messages ?? 0)
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

                if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }

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
                    accumulate(r, today: today, daily: &newDaily, hourly: &newHourly)
                }
            }
        }
        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\""), let r = parseLine(line) {
            accumulate(r, today: today, daily: &newDaily, hourly: &newHourly)
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
    }

    private struct R { let dateKey: String; let hourKey: String; let tokens: Int; let ts: Date? }

    private func parseLine(_ line: String) -> R? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let msg = obj["message"] as? [String: Any],
              msg["role"] as? String == "assistant",
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let tokens = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
        guard tokens > 0 else { return nil }
        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        guard dateKey.count == 10 else { return nil }
        return R(dateKey: dateKey, hourKey: DateHelper.localHourKey(from: timestamp),
                 tokens: tokens, ts: DateHelper.parseISO8601(timestamp))
    }

    private func accumulate(_ r: R, today: String, daily: inout [String: DayUsage], hourly: inout [String: HourlyUsage]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if r.dateKey == today, let ts = r.ts { recentEntries.append(RecentEntry(timestamp: ts, tokens: r.tokens)) }
    }
}
