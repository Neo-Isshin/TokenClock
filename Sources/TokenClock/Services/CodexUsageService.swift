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

    /// 单个 rollout 的可替换统计快照。文件增长时只从上次 EOF 继续读；截断时才重扫该文件。
    private struct JSONLFileSnapshot: Sendable {
        var fileSize = 0
        var modificationDate = Date.distantPast
        var trailingBytes = Data()
        var currentModel: String?
        var dailyTokens: [String: Int] = [:]
        var dailyMessages: [String: Int] = [:]
        var dailyCachedTokens: [String: Int] = [:]
        var hourlyTokens: [String: Int] = [:]
        var hourlyMessages: [String: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var recentEntries: [RecentEntry] = []
        var sessionId: String?
    }

    private struct JSONLDescriptor {
        let path: String
        let fileSize: Int
        let modificationDate: Date
    }

    private var jsonlCache: [String: JSONLFileSnapshot] = [:]

    private static let tokenCountMarker = Data("\"type\":\"token_count\"".utf8)
    private static let turnContextMarker = Data("\"type\":\"turn_context\"".utf8)

    private let fm = FileManager.default
    private let codexHome: String

    init(codexHome: String = PathConfig.codexHome()) {
        self.codexHome = codexHome
    }

    func fullScan() {
        jsonlCache = [:]
        scanJSONL()
    }

    func incrementalScan() {
        scanJSONL()
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
        let descriptors = discoverRelevantJSONLFiles(in: sessionsDir)
        let discoveredPaths = Set(descriptors.map(\.path))
        jsonlCache = jsonlCache.filter { discoveredPaths.contains($0.key) }

        for descriptor in descriptors {
            if let cached = jsonlCache[descriptor.path],
               cached.fileSize == descriptor.fileSize,
               cached.modificationDate == descriptor.modificationDate {
                continue
            }
            parseJSONLFile(descriptor)
        }
        rebuildAggregates()
    }

    private func discoverRelevantJSONLFiles(in sessionsDir: String) -> [JSONLDescriptor] {
        let root = URL(fileURLWithPath: sessionsDir, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(AppConfig.Scan.codexSessionLookbackDays - 1),
            to: startOfToday
        ) ?? startOfToday

        var descriptors: [JSONLDescriptor] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else { continue }
            descriptors.append(JSONLDescriptor(
                path: url.path,
                fileSize: values.fileSize ?? 0,
                modificationDate: modificationDate
            ))
        }
        return descriptors.sorted { $0.modificationDate < $1.modificationDate }
    }

    private func parseJSONLFile(_ descriptor: JSONLDescriptor) {
        let cached = jsonlCache[descriptor.path]
        // 同尺寸但 mtime 改变意味着可能发生原地改写，必须重扫；只有严格增长才可安全续读。
        let canAppend = cached.map { descriptor.fileSize > $0.fileSize } ?? false
        var snapshot = canAppend ? cached! : JSONLFileSnapshot()
        let offset = canAppend ? snapshot.fileSize : 0
        if !canAppend {
            snapshot.sessionId = sessionId(fromJSONLPath: descriptor.path)
        }

        guard let handle = FileHandle(forReadingAtPath: descriptor.path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return
        }

        var buffer = snapshot.trailingBytes
        snapshot.trailingBytes.removeAll(keepingCapacity: false)

        while true {
            guard let chunk = try? handle.read(upToCount: AppConfig.Scan.codexJSONLChunkSize),
                  !chunk.isEmpty else { break }
            buffer.append(chunk)

            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                if cursor < newline {
                    processJSONLLine(buffer[cursor..<newline], into: &snapshot)
                }
                cursor = buffer.index(after: newline)
            }
            // 关键修复：每个 1 MiB 分块只搬一次剩余字节。旧实现每读一行都
            // `lineBuf = lineBuf[... ]`，对大型 rollout 造成大量重复拷贝与内存峰值。
            if cursor > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<cursor)
            }
        }

        snapshot.trailingBytes = buffer
        // 文件可能在扫描期间继续增长，记录实际已读到的 EOF。下次只读新增部分。
        snapshot.fileSize = fileSize(at: descriptor.path)
        snapshot.modificationDate = descriptor.modificationDate
        let recentCutoff = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
        snapshot.recentEntries.removeAll { $0.timestamp < recentCutoff }
        jsonlCache[descriptor.path] = snapshot
    }

    private func processJSONLLine(_ lineData: Data.SubSequence, into snapshot: inout JSONLFileSnapshot) {
        if lineData.range(of: Self.tokenCountMarker) != nil {
            let line = String(decoding: lineData, as: UTF8.self)
            guard let usageRange = line.range(of: "\"last_token_usage\":{") else { return }
            let usageSegment = String(line[usageRange.lowerBound...].prefix(500))
            let tokens = extractInt(from: usageSegment, key: "\"total_tokens\"")
            guard tokens > 0,
                  let timestamp = extractString(from: line, key: "\"timestamp\":\""),
                  let date = DateHelper.parseISO8601(timestamp) else { return }

            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)
            let cached = extractInt(from: usageSegment, key: "\"cached_input_tokens\"")
            let contextWindow = extractInt(from: line, key: "\"model_context_window\"")
            let model = snapshot.currentModel ?? (contextWindow == 258400 ? "gpt-5.5" : nil)

            snapshot.dailyTokens[dateKey, default: 0] += tokens
            snapshot.dailyMessages[dateKey, default: 0] += 1
            snapshot.dailyCachedTokens[dateKey, default: 0] += cached
            snapshot.hourlyTokens[hourKey, default: 0] += tokens
            snapshot.hourlyMessages[hourKey, default: 0] += 1
            snapshot.recentEntries.append(RecentEntry(timestamp: date, tokens: tokens))
            if let model { snapshot.modelTokens[model, default: 0] += tokens }
        } else if lineData.range(of: Self.turnContextMarker) != nil {
            let line = String(decoding: lineData, as: UTF8.self)
            if let model = codexModel(fromLine: line) { snapshot.currentModel = model }
        }
    }

    private func rebuildAggregates() {
        dailyData.removeAll(keepingCapacity: true)
        hourlyData.removeAll(keepingCapacity: true)
        dailyCache.removeAll(keepingCapacity: true)
        recentEntries.removeAll(keepingCapacity: true)
        sessionMessagesByDate.removeAll(keepingCapacity: true)
        sessionTokensByDate.removeAll(keepingCapacity: true)
        sessionModels.removeAll(keepingCapacity: true)

        var sessionModelTokens: [String: [String: Int]] = [:]
        let recentCutoff = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)

        for snapshot in jsonlCache.values {
            for (key, tokens) in snapshot.dailyTokens {
                dailyData[key, default: DayUsage(tokens: 0, messages: 0)].tokens += tokens
                dailyData[key]!.messages += snapshot.dailyMessages[key] ?? 0
                dailyCache[key, default: 0] += snapshot.dailyCachedTokens[key] ?? 0
            }
            for (key, tokens) in snapshot.hourlyTokens {
                hourlyData[key, default: HourlyUsage(tokens: 0, messages: 0)].tokens += tokens
                hourlyData[key]!.messages += snapshot.hourlyMessages[key] ?? 0
            }
            recentEntries.append(contentsOf: snapshot.recentEntries.filter { $0.timestamp >= recentCutoff })

            guard let sessionId = snapshot.sessionId, !sessionId.isEmpty else { continue }
            for (key, tokens) in snapshot.dailyTokens {
                sessionTokensByDate[key, default: [:]][sessionId, default: 0] += tokens
                sessionMessagesByDate[key, default: [:]][sessionId, default: 0] += snapshot.dailyMessages[key] ?? 0
            }
            for (model, tokens) in snapshot.modelTokens {
                sessionModelTokens[sessionId, default: [:]][model, default: 0] += tokens
            }
        }

        for (sessionId, models) in sessionModelTokens {
            sessionModels[sessionId] = models.max(by: { $0.value < $1.value })?.key
        }
        recentEntries.sort { $0.timestamp < $1.timestamp }
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

    private func extractString(from str: String, key: String) -> String? {
        guard let range = str.range(of: key) else { return nil }
        let start = range.upperBound
        guard let end = str[start...].firstIndex(of: "\"") else { return nil }
        return String(str[start..<end])
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
