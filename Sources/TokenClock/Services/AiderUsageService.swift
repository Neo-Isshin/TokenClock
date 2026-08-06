import Foundation

/// 从 Aider analytics JSONL 文件读取 token 使用数据
/// 需要用户启动时加 --analytics-log 参数（如 --analytics-log ~/.aider/analytics.jsonl）
/// 数据位置: 用户指定路径，默认检测 ~/.aider/analytics.jsonl
/// 格式: JSONL，每行含 event 和 properties.prompt_tokens / properties.completion_tokens / properties.cost
final class AiderUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var recentEntries: [RecentEntry] = []
    private var lastScanTime: Date = .distantPast

    private let fm = FileManager.default
    private let analyticsPath: String

    init() {
        analyticsPath = PathConfig.aiderAnalyticsPath()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        recentEntries = []; lastScanTime = .distantPast
        scanAnalyticsFile()
    }

    func incrementalScan() { scanAnalyticsFile() }

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

    private func scanAnalyticsFile() {
        let path = analyticsPath
        var isFile: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isFile), !isFile.boolValue else { return }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              modDate > lastScanTime else { return }

        // 文件有修改，重读
        dailyData.removeAll(); hourlyData.removeAll(); recentEntries = []

        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let today = DateHelper.todayKey()
        let bufSize = AppConfig.Scan.jsonlBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()

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

                // 只处理 message_send 事件
                guard obj["event"] as? String == "message_send" else { continue }
                guard let props = obj["properties"] as? [String: Any] else { continue }

                let promptTokens = props["prompt_tokens"] as? Int ?? 0
                let completionTokens = props["completion_tokens"] as? Int ?? 0
                let total = promptTokens + completionTokens
                guard total > 0 else { continue }

                // Aider 用 Unix timestamp（秒）
                let time = obj["time"] as? Double ?? 0
                let date = time > 0 ? Date(timeIntervalSince1970: time) : Date()
                let dateKey = DateHelper.dateKey(from: date)
                let hourKey = DateHelper.hourKey(from: date)

                if var e = dailyData[dateKey] { e.tokens += total; e.messages += 1; dailyData[dateKey] = e }
                else { dailyData[dateKey] = DayUsage(tokens: total, messages: 1) }

                if var e = hourlyData[hourKey] { e.tokens += total; e.messages += 1; hourlyData[hourKey] = e }
                else { hourlyData[hourKey] = HourlyUsage(tokens: total, messages: 1) }

                if dateKey == today {
                    recentEntries.append(RecentEntry(timestamp: date, tokens: total))
                    // L4: 限制 recentEntries 增长，只保留 active 窗口 3 倍内的条目
                    if recentEntries.count > 64 {
                        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
                        recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
                    }
                }
            }
        }

        lastScanTime = Date()
    }

    func todaySessions() -> [SessionInfo] {
        // Aider 的 analytics JSONL 没有明确的 session 分组，返回空
        return []
    }
}
