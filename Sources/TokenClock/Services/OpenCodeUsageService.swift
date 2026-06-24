import Foundation
import SQLite3

/// 从 OpenCode 本地 SQLite 数据库读取 token 使用数据
/// 数据库位置: ~/.local/share/opencode/opencode.db
/// 表结构: session (tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created)
final class OpenCodeUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []

    private let opencodeHome: String
    private var lastScanTime: Date = .distantPast

    init() {
        opencodeHome = PathConfig.opencodeHome()
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
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private var dbPath: String {
        opencodeHome + "/opencode.db"
    }

    private func scanDatabase() {
        let dbFile = dbPath
        let walFile = dbFile + "-wal"
        var db: OpaquePointer?

        let fm = FileManager.default
        var newestMod: Date?
        for path in [dbFile, walFile] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                if newestMod == nil || modDate > newestMod! { newestMod = modDate }
            }
        }
        if let newest = newestMod, newest <= lastScanTime { return }

        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        recentEntries = []

        guard sqlite3_open(dbFile, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = """
        SELECT tokens_input, tokens_output, tokens_reasoning,
               tokens_cache_read, tokens_cache_write,
               time_created
        FROM session
        WHERE tokens_input > 0 OR tokens_output > 0
        ORDER BY time_created ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let today = DateHelper.todayKey()
        let now = Date()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let inputTokens = sqlite3_column_int(stmt, 0)
            let outputTokens = sqlite3_column_int(stmt, 1)
            let reasoningTokens = sqlite3_column_int(stmt, 2)
            let cacheRead = sqlite3_column_int(stmt, 3)
            let cacheWrite = sqlite3_column_int(stmt, 4)
            let timeCreatedMs = sqlite3_column_int64(stmt, 5)

            let tokens = Int(inputTokens) + Int(outputTokens) + Int(reasoningTokens) + Int(cacheRead)
            guard tokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(timeCreatedMs) / 1000.0)
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)

            if var e = dailyData[dateKey] {
                e.tokens += tokens; e.messages += 1
                dailyData[dateKey] = e
            } else {
                dailyData[dateKey] = DayUsage(tokens: tokens, messages: 1)
            }

            if var e = hourlyData[hourKey] {
                e.tokens += tokens; e.messages += 1
                hourlyData[hourKey] = e
            } else {
                hourlyData[hourKey] = HourlyUsage(tokens: tokens, messages: 1)
            }

            let cacheTokens = Int(cacheRead) + Int(cacheWrite)
            dailyCache[dateKey, default: 0] += cacheTokens

            if dateKey == today && date >= now.addingTimeInterval(-86400) {
                recentEntries.append(RecentEntry(timestamp: date, tokens: tokens))
            }
        }

        lastScanTime = Date()
    }

    // MARK: - 今日活跃 Session 列表

    func todaySessions() -> [SessionInfo] {
        let dbFile = dbPath
        var db: OpaquePointer?
        guard sqlite3_open(dbFile, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let todayStart = Date().addingTimeInterval(-86400)
        let todayStartMs = Int64(todayStart.timeIntervalSince1970 * 1000)

        let query = """
        SELECT id, title, directory,
               tokens_input, tokens_output, tokens_reasoning,
               tokens_cache_read, tokens_cache_write,
               time_created
        FROM session
        WHERE time_created >= ?
          AND (tokens_input > 0 OR tokens_output > 0)
        ORDER BY time_created DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, todayStartMs)

        var results: [SessionInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionIdPtr = sqlite3_column_text(stmt, 0)
            let sessionId = sessionIdPtr != nil ? String(cString: sessionIdPtr!) : ""
            let titlePtr = sqlite3_column_text(stmt, 1)
            let title = titlePtr != nil ? String(cString: titlePtr!) : ""
            let dirPtr = sqlite3_column_text(stmt, 2)
            let directory = dirPtr != nil ? String(cString: dirPtr!) : ""

            let inputTokens = sqlite3_column_int(stmt, 3)
            let outputTokens = sqlite3_column_int(stmt, 4)
            let reasoningTokens = sqlite3_column_int(stmt, 5)
            let cacheRead = sqlite3_column_int(stmt, 6)
            let cacheWrite = sqlite3_column_int(stmt, 7)
            let timeCreatedMs = sqlite3_column_int64(stmt, 8)

            let tokens = Int(inputTokens) + Int(outputTokens) + Int(reasoningTokens) + Int(cacheRead)
            guard tokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(timeCreatedMs) / 1000.0)
            let dateKey = DateHelper.dateKey(from: date)
            guard dateKey == DateHelper.todayKey() else { continue }

            let displayId = SessionIdDisplay.format(sessionId)
            let dirName = (directory as NSString).lastPathComponent

            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: dirName.isEmpty ? nil : dirName,
                todayTokens: tokens,
                todayMessages: 1,
                isActive: true
            ))
        }

        return results
    }
}
