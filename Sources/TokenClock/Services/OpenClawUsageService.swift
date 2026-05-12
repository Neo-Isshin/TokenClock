import Foundation

/// 从 OpenClaw 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.openclaw/agents/*/sessions/
final class OpenClawUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let openclawHome: String

    init() {
        if let xdg = ProcessInfo.processInfo.environment["OPENCLAW_HOME"] {
            openclawHome = xdg
        } else {
            openclawHome = PathConfig.openclawHome()
        }
    }

    // MARK: - 公开接口

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
        recentEntries = []
        scanAgentDirectories()
    }

    func incrementalScan() {
        scanAgentDirectories()
    }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let total = d?.tokens ?? 0
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let rate = total > 0 ? Double(cache) / Double(total) : 0
        return (total, d?.messages ?? 0, rate)
    }

    /// 当前小时的 token 消耗（用于热力计算）
    func currentHourTokens() -> Int {
        let key = DateHelper.currentHourKey()
        return hourlyData[key]?.tokens ?? 0
    }

    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        var tokens = 0, messages = 0
        for entry in recentEntries {
            if entry.timestamp >= cutoff {
                tokens += entry.tokens
                messages += 1
            }
        }
        return (tokens, messages)
    }

    func isActive() -> Bool {
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanAgentDirectories() {
        let agentsDir = openclawHome + "/agents"
        guard let agentNames = try? fm.contentsOfDirectory(atPath: agentsDir) else { return }

        for name in agentNames {
            let sessionsDir = agentsDir + "/" + name + "/sessions"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { continue }

            for file in files {
                if file.contains(".checkpoint.") || file.hasSuffix(".lock") || file == "sessions.json" { continue }
                guard file.hasSuffix(".jsonl") else { continue }

                let fullPath = sessionsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                // 增量：减旧贡献
                if let oldContrib = fileDailyContrib[fullPath] {
                    subtractDailyContributions(oldContrib)
                }
                if let oldContrib = fileHourlyContrib[fullPath] {
                    subtractHourlyContributions(oldContrib)
                }
                if let oldContrib = fileCacheContrib[fullPath] {
                    subtractCacheContributions(oldContrib)
                }

                // 跳过 cron 触发的 session
                if isCronSession(path: fullPath) {
                    fileDailyContrib.removeValue(forKey: fullPath)
                    fileHourlyContrib.removeValue(forKey: fullPath)
                    fileCacheContrib.removeValue(forKey: fullPath)
                    fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
                    continue
                }

                parseFile(path: fullPath, isIncremental: fileDailyContrib[fullPath] != nil)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
    }

    private func subtractCacheContributions(_ contrib: [String: Int]) {
        for (dateKey, count) in contrib {
            if var existing = dailyCache[dateKey] {
                existing -= count
                if existing <= 0 {
                    dailyCache.removeValue(forKey: dateKey)
                } else {
                    dailyCache[dateKey] = existing
                }
            }
        }
    }

    private func subtractDailyContributions(_ contrib: [String: DayUsage]) {
        for (dateKey, usage) in contrib {
            if var existing = dailyData[dateKey] {
                existing.tokens -= usage.tokens
                existing.messages -= usage.messages
                if existing.tokens <= 0 && existing.messages <= 0 {
                    dailyData.removeValue(forKey: dateKey)
                } else {
                    dailyData[dateKey] = existing
                }
            }
        }
    }

    private func subtractHourlyContributions(_ contrib: [String: HourlyUsage]) {
        for (hourKey, usage) in contrib {
            if var existing = hourlyData[hourKey] {
                existing.tokens -= usage.tokens
                existing.messages -= usage.messages
                if existing.tokens <= 0 && existing.messages <= 0 {
                    hourlyData.removeValue(forKey: hourKey)
                } else {
                    hourlyData[hourKey] = existing
                }
            }
        }
    }

    private func parseFile(path: String, isIncremental: Bool = false) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let today = DateHelper.todayKey()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()

        var newDailyContrib: [String: DayUsage] = [:]
        var newHourlyContrib: [String: HourlyUsage] = [:]
        var newCacheContrib: [String: Int] = [:]

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)

            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("\"assistant\"") {
                    if let result = parseAssistantLine(line) {
                        accumulate(result, today: today,
                                   dailyContrib: &newDailyContrib,
                                   hourlyContrib: &newHourlyContrib,
                                   cacheContrib: &newCacheContrib)
                    }
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\"") {
            if let result = parseAssistantLine(line) {
                accumulate(result, today: today,
                           dailyContrib: &newDailyContrib,
                           hourlyContrib: &newHourlyContrib,
                           cacheContrib: &newCacheContrib)
            }
        }

        fileDailyContrib[path] = newDailyContrib
        fileHourlyContrib[path] = newHourlyContrib
        fileCacheContrib[path] = newCacheContrib
        fileCacheContrib[path] = newCacheContrib
    }

    private struct ParseResult {
        let dateKey: String
        let hourKey: String
        let tokens: Int
        let cacheTokens: Int
        let timestamp: Date?
    }

    private func parseAssistantLine(_ line: String) -> ParseResult? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        guard msg["role"] as? String == "assistant" else { return nil }
        guard let usage = msg["usage"] as? [String: Any] else { return nil }

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

        return ParseResult(dateKey: dateKey, hourKey: hourKey,
                          tokens: tokens, cacheTokens: cacheTokens,
                          timestamp: DateHelper.parseISO8601(timestamp))
    }

    private func accumulate(_ result: ParseResult, today: String,
                            dailyContrib: inout [String: DayUsage],
                            hourlyContrib: inout [String: HourlyUsage],
                            cacheContrib: inout [String: Int]) {
        // daily
        if var existing = dailyData[result.dateKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            dailyData[result.dateKey] = existing
        } else {
            dailyData[result.dateKey] = DayUsage(tokens: result.tokens, messages: 1)
        }
        if var existing = dailyContrib[result.dateKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            dailyContrib[result.dateKey] = existing
        } else {
            dailyContrib[result.dateKey] = DayUsage(tokens: result.tokens, messages: 1)
        }
        // hourly
        if var existing = hourlyData[result.hourKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            hourlyData[result.hourKey] = existing
        } else {
            hourlyData[result.hourKey] = HourlyUsage(tokens: result.tokens, messages: 1)
        }
        if var existing = hourlyContrib[result.hourKey] {
            existing.tokens += result.tokens
            existing.messages += 1
            hourlyContrib[result.hourKey] = existing
        } else {
            hourlyContrib[result.hourKey] = HourlyUsage(tokens: result.tokens, messages: 1)
        }
        // cache
        dailyCache[result.dateKey, default: 0] += result.cacheTokens
        cacheContrib[result.dateKey, default: 0] += result.cacheTokens
        // recentEntries（只记录今日）
        if result.dateKey == today, let ts = result.timestamp {
            recentEntries.append(RecentEntry(timestamp: ts, tokens: result.tokens))
        }
    }

    // MARK: - 今日活跃 Agent 列表

    /// 返回今日每个活跃 agent 的数据（用于展开展示）
    func todaySessions() -> [SessionInfo] {
        let agentsDir = openclawHome + "/agents"
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: agentsDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let agentNames = try? fm.contentsOfDirectory(atPath: agentsDir) else { return [] }

        let today = DateHelper.todayKey()
        var results: [SessionInfo] = []

        for agentName in agentNames {
            let sessionsDir = agentsDir + "/" + agentName + "/sessions"
            var sIsDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionsDir, isDirectory: &sIsDir), sIsDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { continue }

            var agentTokens = 0
            var agentMessages = 0

            for file in files {
                // 过滤掉 trajectory 和 checkpoint 文件，只保留主 session 日志
                guard file.hasSuffix(".jsonl"),
                      !file.contains(".checkpoint."),
                      !file.contains(".trajectory.") else { continue }
                let fullPath = sessionsDir + "/" + file

                // 跳过 cron 触发的 session
                if isCronSession(path: fullPath) { continue }

                // 解析该文件今日数据（以实际内容为准，不以文件修改时间为准）
                let (tokens, messages) = parseSessionFileToday(path: fullPath, today: today)
                agentTokens += tokens
                agentMessages += messages
            }

            if agentTokens > 0 {
                results.append(SessionInfo(
                    rawId: agentName,
                    displayName: agentName,
                    detail: nil,
                    todayTokens: agentTokens,
                    todayMessages: agentMessages,
                    isActive: true
                ))
            }
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

    /// 检测 session 是否由 cron 触发
    /// OpenClaw 的 cron 任务会在 session 开始时注入一条用户消息，text 以 `[cron:<UUID> <task_name>]` 开头
    private func isCronSession(path: String) -> Bool {
        guard let stream = InputStream(fileAtPath: path) else { return false }
        stream.open()
        defer { stream.close() }

        let bufSize = 65536
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
                if let line = String(data: lineData, encoding: .utf8),
                   line.contains("\"user\""),
                   let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = obj["message"] as? [String: Any],
                   msg["role"] as? String == "user",
                   let content = msg["content"] as? [[String: Any]],
                   let firstText = content.first?["text"] as? String {
                    return firstText.hasPrefix("[cron:")
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"user\""),
           let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? [String: Any],
           msg["role"] as? String == "user",
           let content = msg["content"] as? [[String: Any]],
           let firstText = content.first?["text"] as? String {
            return firstText.hasPrefix("[cron:")
        }

        return false
    }

    /// 解析单个 session 文件的今日数据
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
                if line.contains("\"assistant\""), let result = parseAssistantLine(line) {
                    if result.dateKey == today {
                        tokens += result.tokens
                        messages += 1
                    }
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\""),
           let result = parseAssistantLine(line), result.dateKey == today {
            tokens += result.tokens
            messages += 1
        }

        return (tokens, messages)
    }
}
