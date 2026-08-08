import Foundation

/// 从 Aider analytics JSONL 文件读取 token 使用数据
/// 需要用户启动时加 --analytics-log 参数（如 --analytics-log ~/.aider/analytics.jsonl）
/// 数据位置: 用户指定路径，默认检测 ~/.aider/analytics.jsonl
/// 格式: JSONL，每行含 event 和 properties.prompt_tokens / properties.completion_tokens / properties.cost
final class AiderUsageService: @unchecked Sendable {
    private static let messageLineNeedle = [Data("\"message_send\"".utf8)]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var recentEntries: [RecentEntry] = []
    private var lastScanTime: Date = .distantPast

    private let fm = FileManager.default
    private let aiderHome: String

    init(aiderHome: String? = nil) {
        self.aiderHome = aiderHome ?? PathConfig.aiderHome()
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

    private var analyticsPath: String {
        aiderHome + "/analytics.jsonl"
    }

    private func scanAnalyticsFile() {
        let path = analyticsPath
        var isFile: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isFile), !isFile.boolValue else {
            dailyData.removeAll(); hourlyData.removeAll(); recentEntries = []
            lastScanTime = .distantPast
            return
        }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              modDate > lastScanTime else { return }

        // 文件有修改，重读
        dailyData.removeAll(); hourlyData.removeAll(); recentEntries = []

        let today = DateHelper.todayKey()
        guard JSONLLineReader.read(
            path: path,
            matchingAny: Self.messageLineNeedle,
            onLine: { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                // 只处理 message_send 事件
                guard obj["event"] as? String == "message_send",
                      let props = obj["properties"] as? [String: Any] else { return }

                let promptTokens = props["prompt_tokens"] as? Int ?? 0
                let completionTokens = props["completion_tokens"] as? Int ?? 0
                let total = promptTokens + completionTokens
                guard total > 0 else { return }

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
                }
            }
        ) != nil else { return }

        // 单文件读取完后再修剪一次；逐行过滤会让繁忙日志退化为 O(n²)。
        if recentEntries.count > 64 {
            let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
            recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
        }
        lastScanTime = Date()
    }

    func todaySessions() -> [SessionInfo] {
        // Aider 的 analytics JSONL 没有明确的 session 分组，返回空
        return []
    }
}
