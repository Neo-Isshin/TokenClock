import Foundation
import SQLite3

/// 日结历史持久化：每天 00:01 抓 viewModel.tools 快照写入 SQLite
/// 路径：~/Library/Application Support/TokenClock/history.sqlite
/// API 端点：GET /api/history?days=N
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let ioQueue = DispatchQueue(label: "com.tokenclock.history.io", qos: .utility)

    // SQLite 的 SQLITE_TRANSIENT 标记,让 bind_text 复制字符串(我们传 String 临时变量)
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    init(path overridePath: URL? = nil) {
        let path = overridePath ?? Self.dbPath()
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            print("[HistoryStore] open failed: \(msg)")
            return
        }
        // WAL 模式让 read 不会被 write 阻塞;fullmutex 让多线程 sqlite3_* 调用串行化
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS daily_snapshots (
                date_key      TEXT NOT NULL,
                tool_name     TEXT NOT NULL,
                tokens        INTEGER NOT NULL,
                messages      INTEGER NOT NULL,
                cache_rate    REAL NOT NULL DEFAULT 0,
                is_active     INTEGER NOT NULL DEFAULT 0,
                settled_at    TEXT NOT NULL,
                sessions_json TEXT NOT NULL DEFAULT '[]',
                cache_read_tokens INTEGER NOT NULL DEFAULT -1,
                cost_value    REAL NOT NULL DEFAULT 0,
                cost_complete INTEGER NOT NULL DEFAULT 0,
                cost_available INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date_key, tool_name)
            );
            CREATE INDEX IF NOT EXISTS idx_date ON daily_snapshots(date_key);
        """, nil, nil, nil)
        // 旧库迁移：CREATE TABLE IF NOT EXISTS 不会给已存在的表补列，
        // 探测 sessions_json 缺失则 ALTER ADD COLUMN（DEFAULT '[]' 让旧行 session 为空）。
        migrateColumnsIfNeeded()
    }

    // MARK: - 迁移 / session 编解码

    /// 旧库 daily_snapshots 无 sessions_json 列时补列（幂等：已有则跳过，避免 duplicate column）。
    private func migrateColumnsIfNeeded() {
        guard let db = db else { return }
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(daily_snapshots)", -1, &probe, nil) == SQLITE_OK else { return }
        var columns: Set<String> = []
        while sqlite3_step(probe) == SQLITE_ROW {
            if let p = sqlite3_column_text(probe, 1) { columns.insert(String(cString: p)) }
        }
        sqlite3_finalize(probe)
        if !columns.contains("sessions_json") {
            sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN sessions_json TEXT NOT NULL DEFAULT '[]'", nil, nil, nil)
        }
        if !columns.contains("cache_read_tokens") { sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT -1", nil, nil, nil) }
        if !columns.contains("cost_value") { sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN cost_value REAL NOT NULL DEFAULT 0", nil, nil, nil) }
        if !columns.contains("cost_complete") { sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN cost_complete INTEGER NOT NULL DEFAULT 0", nil, nil, nil) }
        if !columns.contains("cost_available") { sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN cost_available INTEGER NOT NULL DEFAULT 0", nil, nil, nil) }
    }

    /// [SessionSnapshot] → JSON 字符串（空或失败回退 "[]"，保证 NOT NULL）。
    static func encodeSessions(_ sessions: [SessionSnapshot]) -> String {
        guard !sessions.isEmpty else { return "[]" }
        let arr: [[String: Any]] = sessions.map {
            var value: [String: Any] = [
                "id": $0.id, "displayName": $0.displayName,
                "tokens": $0.tokens, "messages": $0.messages,
                "isActive": $0.isActive, "costValue": $0.cost.value,
                "costComplete": $0.cost.complete, "costAvailable": $0.cost.available,
            ]
            if let model = $0.model { value["model"] = model }
            if let cache = $0.cacheReadTokens { value["cacheReadTokens"] = cache }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// JSON 字符串 → [DaySnapshot.Tool.Session]（解析失败容错为空）。
    static func decodeSessions(_ json: String) -> [DaySnapshot.Tool.Session] {
        guard !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d -> DaySnapshot.Tool.Session? in
            guard let id = d["id"] as? String,
                  let displayName = d["displayName"] as? String,
                  let tokens = (d["tokens"] as? NSNumber)?.intValue,
                  let messages = (d["messages"] as? NSNumber)?.intValue else { return nil }
            let isActive = d["isActive"] as? Bool ?? false
            let hasCost = d["costAvailable"] != nil || d["costValue"] != nil
            let cost = hasCost ? CostEstimate(
                value: (d["costValue"] as? NSNumber)?.doubleValue ?? 0,
                complete: d["costComplete"] as? Bool ?? false,
                available: d["costAvailable"] as? Bool ?? false
            ) : .unavailable
            return DaySnapshot.Tool.Session(id: id, displayName: displayName,
                                            tokens: tokens, messages: messages, isActive: isActive,
                                            model: d["model"] as? String, cost: cost,
                                            cacheReadTokens: (d["cacheReadTokens"] as? NSNumber)?.intValue)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    static func dbPath() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("TokenClock", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// 写入或覆盖一个 date_key 的所有工具快照(幂等:重跑只留最新)
    func upsertDay(dateKey: String, snapshots: [ToolSnapshot]) {
        ioQueue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

            // 1. 先删这一天的(幂等)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM daily_snapshots WHERE date_key = ?1", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_text(del, 1, dateKey, -1, Self.SQLITE_TRANSIENT)
                sqlite3_step(del)
                sqlite3_finalize(del)
            }

            // 2. 批量插入
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT INTO daily_snapshots
                  (date_key, tool_name, tokens, messages, cache_rate, is_active, settled_at,
                   sessions_json, cache_read_tokens, cost_value, cost_complete, cost_available)
                  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """, -1, &ins, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(ins) }

            let now = ISO8601DateFormatter().string(from: Date())
            for s in snapshots {
                sqlite3_reset(ins)
                sqlite3_bind_text(ins, 1, dateKey, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(ins, 2, s.name, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(ins, 3, Int64(s.tokens))
                sqlite3_bind_int64(ins, 4, Int64(s.messages))
                sqlite3_bind_double(ins, 5, s.cacheRate)
                sqlite3_bind_int(ins, 6, s.isActive ? 1 : 0)
                sqlite3_bind_text(ins, 7, now, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(ins, 8, Self.encodeSessions(s.sessions), -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(ins, 9, Int64(s.cacheReadTokens ?? -1))
                sqlite3_bind_double(ins, 10, s.cost.value)
                sqlite3_bind_int(ins, 11, s.cost.complete ? 1 : 0)
                sqlite3_bind_int(ins, 12, s.cost.available ? 1 : 0)
                if sqlite3_step(ins) != SQLITE_DONE {
                    print("[HistoryStore] insert failed for \(s.name): \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }
    }

    /// 查询过去 N 天(返回数据库里实际存在的 date_key,缺数据日由 caller 补 0)
    /// 返回按 date_key 降序的 [DaySnapshot]
    func queryRecent(days: Int) -> [DaySnapshot] {
        query(whereClause: """
            WHERE date_key IN (
              SELECT DISTINCT date_key FROM daily_snapshots
              ORDER BY date_key DESC LIMIT ?1
            )
            """, bind: { sqlite3_bind_int($0, 1, Int32(max(1, days))) })
    }

    func query(from startDateKey: String, through endDateKey: String) -> [DaySnapshot] {
        query(whereClause: "WHERE date_key >= ?1 AND date_key <= ?2", bind: {
            sqlite3_bind_text($0, 1, startDateKey, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text($0, 2, endDateKey, -1, Self.SQLITE_TRANSIENT)
        })
    }

    private func query(whereClause: String, bind: (OpaquePointer?) -> Void) -> [DaySnapshot] {
        ioQueue.sync {
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            // 取最近 N 个不同 date_key 下的所有 (tool, tokens, messages, cacheRate, isActive) 行
            let sql = """
                SELECT date_key, tool_name, tokens, messages, cache_rate, is_active, sessions_json,
                       cache_read_tokens, cost_value, cost_complete, cost_available
                FROM daily_snapshots
                \(whereClause)
                ORDER BY date_key DESC, tool_name ASC
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)

            struct Row {
                let name: String
                let tokens: Int
                let messages: Int
                let cacheRate: Double
                let isActive: Bool
                let sessions: [DaySnapshot.Tool.Session]
                let cacheReadTokens: Int?
                let cost: CostEstimate
            }
            var byDate: [String: [Row]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateKey = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let tokens = Int(sqlite3_column_int64(stmt, 2))
                let messages = Int(sqlite3_column_int64(stmt, 3))
                let cacheRate = sqlite3_column_double(stmt, 4)
                let isActive = sqlite3_column_int(stmt, 5) != 0
                let sessionsJSON = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "[]"
                let rawCacheRead = Int(sqlite3_column_int64(stmt, 7))
                let cost = CostEstimate(value: sqlite3_column_double(stmt, 8),
                                        complete: sqlite3_column_int(stmt, 9) != 0,
                                        available: sqlite3_column_int(stmt, 10) != 0)
                byDate[dateKey, default: []].append(
                    Row(name: name, tokens: tokens, messages: messages,
                        cacheRate: cacheRate, isActive: isActive,
                        sessions: Self.decodeSessions(sessionsJSON),
                        cacheReadTokens: rawCacheRead >= 0 ? rawCacheRead : nil,
                        cost: cost)
                )
            }
            return byDate.map { (date, rows) -> DaySnapshot in
                let tools = rows.map { r in
                    DaySnapshot.Tool(name: r.name, tokens: r.tokens, messages: r.messages,
                                      cacheRate: r.cacheRate, isActive: r.isActive,
                                      cost: r.cost, cacheReadTokens: r.cacheReadTokens,
                                      sessions: r.sessions)
                }
                return DaySnapshot(
                    date: date,
                    totalTokens: tools.reduce(0) { $0 + $1.tokens },
                    totalMessages: tools.reduce(0) { $0 + $1.messages },
                    tools: tools
                )
            }.sorted { $0.date > $1.date }
        }
    }
}

struct DaySnapshot {
    let date: String
    let totalTokens: Int
    let totalMessages: Int
    let tools: [Tool]

    struct Tool {
        let name: String
        let tokens: Int
        let messages: Int
        let cacheRate: Double
        let isActive: Bool
        let cost: CostEstimate
        let cacheReadTokens: Int?
        let sessions: [Session]

        struct Session {
            let id: String
            let displayName: String
            let tokens: Int
            let messages: Int
            let isActive: Bool
            let model: String?
            let cost: CostEstimate
            let cacheReadTokens: Int?
        }
    }
}
