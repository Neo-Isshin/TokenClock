import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

/// 从 Codex CLI 读取 token 使用数据
/// Token 计数使用 last_token_usage（每条消息的增量值）。total_tokens 已包含
/// cached_input_tokens，因此主用量必须减去缓存输入（口径同 main 的 TokenAccounting）；
/// reasoning 已包含在 total 中，不再额外累加。
/// Session 列表从 SQLite threads 表读取
final class CodexUsageService: @unchecked Sendable {
    private static let relevantLineNeedles = [
        Data("\"type\":\"token_count\"".utf8),
        Data("\"type\":\"turn_context\"".utf8),
    ]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var sessionMessagesByDate: [String: [String: Int]] = [:]
    private var sessionTokensByDate: [String: [String: Int]] = [:]
    /// dateKey → 归一化模型名 → 计费分桶（工具级费用，与 dailyData 同口径重建）
    private var dailyModelBuckets: [String: [String: ModelBuckets]] = [:]
    /// dateKey → sessionId → 归一化模型名 → 计费分桶（session 级费用）
    private var sessionBucketsByDate: [String: [String: [String: ModelBuckets]]] = [:]
    /// 每个 session 的代表模型（按 token 占比最高的那个）。
    /// Codex rollout 里模型由 turn_context 事件声明，同一 session 切换模型时取用量最大的。
    private var sessionModels: [String: String] = [:]

    /// 每个 rollout 的解析状态。增长中的文件只读取上次 EOF 之后的字节；截断、
    /// 原地替换或同尺寸改写时才重读单个文件。
    private struct JSONLFileState {
        var fileSize: UInt64 = 0
        var modificationDate = Date.distantPast
        var fileNumber: UInt64?
        var trailingData = Data()
        var currentModel: String?
        var dailyTokens: [String: Int] = [:]
        var dailyMessages: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        var hourlyTokens: [String: Int] = [:]
        var hourlyMessages: [String: Int] = [:]
        var recentEntries: [RecentEntry] = []
        var modelTokens: [String: Int] = [:]
        /// dateKey → 归一化模型名 → 计费分桶（费用估算；input 已扣除 cached 部分）
        var dailyBuckets: [String: [String: ModelBuckets]] = [:]
    }

    private var jsonlCache: [String: JSONLFileState] = [:]

    private let fm = FileManager.default
    private let codexHome: String

