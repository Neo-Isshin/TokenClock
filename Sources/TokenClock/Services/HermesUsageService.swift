import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

/// 从 Hermes Agent 本地 SQLite 数据库读取 token 使用数据
/// 数据库位置: ~/.hermes/state.db
/// 表结构: sessions (input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, started_at, message_count)
final class HermesUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []

    private let hermesHome: String
    private var lastScanTime: Date = .distantPast

    init() {
        hermesHome = PathConfig.hermesHome()
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        recentEntries = []
        lastScanTime = .distantPast
        scanDatabase()
    }

    func incrementalScan() { scanDatabase() }

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
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private var dbPath: String {
        hermesHome + "/state.db"
    }

    private func scanDatabase() {
        let dbFile = dbPath
        let walFile = dbFile + "-wal"
        var db: OpaquePointer?

        // SQLite WAL 模式下，新数据可能写入 -wal 文件而非主 db
        // 检查两者中较新的修改时间
        let fm = FileManager.default
        var newestMod: Date?
        for path in [dbFile, walFile] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                if newestMod == nil || modDate > newestMod! { newestMod = modDate }
            }
        }
        if let newest = newestMod, newest <= lastScanTime { return }

        // DB 有修改，需要先清空再重读（避免叠加重复计数）
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        recentEntries = []

        guard sqlite3_open(dbFile, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // 从 sessions 表读取所有 token 数据
        // started_at 是 Unix timestamp (REAL)
        let query = """
        SELECT started_at,
               input_tokens,
               output_tokens,
               cache_read_tokens,
               cache_write_tokens,
               message_count
        FROM sessions
        WHERE input_tokens > 0 OR output_tokens > 0
        ORDER BY started_at ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let today = DateHelper.todayKey()
        let now = Date()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let startedAt = sqlite3_column_double(stmt, 0)
            let inputTokens = sqlite3_column_int(stmt, 1)
            let outputTokens = sqlite3_column_int(stmt, 2)
            let cacheRead = sqlite3_column_int(stmt, 3)
            let cacheWrite = sqlite3_column_int(stmt, 4)
            let msgCount = sqlite3_column_int(stmt, 5)

            let tokens = Int(inputTokens) + Int(outputTokens) + Int(cacheRead)
            guard tokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: startedAt)
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)

            // 每条 session 算 1 条消息（代表一次会话的 token 消耗）
            // 但如果 message_count > 0，用实际的 assistant 回复数
            let effectiveMessages = msgCount > 0 ? Int(msgCount) : 1

            // Daily
            if var e = dailyData[dateKey] {
                e.tokens += tokens; e.messages += effectiveMessages
                dailyData[dateKey] = e
            } else {
                dailyData[dateKey] = DayUsage(tokens: tokens, messages: effectiveMessages)
            }

            // Hourly
            if var e = hourlyData[hourKey] {
                e.tokens += tokens; e.messages += effectiveMessages
                hourlyData[hourKey] = e
            } else {
                hourlyData[hourKey] = HourlyUsage(tokens: tokens, messages: effectiveMessages)
            }

            // Cache
            let cacheTokens = Int(cacheRead) + Int(cacheWrite)
            dailyCache[dateKey, default: 0] += cacheTokens

            // Recent (今天内的 session)
            if dateKey == today && date >= now.addingTimeInterval(-AppConfig.Scan.oneDaySeconds) {
                recentEntries.append(RecentEntry(timestamp: date, tokens: tokens))
                // L4: 限制 recentEntries 增长，只保留 active 窗口 3 倍内的条目
                if recentEntries.count > 64 {
                    let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
                    recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
                }
            }
        }

        lastScanTime = Date()
    }

    // MARK: - 今日活跃 Session 列表

    /// Hermes session 数据存储在 SQLite 的 sessions 表中
    func todaySessions() -> [SessionInfo] {
        let dbFile = dbPath
        var db: OpaquePointer?
        guard sqlite3_open(dbFile, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let todayStart = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
        let query = """
        SELECT id, started_at, model,
               input_tokens, output_tokens,
               cache_read_tokens, cache_write_tokens,
               message_count
        FROM sessions
        WHERE started_at >= ?
          AND (input_tokens > 0 OR output_tokens > 0)
        ORDER BY started_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, todayStart.timeIntervalSince1970)

        var results: [SessionInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionIdPtr = sqlite3_column_text(stmt, 0)
            let sessionId = sessionIdPtr != nil ? String(cString: sessionIdPtr!) : ""
            let startedAt = sqlite3_column_double(stmt, 1)
            let modelPtr = sqlite3_column_text(stmt, 2)
            let model = modelPtr != nil ? String(cString: modelPtr!) : nil
            let inputTokens = sqlite3_column_int(stmt, 3)
            let outputTokens = sqlite3_column_int(stmt, 4)
            let cacheRead = sqlite3_column_int(stmt, 5)
            let msgCount = sqlite3_column_int(stmt, 7)

            let tokens = Int(inputTokens) + Int(outputTokens) + Int(cacheRead)
            guard tokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: startedAt)
            let dateKey = DateHelper.dateKey(from: date)
            guard dateKey == DateHelper.todayKey() else { continue }

            let displayId = sessionId.isEmpty ? "unknown" : SessionIdDisplay.format(sessionId)
            let effectiveMessages = msgCount > 0 ? Int(msgCount) : 1

            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: nil,
                todayTokens: tokens,
                todayMessages: effectiveMessages,
                isActive: true,
                model: model
            ))
        }

        return results
    }
}
