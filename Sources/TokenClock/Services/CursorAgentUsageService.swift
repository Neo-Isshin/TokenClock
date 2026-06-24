import Foundation

/// 从 cursor-agent CLI 的 hook 脚本写入的 JSONL 文件读取 token 使用数据
/// 数据来源：~/.cursor/hooks/log-token-usage.sh 由 afterAgentResponse hook 触发
/// 文件位置：~/.cursor/token-usage.jsonl
/// 每行格式：{"timestamp": 1234.5, "session_id": "...", "input_tokens": N, "output_tokens": N, ...}
///
/// 注意：cursor-agent 必须在 cli-config.json 中配置 hooks，否则不会有数据
final class CursorAgentUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var lastScanTime: Date = .distantPast
    private var seenRecords: Set<String> = []

    private let fm = FileManager.default
    private let cursorHome: String

    init() {
        cursorHome = PathConfig.cursorAgentHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        dailyCache.removeAll(); recentEntries = []
        seenRecords = []
        lastScanTime = .distantPast
        scanLogFile()
    }

    func incrementalScan() { scanLogFile() }

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
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private var logPath: String {
        cursorHome + "/token-usage.jsonl"
    }

    private func scanLogFile() {
        let path = logPath
        var isFile: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isFile), !isFile.boolValue else { return }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              modDate > lastScanTime else { return }

        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        let today = DateHelper.todayKey()

        // 每次重读时，只清理当天数据并重新累加（避免重复）
        // 但保留 seenRecords 用于去重（跨扫描）
        if dailyData[today] != nil {
            dailyData[today] = nil
            hourlyData = hourlyData.filter { !$0.key.hasPrefix(today) }
            dailyCache[today] = nil
            recentEntries = recentEntries.filter { DateHelper.dateKey(from: $0.timestamp) == today }
        }

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                processLine(lineData, today: today)
            }
        }
        // 末尾无换行
        if !lineBuf.isEmpty {
            processLine(lineBuf, today: today)
        }

        lastScanTime = Date()
    }

    private func processLine(_ data: Data, today: String) {
        guard let line = String(data: data, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) as? [String: Any] else { return }

        // 用 timestamp + session_id 去重
        let ts = (obj["timestamp"] as? Double) ?? 0
        let sessionId = (obj["session_id"] as? String) ?? ""
        let dedupKey = "\(ts)_\(sessionId)"
        if seenRecords.contains(dedupKey) { return }
        seenRecords.insert(dedupKey)

        let inputTokens = (obj["input_tokens"] as? Int) ?? 0
        let outputTokens = (obj["output_tokens"] as? Int) ?? 0
        let cacheRead = (obj["cache_read_tokens"] as? Int) ?? 0
        let cacheWrite = (obj["cache_write_tokens"] as? Int) ?? 0
        let total = inputTokens + outputTokens + cacheRead + cacheWrite
        guard total > 0 else { return }

        let date = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
        let dateKey = DateHelper.dateKey(from: date)
        let hourKey = DateHelper.hourKey(from: date)

        if var e = dailyData[dateKey] {
            e.tokens += total; e.messages += 1; dailyData[dateKey] = e
        } else {
            dailyData[dateKey] = DayUsage(tokens: total, messages: 1)
        }

        if var e = hourlyData[hourKey] {
            e.tokens += total; e.messages += 1; hourlyData[hourKey] = e
        } else {
            hourlyData[hourKey] = HourlyUsage(tokens: total, messages: 1)
        }

        dailyCache[dateKey, default: 0] += cacheRead + cacheWrite

        if dateKey == today {
            recentEntries.append(RecentEntry(timestamp: date, tokens: total))
        }
    }

    func todaySessions() -> [SessionInfo] {
        let path = logPath
        var isFile: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isFile), !isFile.boolValue else { return [] }

        guard let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let today = DateHelper.todayKey()
        var sessionMap: [String: (tokens: Int, messages: Int)] = [:]
        var sessionOrder: [String] = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? Double) ?? 0
            let date = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
            guard DateHelper.dateKey(from: date) == today else { continue }

            let sessionId = (obj["session_id"] as? String) ?? "unknown"
            let inputTokens = (obj["input_tokens"] as? Int) ?? 0
            let outputTokens = (obj["output_tokens"] as? Int) ?? 0
            let cacheRead = (obj["cache_read_tokens"] as? Int) ?? 0
            let cacheWrite = (obj["cache_write_tokens"] as? Int) ?? 0
            let total = inputTokens + outputTokens + cacheRead + cacheWrite
            guard total > 0 else { continue }

            if var s = sessionMap[sessionId] {
                s.tokens += total; s.messages += 1
                sessionMap[sessionId] = s
            } else {
                sessionMap[sessionId] = (total, 1)
                sessionOrder.append(sessionId)
            }
        }

        return sessionOrder.compactMap { sid in
            guard let s = sessionMap[sid] else { return nil }
            return SessionInfo(
                rawId: sid, displayName: SessionIdDisplay.format(sid), detail: nil,
                todayTokens: s.tokens, todayMessages: s.messages, isActive: true
            )
        }.sorted { $0.todayTokens > $1.todayTokens }
    }
}
