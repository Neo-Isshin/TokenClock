import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

/// 从 Antigravity 本地 SQLite 数据库读取 token 使用数据（CLI + IDE + 主应用）
/// 数据库位置:
///   ~/.gemini/antigravity-cli/conversations/{session-uuid}.db   (Antigravity CLI)
///   ~/.gemini/antigravity-ide/conversations/{session-uuid}.db   (Antigravity IDE)
///   ~/.gemini/antigravity/conversations/{session-uuid}.db       (Antigravity 主应用)
/// 三者 schema 与 protobuf 遥测格式同源，统一扫描、用全局 tracking_id 去重。
///
/// 两个 protobuf 列配合读取：
///   - steps.metadata (protobuf blob) → 时间戳
///       outer.field 1 (12B wrapper)
///         inner.field 1 (varint) = Unix seconds
///         inner.field 2 (varint) = nanoseconds
///   - steps.step_payload (protobuf blob) → token telemetry
///       outer.field 5 (step wrapper)
///         inner.field 9 (telemetry block)
///           field 1: input_tokens (new, non-cached)
///           field 2: output_tokens
///           field 3: cache_read_tokens
///           field 5: total_prompt_tokens (cumulative, DO NOT add — would double-count)
///           field 9: thoughts_token_count
///           field 10: tool_token_count
///           field 11: tracking_id (用于去重)
final class AntigravityUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var dailyModelBuckets: [String: [String: ModelBuckets]] = [:]
    private var recentEntries: [RecentEntry] = []
    private var seenTrackingIds: Set<String> = []
    private var lastScanTime: Date = .distantPast

    private let conversationDirs: [String]

    init() {
        conversationDirs = PathConfig.antigravityConversationDirs()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        dailyCache.removeAll(); recentEntries = []
        dailyModelBuckets.removeAll()
        seenTrackingIds = []
        lastScanTime = .distantPast
        scanAllDatabases()
    }

    func incrementalScan() { scanAllDatabases() }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
        let total = d?.tokens ?? 0
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

    func todayModelBuckets() -> [String: ModelBuckets] {
        dailyModelBuckets[DateHelper.todayKey()] ?? [:]
    }

    func todayCost() -> CostEstimate {
        PricingService.shared.cost(of: todayModelBuckets())
    }

    func todayCacheReadTokens() -> Int {
        dailyCache[DateHelper.todayKey()] ?? 0
    }

    // MARK: - 内部

    private func scanAllDatabases() {
        let fm = FileManager.default
        let now = Date()
        var anyChanged = false

        for convDir in conversationDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: convDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: convDir) else { continue }

            for file in files where file.hasSuffix(".db") {
                let dbPath = convDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: dbPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                if modDate <= lastScanTime { continue }
                anyChanged = true
                scanDatabase(dbPath: dbPath)
            }
        }

        if anyChanged { lastScanTime = now }
    }

    private func scanDatabase(dbPath: String) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let model = sessionModel(db: db)

        // 同时取 step_payload（token telemetry）和 metadata（时间戳）
        let query = "SELECT step_payload, metadata FROM steps WHERE step_payload IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let spPtr = sqlite3_column_blob(stmt, 0)
            let spLen = sqlite3_column_bytes(stmt, 0)
            guard spLen > 0, let spPtr = spPtr else { continue }
            let stepPayload = Data(bytes: spPtr, count: Int(spLen))

            // metadata 可能为 NULL
            var timestamp: Date? = nil
            if let metaPtr = sqlite3_column_blob(stmt, 1) {
                let metaLen = sqlite3_column_bytes(stmt, 1)
                if metaLen > 0 {
                    let metaBlob = Data(bytes: metaPtr, count: Int(metaLen))
                    timestamp = parseTimestamp(from: metaBlob)
                }
            }

            processStepPayload(stepPayload, timestamp: timestamp, model: model)
        }
    }

    // MARK: - Protobuf 解析

    /// 从 metadata blob 解析时间戳：outer.field 1 → inner.field 1 (Unix seconds)
    private func parseTimestamp(from metadata: Data) -> Date? {
        guard let outer = parseProtobufFields(metadata) else { return nil }
        guard let wrapperField = outer.first(where: { $0.field == 1 && $0.wireType == 2 }),
              let wrapperData = wrapperField.value as? Data,
              let inner = parseProtobufFields(wrapperData) else { return nil }
        guard let secsField = inner.first(where: { $0.field == 1 && $0.wireType == 0 }),
              let secs = secsField.value as? UInt64, secs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    private func processStepPayload(_ data: Data, timestamp: Date?, model: String) {
        guard let outer = parseProtobufFields(data) else { return }
        // field 5: step wrapper
        guard let f5Field = outer.first(where: { $0.field == 5 && $0.wireType == 2 }),
              let f5Data = f5Field.value as? Data,
              let f5 = parseProtobufFields(f5Data) else { return }
        // field 9: telemetry block
        for field in f5 where field.field == 9 && field.wireType == 2 {
            guard let telData = field.value as? Data,
                  let tel = parseProtobufFields(telData) else { continue }
            // field 11: tracking ID (用于去重)
            guard let trackId = tel.first(where: { $0.field == 11 })?.value as? Data else { continue }
            let trackIdStr = String(data: trackId, encoding: .utf8) ?? ""
            guard !trackIdStr.isEmpty, !seenTrackingIds.contains(trackIdStr) else { continue }
            seenTrackingIds.insert(trackIdStr)

            // Token 字段映射（已根据实际 protobuf 数据校准）：
            //   field 1: input tokens (new, non-cached)
            //   field 2: output tokens
            //   field 3: cache read tokens
            //   field 9: thoughts tokens
            //   field 10: tool tokens
            //   field 5 是累计总 prompt（含历史），不要加入，否则会双重计算
            let inputTokens = varintValue(tel, field: 1)
            let outputTokens = varintValue(tel, field: 2)
            let cacheTokens = varintValue(tel, field: 3)
            let thoughtTokens = varintValue(tel, field: 9)
            let toolTokens = varintValue(tel, field: 10)
            let total = TokenAccounting.separateCacheFields(
                input: inputTokens, output: outputTokens, additional: [thoughtTokens, toolTokens]
            )
            guard total > 0 else { continue }

            // 使用 metadata 提供的真实时间戳；缺失时退回到当前时间
            let date = timestamp ?? Date()
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

            dailyCache[dateKey, default: 0] += cacheTokens
            dailyModelBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(
                ModelBuckets(
                    input: inputTokens,
                    output: outputTokens + thoughtTokens + toolTokens,
                    cacheRead: cacheTokens
                )
            )
            recentEntries.append(RecentEntry(timestamp: date, tokens: total))
            // L4: 限制 recentEntries 增长，只保留 active 窗口 3 倍内的条目
            if recentEntries.count > 64 {
                let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
                recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
            }
        }
    }

    /// 解析 protobuf wire format 字段列表
    private func parseProtobufFields(_ data: Data) -> [ProtobufField]? {
        var fields: [ProtobufField] = []
        var pos = 0
        let bytes = [UInt8](data)

        while pos < bytes.count {
            guard let (key, newPos) = parseVarint(bytes, pos) else { return nil }
            pos = newPos
            let fieldNum = Int(key >> 3)
            let wireType = Int(key & 0x7)

            switch wireType {
            case 0: // varint
                guard let (val, np) = parseVarint(bytes, pos) else { return nil }
                pos = np
                fields.append(ProtobufField(field: fieldNum, wireType: wireType, value: val))
            case 1: // 64-bit
                guard pos + 8 <= bytes.count else { return nil }
                let val = Data(bytes[pos..<pos+8])
                pos += 8
                fields.append(ProtobufField(field: fieldNum, wireType: wireType, value: val))
            case 2: // length-delimited
                guard let (length, np) = parseVarint(bytes, pos) else { return nil }
                pos = np
                guard pos + Int(length) <= bytes.count else { return nil }
                let val = Data(bytes[pos..<pos+Int(length)])
                pos += Int(length)
                fields.append(ProtobufField(field: fieldNum, wireType: wireType, value: val))
            case 5: // 32-bit
                guard pos + 4 <= bytes.count else { return nil }
                let val = Data(bytes[pos..<pos+4])
                pos += 4
                fields.append(ProtobufField(field: fieldNum, wireType: wireType, value: val))
            default:
                return fields
            }
        }
        return fields
    }

    private struct ProtobufField {
        let field: Int
        let wireType: Int
        let value: Any // Int (varint) 或 Data (length-delimited)
    }

    private func parseVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var pos = start
        while pos < bytes.count {
            let b = bytes[pos]
            result |= UInt64(b & 0x7F) << shift
            pos += 1
            if b < 0x80 { return (result, pos) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private func varintValue(_ fields: [ProtobufField], field: Int) -> Int {
        for f in fields where f.field == field {
            if let val = f.value as? UInt64 { return Int(val) }
        }
        return 0
    }

    // MARK: - 今日活跃 Session 列表

    /// 会话目录 → 来源标签：antigravity-cli=CLI / antigravity-ide=IDE / antigravity(主应用)=App
    private static func sourceLabel(for convDir: String) -> String? {
        if convDir.hasSuffix("/antigravity-cli/conversations") { return "CLI" }
        if convDir.hasSuffix("/antigravity-ide/conversations") { return "IDE" }
        if convDir.hasSuffix("/antigravity/conversations") { return "App" }
        return nil
    }

    /// Antigravity executor metadata wire path:
    /// root.field 10 -> runtime.field 1 -> config.field 28 (selected model identifier).
    /// This is shared by CLI, IDE and the main app databases.
    func decodeModelFromExecutorMetadata(_ data: Data) -> String? {
        guard let root = parseProtobufFields(data) else { return nil }
        for runtimeField in root where runtimeField.field == 10 && runtimeField.wireType == 2 {
            guard let runtimeData = runtimeField.value as? Data,
                  let runtime = parseProtobufFields(runtimeData) else { continue }
            for configField in runtime where configField.field == 1 && configField.wireType == 2 {
                guard let configData = configField.value as? Data,
                      let config = parseProtobufFields(configData) else { continue }
                for modelField in config where modelField.field == 28 && modelField.wireType == 2 {
                    guard let bytes = modelField.value as? Data,
                          let raw = String(data: bytes, encoding: .utf8),
                          let model = ModelNormalizer.normalize(raw) else { continue }
                    return model
                }
            }
        }
        return nil
    }

    /// Prefer the precise protobuf field. The byte scan remains a compatibility fallback for
    /// older Antigravity database revisions; the generic `gemini` fallback prevents valid
    /// Antigravity traffic from being mislabeled as Unknown.
    private func sessionModel(db: OpaquePointer?) -> String {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "SELECT data FROM executor_metadata WHERE data IS NOT NULL ORDER BY idx", -1, &stmt, nil
        ) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let pointer = sqlite3_column_blob(stmt, 0) else { continue }
                let length = sqlite3_column_bytes(stmt, 0)
                guard length > 0 else { continue }
                if let model = decodeModelFromExecutorMetadata(
                    Data(bytes: pointer, count: Int(length))
                ) {
                    return model
                }
            }
        }

        let candidates = ["SELECT data FROM gen_metadata", "SELECT data FROM executor_metadata"]
        for sql in candidates {
            var counts: [String: Int] = [:]
            var fallbackStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &fallbackStatement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(fallbackStatement) }
            while sqlite3_step(fallbackStatement) == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(fallbackStatement, 0),
                      sqlite3_column_bytes(fallbackStatement, 0) > 0 else { continue }
                let data = Data(bytes: ptr, count: Int(sqlite3_column_bytes(fallbackStatement, 0)))
                // 宽松解码（无效字节替换为 U+FFFD，不影响 ASCII 模型名的匹配）
                let text = String(decoding: data, as: UTF8.self)
                let range = NSRange(text.startIndex..., in: text)
                for match in Self.geminiIdPattern.matches(in: text, range: range) {
                    if let r = Range(match.range, in: text) {
                        counts[String(text[r]), default: 0] += 1
                    }
                }
            }
            if let dominant = counts.max(by: { $0.value < $1.value })?.key {
                return dominant
            }
        }
        return "gemini"
    }

    /// gemini 模型 ID 形态：gemini-3.7-flash / gemini-3-pro-preview 等
    private static let geminiIdPattern = try! NSRegularExpression(pattern: "gemini-[A-Za-z0-9._-]+")

    func todaySessions() -> [SessionInfo] {
        let fm = FileManager.default

        var results: [SessionInfo] = []
        let today = DateHelper.todayKey()

        for convDir in conversationDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: convDir) else { continue }

            for file in files where file.hasSuffix(".db") {
                let dbPath = convDir + "/" + file
                var db: OpaquePointer?
                guard sqlite3_open(dbPath, &db) == SQLITE_OK else { continue }
                defer { sqlite3_close(db) }

                // 粗过滤：文件 modDate 必须是今天（避免扫历史库）
                guard let attrs = try? fm.attributesOfItem(atPath: dbPath),
                      let modDate = attrs[.modificationDate] as? Date,
                      DateHelper.dateKey(from: modDate) == today else { continue }

                var sessionTokens = 0
                var sessionMsgs = 0
                var sessionBuckets = ModelBuckets()
                let model = sessionModel(db: db)
                // 同时取 step_payload（telemetry）和 metadata（时间戳）
                let query = "SELECT step_payload, metadata FROM steps WHERE step_payload IS NOT NULL"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let blobPtr = sqlite3_column_blob(stmt, 0)
                    let blobLen = sqlite3_column_bytes(stmt, 0)
                    guard blobLen > 0, let blobPtr = blobPtr else { continue }
                    let data = Data(bytes: blobPtr, count: Int(blobLen))

                    // 从 metadata 取时间戳，按行级时间过滤
                    var rowDate: Date? = nil
                    if let metaPtr = sqlite3_column_blob(stmt, 1) {
                        let metaLen = sqlite3_column_bytes(stmt, 1)
                        if metaLen > 0 {
                            let metaBlob = Data(bytes: metaPtr, count: Int(metaLen))
                            rowDate = parseTimestamp(from: metaBlob)
                        }
                    }
                    // 如果文件是今天但具体行不是今天（历史 session 在今天被 touch），跳过
                    if let rd = rowDate, DateHelper.dateKey(from: rd) != today { continue }

                    guard let outer = parseProtobufFields(data),
                          let f5Field = outer.first(where: { $0.field == 5 && $0.wireType == 2 }),
                          let f5Data = f5Field.value as? Data,
                          let f5 = parseProtobufFields(f5Data) else { continue }
                    for field in f5 where field.field == 9 && field.wireType == 2 {
                        guard let telData = field.value as? Data,
                              let tel = parseProtobufFields(telData) else { continue }
                        // 字段映射与 processStepPayload 保持一致（已校准）
                        let inputT = varintValue(tel, field: 1)
                        let outputT = varintValue(tel, field: 2)
                        let cacheT = varintValue(tel, field: 3)
                        let thoughtT = varintValue(tel, field: 9)
                        let toolT = varintValue(tel, field: 10)
                        let total = TokenAccounting.separateCacheFields(
                            input: inputT, output: outputT, additional: [thoughtT, toolT]
                        )
                        guard total > 0 else { continue }
                        sessionTokens += total
                        sessionMsgs += 1
                        sessionBuckets.merge(ModelBuckets(
                            input: inputT,
                            output: outputT + thoughtT + toolT,
                            cacheRead: cacheT
                        ))
                    }
                }

                guard sessionTokens > 0 else { continue }
                let sessionId = String(file.dropLast(".db".count))
                results.append(SessionInfo(
                    rawId: sessionId, displayName: SessionIdDisplay.format(sessionId), detail: nil,
                    todayTokens: sessionTokens, todayMessages: sessionMsgs, isActive: true,
                    source: Self.sourceLabel(for: convDir), model: model,
                    todayCost: PricingService.shared.cost(of: [model: sessionBuckets]),
                    cacheReadTokens: sessionBuckets.cacheRead
                ))
            }
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
