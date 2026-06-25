import Foundation
import SQLite3

/// 通过 Cursor 官方 usage API 拉取 token 消耗。
///
/// 认证流程（自动，无需用户配置）：
///   1. 读取 Cursor IDE 的本地 SQLite: ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
///   2. 从 ItemTable 取 `cursorAuth/accessToken`
///   3. 从 token 提取 userId（两种格式：`user_XXX::JWT` 或纯 JWT 解 payload.sub）
///
/// API endpoint:
///   POST https://cursor.com/api/dashboard/get-filtered-usage-events
///   Body: {teamId: 0, startDate, endDate, page: 1, pageSize: 100}
///   Response: {usageEventsDisplay: [{timestamp, model, tokenUsage: {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalCents}}]}
///
/// 同时覆盖 Cursor IDE 和 Cursor Agent CLI，因为两者共用同一套账户系统。
final class CursorAgentUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []

    private let session: URLSession
    private var sessionToken: String?
    private var userId: String?
    private var lastFetchTime: Date = .distantPast

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.HTTP.requestTimeout
        config.timeoutIntervalForResource = AppConfig.HTTP.resourceTimeout
        config.httpCookieStorage = nil  // 不使用系统 cookie storage
        session = URLSession(configuration: config)
    }

    func fullScan() {
        // 不清空已有数据，等 API 返回后原子替换
        Task.detached { [weak self] in
            await self?.refreshCredentialsIfNeeded()
            await self?.fetchUsageData(timeRangeDays: AppConfig.Scan.cursorFullScanDays)
        }
    }

    func incrementalScan() {
        // 节流：避免高频请求
        let now = Date()
        if now.timeIntervalSince(lastFetchTime) < AppConfig.HTTP.cursorMinFetchInterval { return }

        Task.detached { [weak self] in
            await self?.refreshCredentialsIfNeeded()
            // 增量只拉今天 + 昨天的数据，避免大请求
            await self?.fetchUsageData(timeRangeDays: AppConfig.Scan.cursorIncrementalDays)
        }
    }

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

    // MARK: - 凭据加载

    private func refreshCredentialsIfNeeded() async {
        if sessionToken != nil && userId != nil { return }
        loadCredentialsFromStateDb()
    }

    /// 同步从 Cursor IDE 的 state.vscdb 读 access token
    private func loadCredentialsFromStateDb() {
        let dbPath = cursorStateDbPath()
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return }
        let token = String(cString: cstr)
        guard let uid = extractUserId(from: token) else { return }

        sessionToken = token
        userId = uid
    }

    /// macOS 上 Cursor IDE 的 state.vscdb 路径
    private func cursorStateDbPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// 从 token 提取 userId
    /// 两种格式：
    ///   1. `user_XXXXX::JWT`（WorkosCursorSessionToken cookie 格式）
    ///   2. 纯 JWT（state.vscdb 里存的形式，需解 payload.sub）
    private func extractUserId(from token: String) -> String? {
        let decoded = token.removingPercentEncoding ?? token

        if decoded.contains("::") {
            return decoded.components(separatedBy: "::").first
        }

        let parts = decoded.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = payload["sub"] as? String else { return nil }

        // sub 通常形如 "auth0|user_XXXXX"
        if let range = sub.range(of: #"user_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(sub[range])
        }
        return nil
    }

    // MARK: - API 请求

    private func fetchUsageData(timeRangeDays: Int) async {
        guard let token = sessionToken, let uid = userId else { return }

        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - timeRangeDays * 24 * 60 * 60 * 1000

        guard let url = URL(string: "\(AppConfig.API.cursorBase)/dashboard/get-filtered-usage-events") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.API.cursorOrigin, forHTTPHeaderField: "Origin")
        request.setValue(AppConfig.API.cursorDashboard, forHTTPHeaderField: "Referer")
        request.setValue(AppConfig.HTTP.userAgent, forHTTPHeaderField: "User-Agent")

        // Cookie 格式：WorkosCursorSessionToken=user_XXX%3A%3AJWT
        let cookieValue: String
        if token.contains("::") {
            cookieValue = token.replacingOccurrences(of: "::", with: "%3A%3A")
        } else {
            cookieValue = "\(uid)%3A%3A\(token)"
        }
        request.setValue("WorkosCursorSessionToken=\(cookieValue)", forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "teamId": 0,
            "startDate": String(startMs),
            "endDate": String(nowMs),
            "page": 1,
            "pageSize": AppConfig.Scan.cursorPageSize
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            lastFetchTime = Date()

            guard let http = response as? HTTPURLResponse else { return }

            // 401/403：token 过期，清空凭据，下次扫描重新读
            if http.statusCode == 401 || http.statusCode == 403 {
                sessionToken = nil
                userId = nil
                return
            }

            guard http.statusCode == 200 else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["usageEventsDisplay"] as? [[String: Any]] else { return }

            // 在主线程上更新缓存数据（与 ViewModel 读取一致）
            await MainActor.run {
                self.applyEvents(events, rangeDays: timeRangeDays)
            }
        } catch {
            // 网络错误：保留旧缓存
            lastFetchTime = Date()
        }
    }

    /// 把 API 返回的事件合并到本地缓存
    /// rangeDays > 2 时（fullScan），先清空再重建；否则增量覆盖当日
    private func applyEvents(_ events: [[String: Any]], rangeDays: Int) {
        if rangeDays >= 30 {
            // 全量重建
            dailyData.removeAll()
            hourlyData.removeAll()
            dailyCache.removeAll()
            recentEntries = []
        } else {
            // 增量：清空今天和昨天的数据后重读
            let today = DateHelper.todayKey()
            dailyData[today] = nil
            dailyCache[today] = nil
            hourlyData = hourlyData.filter { !$0.key.hasPrefix(today) }
            recentEntries = recentEntries.filter { DateHelper.dateKey(from: $0.timestamp) != today }
        }

        let today = DateHelper.todayKey()

        for event in events {
            // timestamp 可能是 String 或 Number
            var timestampMs = 0
            if let tsStr = event["timestamp"] as? String, let ts = Int(tsStr) {
                timestampMs = ts
            } else if let ts = event["timestamp"] as? Int {
                timestampMs = ts
            }
            guard timestampMs > 0 else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
            let dateKey = DateHelper.dateKey(from: date)
            let hourKey = DateHelper.hourKey(from: date)

            guard let tokenUsage = event["tokenUsage"] as? [String: Any] else { continue }

            let inputTokens = intValue(tokenUsage, "inputTokens")
            let outputTokens = intValue(tokenUsage, "outputTokens")
            let cacheRead = intValue(tokenUsage, "cacheReadTokens")
            let cacheWrite = intValue(tokenUsage, "cacheWriteTokens")
            let total = inputTokens + outputTokens + cacheRead + cacheWrite
            guard total > 0 else { continue }

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

            dailyCache[dateKey, default: 0] += cacheRead + cacheWrite

            if dateKey == today {
                recentEntries.append(RecentEntry(timestamp: date, tokens: total))
            }
        }
    }

    private func intValue(_ dict: [String: Any], _ key: String) -> Int {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? Double { return Int(n) }
        if let s = dict[key] as? String, let n = Int(s) { return n }
        return 0
    }

    // MARK: - Session 列表

    func todaySessions() -> [SessionInfo] {
        // Cursor API 不按 session 划分，按 model 聚合展示今日活动
        let today = DateHelper.todayKey()
        var byModel: [String: (tokens: Int, messages: Int)] = [:]
        var modelOrder: [String] = []

        // 重新扫一次 dailyData 不够（没存 model 信息），这里直接返回按 hour 聚合的简化列表
        // 真实场景下 ViewModel 会用其他维度展示，这里给出一个合理的近似
        let tokens = dailyData[today]?.tokens ?? 0
        let messages = dailyData[today]?.messages ?? 0
        guard tokens > 0 else { return [] }

        byModel["cursor"] = (tokens, messages)
        modelOrder.append("cursor")

        return modelOrder.compactMap { name in
            guard let s = byModel[name] else { return nil }
            return SessionInfo(
                rawId: name, displayName: name, detail: nil,
                todayTokens: s.tokens, todayMessages: s.messages, isActive: true
            )
        }
    }
}
