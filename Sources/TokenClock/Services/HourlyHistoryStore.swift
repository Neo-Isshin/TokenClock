import Foundation
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

struct HourlyUsagePart: Codable, Sendable {
    var tokens = 0
    var messages = 0
    var cache = 0
    var missingCache = 0
    var pricedMessages = 0
    var missingPrice = 0
    var costValue = 0.0
    var cost: CostEstimate { CostEstimate(value: max(0,costValue), complete: missingPrice == 0, available: pricedMessages > 0) }
}
extension HourlyUsage {
    /// Called only for records with a genuine event timestamp, never mtime/session-total fallbacks.
    mutating func recordMetadata(tokens: Int, messages: Int = 1, cache: Int?, model: String?,
                                 cost: CostEstimate = .unavailable) {
        let key = ModelNormalizer.normalize(model) ?? "Unknown"
        var part = parts[key] ?? HourlyUsagePart()
        part.tokens += max(0,tokens); part.messages += max(0,messages)
        if let cache { part.cache += max(0,cache) } else { part.missingCache += messages }
        if cost.available && cost.value.isFinite && cost.value >= 0 {
            part.costValue += cost.value; part.pricedMessages += messages
            if !cost.complete { part.missingPrice += messages }
        }
        else { part.missingPrice += messages }
        parts[key] = part
    }
    mutating func mergeMetadata(_ other: HourlyUsage, subtract: Bool = false) {
        let sign = subtract ? -1 : 1
        for (key,value) in other.parts {
            var part = parts[key] ?? HourlyUsagePart()
            part.tokens += sign * value.tokens; part.messages += sign * value.messages
            part.cache += sign * value.cache; part.missingCache += sign * value.missingCache
            part.pricedMessages += sign * value.pricedMessages; part.missingPrice += sign * value.missingPrice
            part.costValue += Double(sign) * value.costValue
            if part.messages <= 0 && part.tokens <= 0 && part.cache <= 0 { parts[key] = nil }
            else { parts[key] = part }
        }
    }
    func historyTool(name: String) -> DaySnapshot.Tool {
        let values = parts.values
        let tokens = values.reduce(0) { $0 + $1.tokens }
        let messages = values.reduce(0) { $0 + $1.messages }
        let cache = values.reduce(0) { $0 + $1.cache }
        let exactCache = values.allSatisfy { $0.missingCache == 0 }
        var cost = CostEstimate.unavailable
        for part in values { cost.merge(part.cost) }
        if values.contains(where: { $0.missingPrice > 0 }) { cost.complete = false }
        let sessions = parts.sorted { $0.key < $1.key }.map { name, part in
            DaySnapshot.Tool.Session(id: name, displayName: name, tokens: part.tokens, messages: part.messages,
                isActive: false, model: name == "Unknown" ? nil : name, cost: part.cost,
                cacheReadTokens: part.missingCache == 0 ? part.cache : nil)
        }
        return DaySnapshot.Tool(name: name, tokens: tokens, messages: messages,
            cacheRate: TokenAccounting.cacheReadShare(freshTokens: tokens, cacheRead: cache),
            isActive: false, cost: cost, cacheReadTokens: exactCache ? cache : nil, sessions: sessions)
    }
}

/// Separate durable event-hour data. Daily snapshots and old databases are never rewritten.
final class HourlyHistoryStore: @unchecked Sendable {
    static let shared = HourlyHistoryStore()
    static func saveCursor(_ cursor: [String: HourlyUsage], _ grok: [String: HourlyUsage]) {
        shared.replace(tool: "Cursor Agent", hours: cursor, force: true)
        shared.replace(tool: "Grok Bot", hours: grok, force: true)
    }
    static let updated = Notification.Name("TokenClock.hourlyHistoryUpdated")
    private var db: OpaquePointer?
    private let emitsUpdates: Bool
    private let queue = DispatchQueue(label: "com.tokenclock.hourly-history")
    private var savedAt: [String: Date] = [:]
    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    init(path: URL? = nil) {
        emitsUpdates = path == nil
        let file = path ?? HistoryStore.dbPath().deletingLastPathComponent().appendingPathComponent("hourly-history.sqlite")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS event_hours (hour_key TEXT NOT NULL, tool TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(hour_key,tool));", nil,nil,nil)
    }
    deinit { if let db { sqlite3_close(db) } }

