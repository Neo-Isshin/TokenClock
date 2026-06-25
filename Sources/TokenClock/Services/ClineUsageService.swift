import Foundation

/// 从 Cline (VS Code 扩展) 本地 JSON 文件读取 token 使用数据
/// 数据位置: ~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/
///   - tasks/{task-id}/                  每个任务的文件夹
///     - api_conversation.json           含 token usage 字段
///   - taskHistory.json                  任务索引（含 tokensIn/tokensOut）
final class ClineUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var lastScanTime: Date = .distantPast

    private let fm = FileManager.default
    private let clineHome: String

    init() {
        clineHome = PathConfig.clineHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        dailyCache.removeAll(); recentEntries = []
        lastScanTime = .distantPast
        scanTasks()
    }

    func incrementalScan() { scanTasks() }

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

    private func scanTasks() {
        let tasksDir = clineHome + "/tasks"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: tasksDir, isDirectory: &isDir), isDir.boolValue else { return }

        // 检查是否有新数据
        guard let taskDirs = try? fm.contentsOfDirectory(atPath: tasksDir) else { return }
        var newestMod: Date?
        for task in taskDirs {
            let convPath = tasksDir + "/" + task + "/api_conversation.json"
            if let attrs = try? fm.attributesOfItem(atPath: convPath),
               let mod = attrs[.modificationDate] as? Date {
                if newestMod == nil || mod > newestMod! { newestMod = mod }
            }
        }
        if let newest = newestMod, newest <= lastScanTime { return }

        // 重读
        dailyData.removeAll(); hourlyData.removeAll()
        dailyCache.removeAll(); recentEntries = []

        for task in taskDirs {
            let convPath = tasksDir + "/" + task + "/api_conversation.json"
            parseConversationFile(convPath)
        }
        if let newest = newestMod { lastScanTime = newest }
    }

    /// 解析 api_conversation.json
    /// 格式: 数组，每个元素含 { ts: 1234567890, message: { usage: { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens } } }
    private func parseConversationFile(_ path: String) {
        guard let data = fm.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        let today = DateHelper.todayKey()

        for entry in arr {
            // 提取时间戳
            let ts = (entry["ts"] as? Double) ?? (entry["timestamp"] as? Double) ?? 0
            let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000.0) : Date()
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)

            // token 数据在 message.usage 或 message.metadata.usage
            guard let message = entry["message"] as? [String: Any] else { continue }
            let usage = (message["usage"] as? [String: Any])
                ?? ((message["metadata"] as? [String: Any])?["usage"] as? [String: Any])
            guard let usage = usage else { continue }

            // Cline 字段名（Anthropic API 风格）
            let input = (usage["input_tokens"] as? Int)
                ?? (usage["inputTokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int)
                ?? (usage["outputTokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int)
                ?? (usage["cacheRead"] as? Int)
                ?? (usage["cacheReadInputTokens"] as? Int) ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? Int)
                ?? (usage["cacheWrite"] as? Int)
                ?? (usage["cacheCreationInputTokens"] as? Int) ?? 0
            let total = input + output + cacheRead + cacheWrite
            guard total > 0 else { continue }

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

            let cacheTokens = cacheRead + cacheWrite
            dailyCache[dateKey, default: 0] += cacheTokens

            if dateKey == today {
                recentEntries.append(RecentEntry(timestamp: date, tokens: total))
            }
        }
    }

    func todaySessions() -> [SessionInfo] {
        let tasksDir = clineHome + "/tasks"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: tasksDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let taskDirs = try? fm.contentsOfDirectory(atPath: tasksDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for task in taskDirs {
            let convPath = tasksDir + "/" + task + "/api_conversation.json"
            guard let attrs = try? fm.attributesOfItem(atPath: convPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  DateHelper.dateKey(from: modDate) == today else { continue }

            var totalTokens = 0, msgCount = 0
            guard let data = fm.contents(atPath: convPath),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for entry in arr {
                let ts = (entry["ts"] as? Double) ?? 0
                let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000.0) : Date()
                guard DateHelper.dateKey(from: date) == today else { continue }
                guard let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let total = input + output + cacheRead + cacheWrite
                guard total > 0 else { continue }
                totalTokens += total; msgCount += 1
            }
            guard totalTokens > 0 else { continue }
            results.append(SessionInfo(
                rawId: task, displayName: SessionIdDisplay.format(task), detail: nil,
                todayTokens: totalTokens, todayMessages: msgCount, isActive: true
            ))
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
