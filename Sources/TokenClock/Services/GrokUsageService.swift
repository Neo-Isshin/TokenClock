import Foundation

/// 从 Grok Build CLI 本地 session 文件读取 token 使用数据
/// 数据位置: ~/.grok/sessions/*/*/updates.jsonl
/// 格式: JSONL，含 totalTokens 字段（无 input/output 拆分）
final class GrokUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let grokHome: String

    init() {
        grokHome = PathConfig.grokHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        fileCache.removeAll(); fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
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
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanSessionsDir() {
        let sessionsDir = grokHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return }
        guard let level1 = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }

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
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[updatesPath]
                if cached != nil && cached?.modDate == modDate { continue }

                if let old = fileDailyContrib[updatesPath] { subtractDay(old, from: &dailyData) }
                if let old = fileHourlyContrib[updatesPath] { subtractHour(old, from: &hourlyData) }

                parseJSONL(path: updatesPath)
                fileCache[updatesPath] = FileMeta(path: updatesPath, modDate: modDate)
            }
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
                guard let line = String(data: lineData, encoding: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) as? [String: Any] else { continue }

                let totalTokens = obj["totalTokens"] as? Int ?? 0
                guard totalTokens > 0 else { continue }

                let ts = obj["timestamp"] as? String ?? obj["time"] as? String ?? ""
                let dateKey = ts.isEmpty ? DateHelper.todayKey() : DateHelper.localDateKey(from: ts)
                let hourKey = ts.isEmpty ? DateHelper.currentHourKey() : DateHelper.localHourKey(from: ts)
                guard dateKey.count == 10 else { continue }

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
                    recentEntries.append(RecentEntry(timestamp: date, tokens: totalTokens))
                }
            }
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
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

                var totalTokens = 0, msgCount = 0
                guard let data = fm.contents(atPath: updatesPath),
                      let content = String(data: data, encoding: .utf8) else { continue }
                for line in content.components(separatedBy: .newlines) {
                    guard !line.isEmpty,
                          let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) as? [String: Any] else { continue }
                    let ts = obj["timestamp"] as? String ?? obj["time"] as? String ?? ""
                    let dateKey = ts.isEmpty ? today : DateHelper.localDateKey(from: ts)
                    guard dateKey == today else { continue }
                    let tokens = obj["totalTokens"] as? Int ?? 0
                    guard tokens > 0 else { continue }
                    totalTokens += tokens; msgCount += 1
                }
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