    func replace(tool: String, hours: [String: HourlyUsage], force: Bool = false, now: Date = Date()) {
        let changed: Bool = queue.sync {
            guard let db, force || now.timeIntervalSince(savedAt[tool] ?? .distantPast) >= 60 else { return false }
            let cutoff = DateHelper.dateKey(from: Calendar.current.date(byAdding: .day, value: -AppConfig.History.retentionDays, to: now) ?? now)
            let rows = hours.filter { $0.key.count == 13 && $0.key >= cutoff && (0..<24).contains(Int($0.key.suffix(2)) ?? -1) && !$0.value.parts.isEmpty }
            guard !rows.isEmpty else { return false }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil,nil,nil) == SQLITE_OK else { return false }
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil,nil,nil) } }
            var delete: OpaquePointer?, insert: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM event_hours WHERE tool=?1 AND hour_key >= ?2 AND hour_key <= ?3", -1,&delete,nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "INSERT INTO event_hours VALUES (?1,?2,?3)", -1,&insert,nil) == SQLITE_OK else {
                sqlite3_finalize(delete); sqlite3_finalize(insert); return false
            }
            defer { sqlite3_finalize(delete); sqlite3_finalize(insert) }
            for day in Set(rows.keys.map { String($0.prefix(10)) }) {
                sqlite3_reset(delete)
                sqlite3_bind_text(delete,1,tool,-1,Self.transient)
                sqlite3_bind_text(delete,2,day+"-00",-1,Self.transient)
                sqlite3_bind_text(delete,3,day+"-23",-1,Self.transient)
                guard sqlite3_step(delete) == SQLITE_DONE else { return false }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for (key,value) in rows {
                guard let data = try? encoder.encode(value) else { return false }
                sqlite3_reset(insert)
                sqlite3_bind_text(insert,1,key,-1,Self.transient)
                sqlite3_bind_text(insert,2,tool,-1,Self.transient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(insert,3,$0.baseAddress,Int32(data.count),Self.transient) }
                guard sqlite3_step(insert) == SQLITE_DONE else { return false }
            }
            guard sqlite3_exec(db, "COMMIT", nil,nil,nil) == SQLITE_OK else { return false }
            committed = true; savedAt[tool] = now
            return true
        }
        if changed && emitsUpdates { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updated, object: nil) } }
    }

    func query(day: String) -> [DaySnapshot] {
        queue.sync {
            guard let db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT hour_key,tool,payload FROM event_hours WHERE hour_key >= ?1 AND hour_key <= ?2 ORDER BY hour_key,tool", -1,&statement,nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement,1,day+"-00",-1,Self.transient)
            sqlite3_bind_text(statement,2,day+"-23",-1,Self.transient)
            var values: [String: [DaySnapshot.Tool]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement,0), let name = sqlite3_column_text(statement,1),
                      let bytes = sqlite3_column_blob(statement,2) else { continue }
                let data = Data(bytes: bytes,count: Int(sqlite3_column_bytes(statement,2)))
                guard let hour = try? JSONDecoder().decode(HourlyUsage.self,from: data) else { continue }
                values[String(cString:key),default:[]].append(hour.historyTool(name:String(cString:name)))
            }
            return values.keys.sorted().map { key in
                let tools = values[key] ?? []
                return DaySnapshot(date:key,totalTokens:tools.reduce(0){$0+$1.tokens},
                    totalMessages:tools.reduce(0){$0+$1.messages},tools:tools)
            }
        }
    }
}

enum HourlyOverviewLabels {
    static var title: String {
        switch L10n.shared.language { case .en: return "Hourly Usage"; case .zhHans: return "每小时用量"; case .zhHant: return "每小時用量" }
    }
    static var partial: String {
        switch L10n.shared.language {
        case .en: return "Hourly data is partial: only saved, timestamped events are shown."
        case .zhHans: return "小时数据不完整：仅展示已保存且具有事件时间戳的记录。"
        case .zhHant: return "小時資料不完整：僅顯示已儲存且具有事件時間戳的記錄。"
        }
    }
    static func label(_ key: String) -> String {
        guard key.count == 13 else { return key }
        let hour = Int(key.suffix(2)) ?? 0
        return "\(key.prefix(10)) \(String(format: "%02d",hour)):00–\(String(format: "%02d",hour+1)):00"
    }
}
