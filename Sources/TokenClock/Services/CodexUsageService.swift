import Foundation
import SQLite3

/// 从 Codex CLI 读取 token 使用数据
/// Token 计数使用 total_token_usage.total_tokens 的差值（累计增量），避免 last_token_usage 重复统计
/// 缓存率从 last_token_usage.cached_input_tokens 计算
/// Session 列表从 SQLite threads 表读取
final class CodexUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var sessionMessagesByDate: [String: [String: Int]] = [:]
    private var sessionTokensByDate: [String: [String: Int]] = [:]

    /// 已扫描的 JSONL 文件路径及其统计结果（含文件大小用于变更检测）
    private var jsonlCache: [String: (dateKey: String, count: Int, tokens: Int, cachedTokens: Int, fileSize: Int)] = [:]

    private let fm = FileManager.default
    private let codexHome: String

    init() {
        codexHome = PathConfig.codexHome()
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        recentEntries = []
        sessionMessagesByDate = [:]
        sessionTokensByDate = [:]
        jsonlCache = [:]
        scanJSONL()
    }

    func incrementalScan() {
        // 检测文件变化：如有任何已缓存文件增长，触发全量重扫
        let needsRescan = checkForFileChanges()
        if needsRescan {
            fullScan()
        } else {
            scanJSONL()
        }
    }

    /// 检查已缓存的文件是否有增长
    private func checkForFileChanges() -> Bool {
        for (path, cached) in jsonlCache {
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int) ?? 0
            if size != cached.fileSize { return true }
        }
        return false
    }

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

    // MARK: - JSONL 扫描（tokens + messages + cache）

    private func scanJSONL() {
        let sessionsDir = codexHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return }
        scanJSONLDirRecursive(sessionsDir)
    }

    private func scanJSONLDirRecursive(_ dirPath: String) {
        guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
        for item in contents {
            let fullPath = dirPath + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                scanJSONLDirRecursive(fullPath)
            } else if item.hasPrefix("rollout-") && item.hasSuffix(".jsonl") {
                guard jsonlCache[fullPath] == nil else { continue }
                parseJSONLFile(path: fullPath)
            }
        }
    }

    private func parseJSONLFile(path: String) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var prevTotalUsage = 0
        var lastDateKey = ""
        var lastTimestamp: Date?
        // 按日期拆分的统计
        var dailyTokens: [String: Int] = [:]
        var dailyMsgs: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)
            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""

                if line.contains("\"type\":\"token_count\",\"info\"") {
                    let grossTotal = extractInt(from: line, key: "\"total_tokens\"")
                    let reasoning = extractInt(from: line, key: "\"reasoning_output_tokens\"")
                    let effectiveTotal = grossTotal + reasoning
                    let delta = max(0, effectiveTotal - prevTotalUsage)
                    prevTotalUsage = effectiveTotal

                    var dateKey = ""
                    if let tsRange = line.range(of: "\"timestamp\":\"") {
                        let start = tsRange.upperBound
                        if let end = line[start...].firstIndex(of: "\"") {
                            let tsStr = String(line[start..<end])
                            dateKey = DateHelper.localDateKey(from: tsStr)
                            lastTimestamp = DateHelper.parseISO8601(tsStr)
                        }
                    }
                    guard !dateKey.isEmpty else { continue }
                    lastDateKey = dateKey

                    if delta > 0 {
                        dailyTokens[dateKey, default: 0] += delta
                        dailyMsgs[dateKey, default: 0] += 1
                        dailyCached[dateKey, default: 0] += extractCachedTokens(from: line)
                    }
                }
            }
        }

        // 尾部残留
        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"type\":\"token_count\",\"info\"") {
            let grossTotal = extractInt(from: line, key: "\"total_tokens\"")
            let reasoning = extractInt(from: line, key: "\"reasoning_output_tokens\"")
            let effectiveTotal = grossTotal + reasoning
            let delta = max(0, effectiveTotal - prevTotalUsage)
            if delta > 0, !lastDateKey.isEmpty {
                dailyTokens[lastDateKey, default: 0] += delta
                dailyMsgs[lastDateKey, default: 0] += 1
                dailyCached[lastDateKey, default: 0] += extractCachedTokens(from: line)
            }
        }

        let totalTokens = dailyTokens.values.reduce(0, +)
        let totalMsgs = dailyMsgs.values.reduce(0, +)
        let totalCached = dailyCached.values.reduce(0, +)
        jsonlCache[path] = (lastDateKey, totalMsgs, totalTokens, totalCached, fileSize(at: path))
        guard totalMsgs > 0, !lastDateKey.isEmpty else { return }

        // 按日期写入 dailyData
        for (dateKey, tokens) in dailyTokens {
            dailyData[dateKey, default: DayUsage(tokens: 0, messages: 0)].tokens += tokens
            dailyData[dateKey]!.messages += dailyMsgs[dateKey] ?? 0
            dailyCache[dateKey, default: 0] += dailyCached[dateKey] ?? 0
        }

        if let ts = lastTimestamp {
            recentEntries.append(RecentEntry(timestamp: ts, tokens: totalTokens))
        }
        if let sessionId = sessionId(fromJSONLPath: path), !sessionId.isEmpty {
            for (dateKey, tokens) in dailyTokens {
                sessionMessagesByDate[dateKey, default: [:]][sessionId, default: 0] += dailyMsgs[dateKey] ?? 0
                sessionTokensByDate[dateKey, default: [:]][sessionId, default: 0] += tokens
            }
        }
    }

    private func sessionId(fromJSONLPath path: String) -> String? {
        let filename = (path as NSString).lastPathComponent
        guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropFirst("rollout-".count).dropLast(".jsonl".count))
        // Codex filenames are rollout-YYYY-MM-DDTHH-MM-SS-<sessionId>.jsonl.
        guard stem.count > 20 else { return nil }
        return String(stem.dropFirst(20))
    }

    /// 从 last_token_usage 中提取 cached_input_tokens（用于缓存率计算）
    private func extractCachedTokens(from line: String) -> Int {
        guard let range = line.range(of: "\"last_token_usage\":{") else { return 0 }
        let segment = String(line[range.lowerBound...]).prefix(300)
        return extractInt(from: String(segment), key: "\"cached_input_tokens\"")
    }

    private func extractInt(from str: String, key: String) -> Int {
        guard let range = str.range(of: key) else { return 0 }
        let after = str[range.upperBound...]
        // 跳过可能的冒号和空格
        let digits = after.drop(while: { $0 == ":" || $0 == " " })
        let numStr = digits.prefix(while: { $0.isNumber })
        return Int(numStr) ?? 0
    }

    // MARK: - 今日活跃 Session 列表（从 SQLite）

    private var dbPath: String {
        codexHome + "/state_5.sqlite"
    }

    func todaySessions() -> [SessionInfo] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let todayStart = Date().addingTimeInterval(-86400)
        let query = """
        SELECT id, updated_at_ms, cwd
        FROM threads
        WHERE updated_at_ms >= ?
        ORDER BY updated_at_ms DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, todayStart.timeIntervalSince1970 * 1000)

        let today = DateHelper.todayKey()
        let sessionMessageCounts = sessionMessagesByDate[today] ?? [:]
        let sessionTokenCounts = sessionTokensByDate[today] ?? [:]
        var results: [SessionInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idPtr = sqlite3_column_text(stmt, 0)
            let sessionId = idPtr != nil ? String(cString: idPtr!) : ""
            let updatedAtMs = sqlite3_column_int64(stmt, 1)
            let cwdPtr = sqlite3_column_text(stmt, 2)

            let updatedDate = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000.0)
            let dateKey = DateHelper.dateKey(from: updatedDate)
            guard dateKey == today else { continue }

            let displayId = sessionId.isEmpty ? "unknown" : String(sessionId.prefix(7))
            let cwd = cwdPtr != nil ? String(cString: cwdPtr!) : ""
            let detail = cwd.isEmpty ? nil : cwd
            let messages = sessionMessageCount(
                for: sessionId,
                in: sessionMessageCounts,
                fallback: 1
            )
            let tokens = sessionTokenCount(
                for: sessionId,
                in: sessionTokenCounts
            )
            guard tokens > 0 else { continue }

            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: detail,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true
            ))
        }

        return results
    }

    private func sessionMessageCount(
        for sessionId: String,
        in counts: [String: Int],
        fallback: Int
    ) -> Int {
        if let exact = counts[sessionId] { return exact }
        if let prefixMatch = counts.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return fallback
    }

    private func sessionTokenCount(
        for sessionId: String,
        in counts: [String: Int]
    ) -> Int {
        if let exact = counts[sessionId] { return exact }
        if let prefixMatch = counts.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return 0
    }

    private func fileSize(at path: String) -> Int {
        (try? fm.attributesOfItem(atPath: path)[FileAttributeKey.size] as? Int) ?? 0
    }
}
