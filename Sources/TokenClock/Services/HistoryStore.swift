import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

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

    init() {
        let path = Self.dbPath()
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
                PRIMARY KEY (date_key, tool_name)
            );
            CREATE INDEX IF NOT EXISTS idx_date ON daily_snapshots(date_key);
        """, nil, nil, nil)
        // 旧库迁移：CREATE TABLE IF NOT EXISTS 不会给已存在的表补列，
        // 探测 sessions_json 缺失则 ALTER ADD COLUMN（DEFAULT '[]' 让旧行 session 为空）。
        migrateSessionsColumnIfNeeded()
    }

    // MARK: - 迁移 / session 编解码

    /// 旧库 daily_snapshots 无 sessions_json 列时补列（幂等：已有则跳过，避免 duplicate column）。
    private func migrateSessionsColumnIfNeeded() {
        guard let db = db else { return }
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(daily_snapshots)", -1, &probe, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(probe) }
        var hasCol = false
        while sqlite3_step(probe) == SQLITE_ROW {
            if let p = sqlite3_column_text(probe, 1), String(cString: p) == "sessions_json" {
                hasCol = true
                break
            }
        }
        if !hasCol {
            sqlite3_exec(db, "ALTER TABLE daily_snapshots ADD COLUMN sessions_json TEXT NOT NULL DEFAULT '[]'", nil, nil, nil)
        }
    }

    /// [SessionSnapshot] → JSON 字符串（空或失败回退 "[]"，保证 NOT NULL）。
    static func encodeSessions(_ sessions: [SessionSnapshot]) -> String {
        guard !sessions.isEmpty else { return "[]" }
        let arr: [[String: Any]] = sessions.map {
            ["id": $0.id, "displayName": $0.displayName,
             "tokens": $0.tokens, "messages": $0.messages,
             "isActive": $0.isActive] as [String: Any]
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
            return DaySnapshot.Tool.Session(id: id, displayName: displayName,
                                            tokens: tokens, messages: messages, isActive: isActive)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    static func dbPath() -> URL {
#if os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share", isDirectory: true).path
        return URL(fileURLWithPath: dataHome, isDirectory: true)
            .appendingPathComponent("tokenclock", isDirectory: true)
            .appendingPathComponent("history.sqlite")
#else
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("TokenClock", isDirectory: true)
            .appendingPathComponent("history.sqlite")
#endif
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
                  (date_key, tool_name, tokens, messages, cache_rate, is_active, settled_at, sessions_json)
                  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
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
                if sqlite3_step(ins) != SQLITE_DONE {
                    print("[HistoryStore] insert failed for \(s.name): \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }
    }

    /// 查询过去 N 天(返回数据库里实际存在的 date_key,缺数据日由 caller 补 0)
    /// 返回按 date_key 降序的 [DaySnapshot]
    func queryRecent(days: Int) -> [DaySnapshot] {
        ioQueue.sync {
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            // 取最近 N 个不同 date_key 下的所有 (tool, tokens, messages, cacheRate, isActive) 行
            let sql = """
                SELECT date_key, tool_name, tokens, messages, cache_rate, is_active, sessions_json
                FROM daily_snapshots
                WHERE date_key IN (
                  SELECT DISTINCT date_key FROM daily_snapshots
                  ORDER BY date_key DESC LIMIT ?1
                )
                ORDER BY date_key DESC, tool_name ASC
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(days))

            struct Row {
                let name: String
                let tokens: Int
                let messages: Int
                let cacheRate: Double
                let isActive: Bool
                let sessions: [DaySnapshot.Tool.Session]
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
                byDate[dateKey, default: []].append(
                    Row(name: name, tokens: tokens, messages: messages,
                        cacheRate: cacheRate, isActive: isActive,
                        sessions: Self.decodeSessions(sessionsJSON))
                )
            }
            return byDate.map { (date, rows) -> DaySnapshot in
                let tools = rows.map { r in
                    DaySnapshot.Tool(name: r.name, tokens: r.tokens, messages: r.messages,
                                      cacheRate: r.cacheRate, isActive: r.isActive,
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
        let sessions: [Session]

        struct Session {
            let id: String
            let displayName: String
            let tokens: Int
            let messages: Int
            let isActive: Bool
        }
    }
}
