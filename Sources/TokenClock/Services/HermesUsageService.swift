import Foundation

/// 从远程 Hermes agent (OpenClaw on Debian) 读取 token 使用数据
/// Hermes 是 OpenClaw agent "main"，运行在 Debian 小主机上
/// 数据格式与 OpenClaw 相同，通过 SSH 读取
final class HermesUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default

    /// SSH 配置：使用本地已配置的 ssh alias "debian"
    private let sshHost = "debian"
    private let remoteBase = "~/.openclaw/agents/main/sessions"

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
        recentEntries = []
        scanRemoteSessions()
    }

    func incrementalScan() { scanRemoteSessions() }

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

    private func scanRemoteSessions() {
        // 1. 获取远程文件列表及修改时间
        let listCmd = "ssh -o ConnectTimeout=5 \(sshHost) " +
            "'ls -lT --time-style=+%s \(remoteBase)/*.jsonl 2>/dev/null " +
            "| grep -v \"\\.checkpoint\\.\" | grep -v \"\\.lock\" | grep -v \"sessions\\.json\" " +
            "| grep -v \"\\.deleted\\.\" | grep -v \"\\.reset\\.\"'"

        guard let listOutput = try? Shell.run(listCmd) else { return }
        let lines = listOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 6)
            guard parts.count >= 7 else { continue }
            let modTimestamp = Int(parts[5]) ?? 0
            let modDate = Date(timeIntervalSince1970: Double(modTimestamp))
            let remotePath = String(parts[6])

            let cached = fileCache[remotePath]
            if cached != nil && cached?.modDate == modDate { continue }

            // 2. 撤销旧贡献
            if let old = fileDailyContrib[remotePath] { subtractDaily(old) }
            if let old = fileHourlyContrib[remotePath] { subtractHourly(old) }
            if let old = fileCacheContrib[remotePath] { subtractCache(old) }

            // 3. 通过 SSH 读取文件内容
            let catCmd = "ssh -o ConnectTimeout=5 \(sshHost) 'cat \"\(remotePath)\"'"
            guard let content = try? Shell.run(catCmd) else {
                fileCache[remotePath] = FileMeta(path: remotePath, modDate: modDate)
                continue
            }

            parseContent(content, remotePath: remotePath)
            fileCache[remotePath] = FileMeta(path: remotePath, modDate: modDate)
        }
    }

    private func parseContent(_ content: String, remotePath: String) {
        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains("\"assistant\""), let r = parseLine(trimmed) else { continue }
            accumulate(r, today: today, daily: &newDaily, hourly: &newHourly, cache: &newCache)
        }

        fileDailyContrib[remotePath] = newDaily
        fileHourlyContrib[remotePath] = newHourly
        fileCacheContrib[remotePath] = newCache
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

    private struct R { let dateKey: String; let hourKey: String; let tokens: Int; let cacheTokens: Int; let ts: Date? }

    private func parseLine(_ line: String) -> R? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let msg = obj["message"] as? [String: Any],
              msg["role"] as? String == "assistant",
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let input = usage["input"] as? Int ?? 0
        let output = usage["output"] as? Int ?? 0
        let cacheRead = usage["cacheRead"] as? Int ?? 0
        let cacheWrite = usage["cacheWrite"] as? Int ?? 0
        let tokens = input + output + cacheRead + cacheWrite
        let cacheTokens = cacheRead + cacheWrite
        guard tokens > 0 else { return nil }
        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        let hourKey = DateHelper.localHourKey(from: timestamp)
        guard !dateKey.isEmpty else { return nil }
        return R(dateKey: dateKey, hourKey: hourKey,
                 tokens: tokens, cacheTokens: cacheTokens,
                 ts: DateHelper.parseISO8601(timestamp))
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
}

/// Shell 命令执行工具
private enum Shell {
    static func run(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
