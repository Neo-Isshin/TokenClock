import Foundation
import SQLite3

/// 从 Antigravity CLI 本地 SQLite 数据库读取 token 使用数据
/// 数据库位置: ~/.gemini/antigravity-cli/conversations/{session-uuid}.db
/// 数据结构: steps.step_payload (protobuf blob)
///   → field 5 (step wrapper)
///     → field 9 (telemetry event block)
///       → field 2: input_token_count
///       → field 3: output_token_count
///       → field 5: cached_content_token_count
///       → field 9: thoughts_token_count
///       → field 10: tool_token_count
///       → field 11: tracking_id (用于去重)
final class AntigravityUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var seenTrackingIds: Set<String> = []
    private var lastScanTime: Date = .distantPast

    private let agHome: String

    init() {
        agHome = PathConfig.antigravityHome()
    }

    func fullScan() {
        dailyData.removeAll(); hourlyData.removeAll()
        dailyCache.removeAll(); recentEntries = []
        seenTrackingIds = []
        lastScanTime = .distantPast
        scanAllDatabases()
    }

    func incrementalScan() { scanAllDatabases() }

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
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanAllDatabases() {
        let convDir = agHome + "/conversations"
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: convDir, isDirectory: &isDir), isDir.boolValue else { return }
        guard let files = try? fm.contentsOfDirectory(atPath: convDir) else { return }

        let now = Date()
        var anyChanged = false

        for file in files where file.hasSuffix(".db") {
            let dbPath = convDir + "/" + file
            guard let attrs = try? fm.attributesOfItem(atPath: dbPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if modDate <= lastScanTime { continue }
            anyChanged = true
            scanDatabase(dbPath: dbPath)
        }

        if anyChanged { lastScanTime = now }
    }

    private func scanDatabase(dbPath: String) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = "SELECT step_payload FROM steps WHERE step_payload IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let blobPtr = sqlite3_column_blob(stmt, 0)
            let blobLen = sqlite3_column_bytes(stmt, 0)
            guard blobLen > 0, let blobPtr = blobPtr else { continue }
            let data = Data(bytes: blobPtr, count: Int(blobLen))
            processStepPayload(data)
        }
    }

    // MARK: - Protobuf 解析

    private func processStepPayload(_ data: Data) {
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

            let inputTokens = varintValue(tel, field: 2)
            let outputTokens = varintValue(tel, field: 3)
            let cacheTokens = varintValue(tel, field: 5)
            let thoughtTokens = varintValue(tel, field: 9)
            let toolTokens = varintValue(tel, field: 10)
            let total = inputTokens + outputTokens + cacheTokens + thoughtTokens + toolTokens
            guard total > 0 else { continue }

            // 数据库文件名是 session UUID，没有时间戳信息
            // 使用当前时间作为近似（Antigravity 数据库本身没有逐条时间戳）
            let now = Date()
            let dateKey = DateHelper.dateKey(from: now)
            let hourKey = DateHelper.hourKey(from: now)

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
            recentEntries.append(RecentEntry(timestamp: now, tokens: total))
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

    func todaySessions() -> [SessionInfo] {
        let convDir = agHome + "/conversations"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: convDir) else { return [] }

        var results: [SessionInfo] = []
        let today = DateHelper.todayKey()

        for file in files where file.hasSuffix(".db") {
            let dbPath = convDir + "/" + file
            var db: OpaquePointer?
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }

            guard let attrs = try? fm.attributesOfItem(atPath: dbPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  DateHelper.dateKey(from: modDate) == today else { continue }

            var sessionTokens = 0
            var sessionMsgs = 0
            let query = "SELECT step_payload FROM steps WHERE step_payload IS NOT NULL"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let blobPtr = sqlite3_column_blob(stmt, 0)
                let blobLen = sqlite3_column_bytes(stmt, 0)
                guard blobLen > 0, let blobPtr = blobPtr else { continue }
                let data = Data(bytes: blobPtr, count: Int(blobLen))
                guard let outer = parseProtobufFields(data),
                      let f5Field = outer.first(where: { $0.field == 5 && $0.wireType == 2 }),
                      let f5Data = f5Field.value as? Data,
                      let f5 = parseProtobufFields(f5Data) else { continue }
                for field in f5 where field.field == 9 && field.wireType == 2 {
                    guard let telData = field.value as? Data,
                          let tel = parseProtobufFields(telData),
                          let trackIdData = tel.first(where: { $0.field == 11 })?.value as? Data,
                          let trackIdStr = String(data: trackIdData, encoding: .utf8) else { continue }
                    let inputT = varintValue(tel, field: 2)
                    let outputT = varintValue(tel, field: 3)
                    let cacheT = varintValue(tel, field: 5)
                    let thoughtT = varintValue(tel, field: 9)
                    let toolT = varintValue(tel, field: 10)
                    let total = inputT + outputT + cacheT + thoughtT + toolT
                    guard total > 0 else { continue }
                    sessionTokens += total
                    sessionMsgs += 1
                    _ = trackIdStr
                }
            }

            guard sessionTokens > 0 else { continue }
            let sessionId = String(file.dropLast(".db".count))
            results.append(SessionInfo(
                rawId: sessionId, displayName: SessionIdDisplay.format(sessionId), detail: nil,
                todayTokens: sessionTokens, todayMessages: sessionMsgs, isActive: true
            ))
        }
        return results.sorted { $0.todayTokens > $1.todayTokens }
    }
}
