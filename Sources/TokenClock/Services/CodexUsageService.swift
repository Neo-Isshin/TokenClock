import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

/// 从 Codex CLI 读取 token 使用数据
/// Token 计数直接使用 last_token_usage（每条消息的增量值），取 total_tokens。
/// 注意：total_tokens == input + output，已包含 reasoning_output_tokens（reasoning ⊂ output），
/// 故不再额外累加 reasoning，否则会重复计算。
/// last_token_usage.input_tokens 已包含 cached_input_tokens，与 total_token_usage 语义一致
/// 缓存率从 last_token_usage.cached_input_tokens 计算
/// Session 列表从 SQLite threads 表读取
final class CodexUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var sessionMessagesByDate: [String: [String: Int]] = [:]
    private var sessionTokensByDate: [String: [String: Int]] = [:]
    /// 每个 session 的代表模型（按 token 占比最高的那个）。
    /// Codex rollout 里模型由 turn_context 事件声明，同一 session 切换模型时取用量最大的。
    private var sessionModels: [String: String] = [:]

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
        sessionModels = [:]
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
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
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

        let bufSize = AppConfig.Scan.jsonlBufferSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()
        var lastDateKey = ""
        var lastTimestamp: Date?
        var dailyTokens: [String: Int] = [:]
        var dailyMsgs: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        // 模型状态机：turn_context 事件声明本 turn 的模型，缓存到下一条 token_count。
        var currentModel: String?
        // 模型 → token 用量，结尾取最大者作为该 session 的代表模型。
        var modelTokens: [String: Int] = [:]

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
                    guard let ltuRange = line.range(of: "\"last_token_usage\":{") else { continue }
                    let segment = String(line[ltuRange.lowerBound...].prefix(500))

                    let totalTokens = extractInt(from: segment, key: "\"total_tokens\"")
                    // total_tokens 已含 reasoning_output_tokens（total == input + output，reasoning ⊂ output），不再重复累加
                    let tokens = totalTokens
                    let cached = extractInt(from: segment, key: "\"cached_input_tokens\"")

                    // 归因模型：优先 turn_context 缓存的 currentModel；
                    // 缺失时按 model_context_window 启发式回退（258400 → gpt-5.5，移植自 open-nova）。
                    let contextWindow = extractInt(from: line, key: "\"model_context_window\"")
                    let modelForTurn = currentModel ?? (contextWindow == 258400 ? "gpt-5.5" : nil)

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

                    if tokens > 0 {
                        dailyTokens[dateKey, default: 0] += tokens
                        dailyMsgs[dateKey, default: 0] += 1
                        dailyCached[dateKey, default: 0] += cached
                        if let m = modelForTurn { modelTokens[m, default: 0] += tokens }
                    }
                } else if line.contains("\"type\":\"turn_context\"") {
                    // turn_context 声明本 turn 模型，缓存供后续 token_count 归因。
                    if let m = codexModel(fromLine: line) { currentModel = m }
                }
            }
        }

        // 尾部残留
        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"type\":\"token_count\",\"info\""),
           let ltuRange = line.range(of: "\"last_token_usage\":{") {
            let segment = String(line[ltuRange.lowerBound...].prefix(500))
            let totalTokens = extractInt(from: segment, key: "\"total_tokens\"")
            // total_tokens 已含 reasoning_output_tokens，不再重复累加
            let tokens = totalTokens
            if tokens > 0, !lastDateKey.isEmpty {
                dailyTokens[lastDateKey, default: 0] += tokens
                dailyMsgs[lastDateKey, default: 0] += 1
                dailyCached[lastDateKey, default: 0] += extractInt(from: segment, key: "\"cached_input_tokens\"")
                if let m = currentModel { modelTokens[m, default: 0] += tokens }
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
            // L4: 限制 recentEntries 增长，只保留 active 窗口 3 倍内的条目
            if recentEntries.count > 64 {
                let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
                recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
            }
        }
        if let sessionId = sessionId(fromJSONLPath: path), !sessionId.isEmpty {
            for (dateKey, tokens) in dailyTokens {
                sessionMessagesByDate[dateKey, default: [:]][sessionId, default: 0] += dailyMsgs[dateKey] ?? 0
                sessionTokensByDate[dateKey, default: [:]][sessionId, default: 0] += tokens
            }
            // 取用量最大的模型作为该 session 的代表模型
            if let dominant = modelTokens.max(by: { $0.value < $1.value })?.key {
                sessionModels[sessionId] = dominant
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

    /// 从一条 turn_context 行解析模型名（多键回退，移植自 open-nova `_codex_model_from_payload`）。
    /// 回退顺序：model → model_key → model_slug → collaboration_mode.settings.model → settings.model
    private func codexModel(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return codexModel(fromPayload: payload)
    }

    private func codexModel(fromPayload payload: [String: Any]) -> String? {
        for key in ["model", "model_key", "model_slug"] {
            if let s = payload[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let s = settings["model"] as? String, !s.isEmpty {
            return s
        }
        if let settings = payload["settings"] as? [String: Any],
           let s = settings["model"] as? String, !s.isEmpty {
            return s
        }
        return nil
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

        let todayStart = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
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

            let displayId = sessionId.isEmpty ? "unknown" : SessionIdDisplay.format(sessionId)
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
                isActive: true,
                model: sessionModel(for: sessionId, in: sessionModels)
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

    /// 按 sessionId 查代表模型（与 token 计数采用同样的前缀容错匹配）
    private func sessionModel(for sessionId: String, in models: [String: String]) -> String? {
        if let exact = models[sessionId] { return exact }
        if let prefixMatch = models.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return nil
    }

    private func fileSize(at path: String) -> Int {
        (try? fm.attributesOfItem(atPath: path)[FileAttributeKey.size] as? Int) ?? 0
    }
}