    init(codexHome: String? = nil) {
        self.codexHome = codexHome ?? PathConfig.codexHome()
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
        let rate = TokenAccounting.cacheReadShare(freshTokens: total, cacheRead: cache)
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
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else {
            jsonlCache.removeAll()
            rebuildAggregates()
            return
        }

        let rootURL = URL(fileURLWithPath: sessionsDir, isDirectory: true)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(AppConfig.Scan.codexSessionLookbackDays - 1),
            to: startOfToday
        ) ?? startOfToday
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var livePaths = Set<String>()
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let path = url.path
            guard let metadata = fileMetadata(at: path),
                  metadata.modificationDate >= cutoff else { continue }
            livePaths.insert(path)
            if var state = jsonlCache[path] {
                let sameFile = state.fileNumber == nil || metadata.fileNumber == nil || state.fileNumber == metadata.fileNumber
                if sameFile, metadata.size > state.fileSize {
                    appendJSONLFile(path: path, metadata: metadata, state: &state)
                    jsonlCache[path] = state
                } else if sameFile,
                          metadata.size == state.fileSize,
                          metadata.modificationDate == state.modificationDate {
                    continue
                } else {
                    jsonlCache[path] = parseJSONLFile(path: path, metadata: metadata)
                }
            } else {
                jsonlCache[path] = parseJSONLFile(path: path, metadata: metadata)
            }
        }

        jsonlCache = jsonlCache.filter { livePaths.contains($0.key) }
        rebuildAggregates()
    }

    private func parseJSONLFile(path: String, metadata: FileMetadata) -> JSONLFileState {
        var state = JSONLFileState(
            modificationDate: metadata.modificationDate,
            fileNumber: metadata.fileNumber
        )
        appendJSONLFile(path: path, metadata: metadata, state: &state)
        return state
    }

    private func appendJSONLFile(path: String, metadata: FileMetadata, state: inout JSONLFileState) {
        let oldOffset = state.fileSize
        let recentCutoff = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
        guard let result = JSONLLineReader.read(
            path: path,
            from: oldOffset,
            prefix: state.trailingData,
            matchingAny: Self.relevantLineNeedles,
            onLine: { line in processJSONLLine(line, recentCutoff: recentCutoff, state: &state) }
        ) else { return }

        state.fileSize = result.offset
        state.trailingData = JSONLLineReader.consumeCompleteTrailingLine(
            result.trailingData,
            onLine: { line in processJSONLLine(line, recentCutoff: recentCutoff, state: &state) }
        )
        state.recentEntries.removeAll { $0.timestamp < recentCutoff }
        state.modificationDate = metadata.modificationDate
        state.fileNumber = metadata.fileNumber
    }

    private func processJSONLLine(
        _ line: String,
        recentCutoff: Date,
        state: inout JSONLFileState
    ) {
        if line.contains("\"type\":\"token_count\"") {
            guard let ltuRange = line.range(of: "\"last_token_usage\":{") else { return }
            let segment = String(line[ltuRange.lowerBound...].prefix(500))
            let rawTotal = extractInt(from: segment, key: "\"total_tokens\"")
            let cached = extractInt(from: segment, key: "\"cached_input_tokens\"")
            let tokens = TokenAccounting.excludingCacheRead(inclusiveTotal: rawTotal, cacheRead: cached)
            let inputTokens = extractInt(from: segment, key: "\"input_tokens\"")
            let outputTokens = extractInt(from: segment, key: "\"output_tokens\"")
            let contextWindow = extractInt(from: line, key: "\"model_context_window\"")
            let modelForTurn = state.currentModel ?? (contextWindow == 258400 ? "gpt-5.5" : nil)

            guard let tsRange = line.range(of: "\"timestamp\":\"") else { return }
            let start = tsRange.upperBound
            guard let end = line[start...].firstIndex(of: "\"") else { return }
            let timestamp = String(line[start..<end])
            guard let date = DateHelper.parseISO8601(timestamp) else { return }
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)
            guard !dateKey.isEmpty, !hourKey.isEmpty else { return }

            if tokens > 0 {
                state.dailyTokens[dateKey, default: 0] += tokens
                state.dailyMessages[dateKey, default: 0] += 1
                state.dailyCached[dateKey, default: 0] += cached
                state.hourlyTokens[hourKey, default: 0] += tokens
                state.hourlyMessages[hourKey, default: 0] += 1
                if date >= recentCutoff {
                    state.recentEntries.append(RecentEntry(timestamp: date, tokens: tokens))
                }
                if let modelForTurn {
                    state.modelTokens[modelForTurn, default: 0] += tokens
                }
                // 费用分桶：input_tokens 已含 cached，扣除后按未缓存输入计价；模型名归一化
                if let model = ModelNormalizer.normalize(modelForTurn) {
                    state.dailyBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(
                        ModelBuckets(
                            input: max(0, inputTokens - cached),
                            output: outputTokens,
                            cacheRead: cached,
                            cacheWrite: 0
                        )
                    )
                }
            }
        } else if line.contains("\"type\":\"turn_context\"") {
            if let model = codexModel(fromLine: line) {
                state.currentModel = model
            }
        }
    }

    private func rebuildAggregates() {
        dailyData.removeAll(keepingCapacity: true)
        hourlyData.removeAll(keepingCapacity: true)
        dailyCache.removeAll(keepingCapacity: true)
        recentEntries.removeAll(keepingCapacity: true)
        sessionMessagesByDate.removeAll(keepingCapacity: true)
        sessionTokensByDate.removeAll(keepingCapacity: true)
        dailyModelBuckets.removeAll(keepingCapacity: true)
        sessionBucketsByDate.removeAll(keepingCapacity: true)
        sessionModels.removeAll(keepingCapacity: true)

        for (path, state) in jsonlCache {
            for (dateKey, tokens) in state.dailyTokens {
                dailyData[dateKey, default: DayUsage(tokens: 0, messages: 0)].tokens += tokens
                dailyData[dateKey]!.messages += state.dailyMessages[dateKey] ?? 0
                dailyCache[dateKey, default: 0] += state.dailyCached[dateKey] ?? 0
            }
            for (hourKey, tokens) in state.hourlyTokens {
                hourlyData[hourKey, default: HourlyUsage(tokens: 0, messages: 0)].tokens += tokens
                hourlyData[hourKey]!.messages += state.hourlyMessages[hourKey] ?? 0
            }
            for (dateKey, models) in state.dailyBuckets {
                for (model, b) in models {
                    dailyModelBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(b)
                }
            }
            recentEntries.append(contentsOf: state.recentEntries)

            guard let sessionId = sessionId(fromJSONLPath: path), !sessionId.isEmpty else { continue }
            for (dateKey, tokens) in state.dailyTokens {
                sessionMessagesByDate[dateKey, default: [:]][sessionId, default: 0] += state.dailyMessages[dateKey] ?? 0
                sessionTokensByDate[dateKey, default: [:]][sessionId, default: 0] += tokens
            }
            for (dateKey, models) in state.dailyBuckets {
                for (model, b) in models {
                    sessionBucketsByDate[dateKey, default: [:]][sessionId, default: [:]][model, default: ModelBuckets()].merge(b)
                }
            }
            if let dominant = state.modelTokens.max(by: { $0.value < $1.value })?.key {
                sessionModels[sessionId] = dominant
            }
        }

        recentEntries.sort { $0.timestamp < $1.timestamp }
    }

    // MARK: - 费用估算

    /// 今日按归一化模型聚合的计费分桶（保留分桶而非金额，价格更新后无需重扫日志）
    func todayModelBuckets() -> [String: ModelBuckets] {
        dailyModelBuckets[DateHelper.todayKey()] ?? [:]
    }

    /// 今日工具级估算费用
    func todayCost() -> CostEstimate {
        PricingService.shared.cost(of: todayModelBuckets())
    }

    /// 今日缓存读 token 总数（dailyCache 累计的 cached_input_tokens；「包含缓存读」展示用）
    func todayCacheReadTokens() -> Int {
        dailyCache[DateHelper.todayKey()] ?? 0
    }

    private struct FileMetadata {
        let size: UInt64
        let modificationDate: Date
        let fileNumber: UInt64?
    }

    private func fileMetadata(at path: String) -> FileMetadata? {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attrs[.modificationDate] as? Date else { return nil }
        return FileMetadata(
            size: size,
            modificationDate: modificationDate,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        )
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
        let sessionBuckets = sessionBucketsByDate[today] ?? [:]
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

            let matchedBuckets = sessionBucketsMatching(sessionId, in: sessionBuckets)
            let sessionCacheRead = matchedBuckets.values.reduce(0) { $0 + $1.cacheRead }
            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: detail,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true,
                model: sessionModel(for: sessionId, in: sessionModels),
                todayCost: PricingService.shared.cost(of: matchedBuckets),
                cacheReadTokens: sessionCacheRead
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

    /// 按 sessionId 查计费分桶（同样的前缀容错匹配；未命中返回空 → 费用按 $0 处理）
    private func sessionBucketsMatching(
        _ sessionId: String,
        in buckets: [String: [String: ModelBuckets]]
    ) -> [String: ModelBuckets] {
        if let exact = buckets[sessionId] { return exact }
        if let prefixMatch = buckets.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return [:]
    }

}
