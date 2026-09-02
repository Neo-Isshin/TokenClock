import Foundation
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

/// Reads ZCode's authoritative local request ledger.
///
/// ZCode's diagnostic JSONL deliberately redacts token values. The SQLite
/// `model_usage` table keeps the exact per-request buckets and is also what
/// ZCode's own App Usage view is backed by.
final class ZCodeUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var dailyModelBuckets: [String: [String: ModelBuckets]] = [:]
    private var dailySessions: [String: [String: SessionAggregate]] = [:]
    private var recentEntries: [RecentEntry] = []
    private var lastScanTime: Date = .distantPast
    private let zcodeHome: String

    private struct SessionAggregate {
        var title: String
        var directory: String?
        var taskType: String?
        var tokens = 0
        var messages = 0
        var cacheRead = 0
        var latest = Date.distantPast
        var modelTokens: [String: Int] = [:]
        var modelBuckets: [String: ModelBuckets] = [:]
    }

    init(zcodeHome: String? = nil) {
        self.zcodeHome = zcodeHome ?? PathConfig.zcodeHome()
    }

    func fullScan() {
        lastScanTime = .distantPast
        scanDatabase(force: true)
    }

    func incrementalScan() { scanDatabase(force: false) }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let key = DateHelper.todayKey()
        let usage = dailyData[key]
        let cache = dailyCache[key] ?? 0
        let tokens = usage?.tokens ?? 0
        return (tokens, usage?.messages ?? 0,
                TokenAccounting.cacheReadShare(freshTokens: tokens, cacheRead: cache))
    }

    func todayModelBuckets() -> [String: ModelBuckets] {
        dailyModelBuckets[DateHelper.todayKey()] ?? [:]
    }

    func todayCost() -> CostEstimate { PricingService.shared.cost(of: todayModelBuckets()) }
    func todayCacheReadTokens() -> Int { dailyCache[DateHelper.todayKey()] ?? 0 }
    func currentHourTokens() -> Int { hourlyData[DateHelper.currentHourKey()]?.tokens ?? 0 }

    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        let entries = recentEntries.filter { $0.timestamp >= cutoff }
        return (entries.reduce(0) { $0 + $1.tokens }, entries.count)
    }

    func isActive() -> Bool {
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    func todaySessions() -> [SessionInfo] {
        sessions(for: DateHelper.todayKey())
    }

    func historicalSnapshots(retentionDays: Int) -> [String: ToolSnapshot] {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -max(1, retentionDays) + 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? .distantPast
        let cutoff = DateHelper.dateKey(from: cutoffDate)
        var result: [String: ToolSnapshot] = [:]
        for (dateKey, usage) in dailyData where dateKey >= cutoff {
            let cache = dailyCache[dateKey] ?? 0
            let infos = sessions(for: dateKey)
            result[dateKey] = ToolSnapshot(
                name: "ZCode", tokens: usage.tokens, messages: usage.messages,
                cacheRate: TokenAccounting.cacheReadShare(freshTokens: usage.tokens, cacheRead: cache),
                isActive: dateKey == DateHelper.todayKey() && isActive(),
                cost: PricingService.shared.cost(of: dailyModelBuckets[dateKey] ?? [:]),
                cacheReadTokens: cache,
                sessions: infos.map {
                    SessionSnapshot(
                        id: $0.rawId, displayName: $0.displayName,
                        tokens: $0.todayTokens, messages: $0.todayMessages,
                        isActive: $0.isActive, model: $0.model,
                        cost: $0.todayCost, cacheReadTokens: $0.cacheReadTokens
                    )
                }
            )
        }
        return result
    }

    private func sessions(for dateKey: String) -> [SessionInfo] {
        let activeCutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return (dailySessions[dateKey] ?? [:]).map { id, value in
            let model = value.modelTokens.max(by: { $0.value < $1.value })?.key
            return SessionInfo(
                rawId: id,
                displayName: value.title.isEmpty ? Self.shortID(id) : value.title,
                detail: value.directory,
                todayTokens: value.tokens,
                todayMessages: value.messages,
                isActive: dateKey == DateHelper.todayKey() && value.latest >= activeCutoff,
                source: value.taskType,
                model: model,
                todayCost: PricingService.shared.cost(of: value.modelBuckets),
                cacheReadTokens: value.cacheRead
            )
        }.sorted { $0.todayTokens > $1.todayTokens }
    }

    private var databasePath: String {
        if zcodeHome.lowercased().hasSuffix(".sqlite") || zcodeHome.lowercased().hasSuffix(".db") {
            return zcodeHome
        }
        return zcodeHome + "/cli/db/db.sqlite"
    }

    private func scanDatabase(force: Bool) {
        let dbFile = databasePath
        let files = [dbFile, dbFile + "-wal"]
        let newest = files.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }.max() ?? .distantPast
        guard force || newest > lastScanTime else { return }

        clearData()
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbFile, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = """
        SELECT m.session_id,
               COALESCE(s.title, ''), COALESCE(s.directory, ''), COALESCE(s.task_type, ''),
               m.model_id, m.started_at, COALESCE(m.completed_at, m.started_at),
               m.input_tokens, m.output_tokens, m.reasoning_tokens,
               m.cache_creation_input_tokens, m.cache_read_input_tokens
        FROM model_usage m
        LEFT JOIN session s ON s.id = m.session_id
        WHERE m.status = 'completed'
          AND NOT EXISTS (
            SELECT 1 FROM model_usage newer
            WHERE newer.logical_request_id = m.logical_request_id
              AND newer.status = 'completed'
              AND (newer.attempt_index > m.attempt_index
                   OR (newer.attempt_index = m.attempt_index AND newer.rowid > m.rowid))
          )
        ORDER BY m.started_at ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let today = DateHelper.todayKey()
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = text(statement, 0)
            guard !sessionID.isEmpty else { continue }
            let title = text(statement, 1)
            let directory = text(statement, 2)
            let taskType = text(statement, 3)
            let model = Self.normalizedModel(text(statement, 4))
            let startedAt = milliseconds(statement, 5)
            let completedAt = milliseconds(statement, 6)
            let input = integer(statement, 7)
            let output = integer(statement, 8)
            let reasoning = integer(statement, 9)
            let cacheWrite = integer(statement, 10)
            let cacheRead = integer(statement, 11)
            let freshInput = max(0, input - min(input, cacheRead))
            let tokens = TokenAccounting.separateCacheFields(
                input: freshInput, cacheWrite: cacheWrite, output: output,
                additional: [reasoning]
            )
            guard tokens > 0 else { continue }

            let date = completedAt ?? startedAt ?? .distantPast
            guard date != .distantPast else { continue }
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)
            add(tokens: tokens, messages: 1, to: dateKey, hourKey: hourKey)
            dailyCache[dateKey, default: 0] += cacheRead

            if let model {
                let buckets = ModelBuckets(
                    input: freshInput,
                    output: output + reasoning,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
                dailyModelBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(buckets)
                var session = dailySessions[dateKey, default: [:]][sessionID]
                    ?? SessionAggregate(title: title, directory: directory.isEmpty ? nil : directory,
                                        taskType: taskType.isEmpty ? nil : taskType)
                session.tokens += tokens
                session.messages += 1
                session.cacheRead += cacheRead
                session.latest = max(session.latest, date)
                session.modelTokens[model, default: 0] += tokens
                session.modelBuckets[model, default: ModelBuckets()].merge(buckets)
                dailySessions[dateKey, default: [:]][sessionID] = session
            }
            if dateKey == today { recentEntries.append(RecentEntry(timestamp: date, tokens: tokens)) }
        }
        let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
        recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
        lastScanTime = newest == .distantPast ? Date() : newest
    }

    private func clearData() {
        dailyData.removeAll(); hourlyData.removeAll(); dailyCache.removeAll()
        dailyModelBuckets.removeAll(); dailySessions.removeAll(); recentEntries.removeAll()
    }

    private func add(tokens: Int, messages: Int, to dateKey: String, hourKey: String) {
        var day = dailyData[dateKey] ?? DayUsage(tokens: 0, messages: 0)
        day.tokens += tokens; day.messages += messages; dailyData[dateKey] = day
        var hour = hourlyData[hourKey] ?? HourlyUsage(tokens: 0, messages: 0)
        hour.tokens += tokens; hour.messages += messages; hourlyData[hourKey] = hour
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func integer(_ statement: OpaquePointer?, _ column: Int32) -> Int {
        Int(clamping: max(Int64(0), sqlite3_column_int64(statement, column)))
    }

    private func milliseconds(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, column)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }

    private static func normalizedModel(_ raw: String) -> String? {
        ModelNormalizer.normalize(raw.lowercased())
    }

    private static func shortID(_ id: String) -> String {
        guard id.count > 14 else { return id }
        return String(id.prefix(7)) + "…" + String(id.suffix(4))
    }
}
