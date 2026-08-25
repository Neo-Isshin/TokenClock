import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

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
    /// Cursor Dashboard 的 usage event 自带模型与四类 token。这里保留模型维度，
    /// 避免汇总后退化成一个无法计价、也无法辨认的 `cursor` 占位项。
    private(set) var dailyModelBuckets: [String: [String: ModelBuckets]] = [:]
    private var dailyModelUsage: [String: [String: DayUsage]] = [:]
    private var dailyModelCache: [String: [String: Int]] = [:]
    private var dailyModelLatestActivity: [String: [String: Date]] = [:]
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
        let rate = TokenAccounting.cacheReadShare(freshTokens: total, cacheRead: cache)
        return (total, d?.messages ?? 0, rate)
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

    /// Cursor IDE 的 state.vscdb 路径（macOS: Library，Linux: XDG config）
    private func cursorStateDbPath() -> String {
#if os(Linux)
        let configured = PathConfig.cursorAgentHome()
        let candidates: [String]
        if configured.hasSuffix(".vscdb") {
            candidates = [configured]
        } else {
            candidates = [
                configured + "/state.vscdb",
                configured + "/User/globalStorage/state.vscdb",
            ]
        }
        return candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
            ?? candidates[0]
#else
        AppPaths.appSupport("Cursor", "User", "globalStorage", "state.vscdb")
#endif
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
        // 用户可在设置中关闭 Cursor 云端获取，避免凭证外发 cursor.com
        guard UserDefaults.standard.bool(for: .cursorCloudFetchEnabled, default: true) else { return }
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

        // 分页拉满整个窗口：单页 pageSize=200，超过部分曾被静默丢弃。
        // 循环直到某页返回 < pageSize（最后一页）/ 空 / 非 200，安全上限 100 页（=20000 事件，30 天远超）。
        var allEvents: [[String: Any]] = []
        var page = 1
        let maxPages = 100
        var gotSuccess = false   // 至少一次 200 —— 区分"窗口真没事件"与"API 全失败需保缓存"
        var sawAuthError = false

        while page <= maxPages {
            let body: [String: Any] = [
                "teamId": 0,
                "startDate": String(startMs),
                "endDate": String(nowMs),
                "page": page,
                "pageSize": AppConfig.Scan.cursorPageSize
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { break }

                // 401/403：token 过期，清空凭据，下次扫描重新读；停止翻页
                if http.statusCode == 401 || http.statusCode == 403 {
                    sawAuthError = true
                    break
                }
                guard http.statusCode == 200 else { break }   // 翻页中途非 200：停止，保留已拿到的事件

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = json["usageEventsDisplay"] as? [[String: Any]] else { break }

                gotSuccess = true
                allEvents.append(contentsOf: events)
                if events.count < AppConfig.Scan.cursorPageSize { break }   // 最后一页
                page += 1
            } catch {
                // 网络错误：停止翻页，保留已拿到的事件（与旧"保留旧缓存"语义一致）
                break
            }
        }

        if sawAuthError {
            sessionToken = nil
            userId = nil
        }
        lastFetchTime = Date()

        // 只有真正拿到过 200（哪怕空列表）才更新缓存；完全失败则保留旧缓存
        guard gotSuccess else { return }

        // 在主线程上更新缓存数据（与 ViewModel 读取一致）
        await MainActor.run {
            self.applyEvents(allEvents, rangeDays: timeRangeDays)
        }
    }

    /// 把 API 返回的事件合并到本地缓存
    /// rangeDays > 2 时（fullScan），先清空再重建；否则增量覆盖当日
    /// internal 便于用真实 API 响应形状做解析回归测试。
    func applyEvents(_ events: [[String: Any]], rangeDays: Int) {
        if rangeDays >= 30 {
            // 全量重建
            dailyData.removeAll()
            hourlyData.removeAll()
            dailyCache.removeAll()
            dailyModelBuckets.removeAll()
            dailyModelUsage.removeAll()
            dailyModelCache.removeAll()
            dailyModelLatestActivity.removeAll()
            recentEntries = []
        } else {
            // 增量窗口覆盖最近 rangeDays 天（cursorIncrementalDays=2 = 今天 + 昨天）。
            // 必须逐天清空后再重读，否则昨天的 dailyData/hourlyData/dailyCache 每轮增量都
            // 累加一次（double-count）。recentEntries 本身只收今天条目，清昨天对它是 no-op，
            // 但保持循环统一。（旧实现只清今天 → 昨天持续翻倍。）
            for dayOffset in 0..<rangeDays {
                let day = DateHelper.dateKey(from: Date().addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60))
                dailyData[day] = nil
                dailyCache[day] = nil
                dailyModelBuckets[day] = nil
                dailyModelUsage[day] = nil
                dailyModelCache[day] = nil
                dailyModelLatestActivity[day] = nil
                hourlyData = hourlyData.filter { !$0.key.hasPrefix(day) }
                recentEntries = recentEntries.filter { DateHelper.dateKey(from: $0.timestamp) != day }
            }
        }

        let today = DateHelper.todayKey()

        for event in events {
            // timestamp 可能是 String 或 Number
            var timestampMs = 0
            if let tsStr = event["timestamp"] as? String, let ts = Int(tsStr) {
                timestampMs = ts
            } else if let ts = event["timestamp"] as? Int {
                timestampMs = ts
            } else if let ts = event["timestamp"] as? Double {
                timestampMs = Int(ts)
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
            let total = TokenAccounting.separateCacheFields(
                input: inputTokens, cacheWrite: cacheWrite, output: outputTokens
            )
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

            dailyCache[dateKey, default: 0] += cacheRead

            if let model = ModelNormalizer.normalize(event["model"] as? String) {
                dailyModelBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(
                    ModelBuckets(
                        input: inputTokens,
                        output: outputTokens,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite
                    )
                )

                if var usage = dailyModelUsage[dateKey, default: [:]][model] {
                    usage.tokens += total
                    usage.messages += 1
                    dailyModelUsage[dateKey, default: [:]][model] = usage
                } else {
                    dailyModelUsage[dateKey, default: [:]][model] = DayUsage(tokens: total, messages: 1)
                }
                dailyModelCache[dateKey, default: [:]][model, default: 0] += cacheRead
                if date > (dailyModelLatestActivity[dateKey, default: [:]][model] ?? .distantPast) {
                    dailyModelLatestActivity[dateKey, default: [:]][model] = date
                }
            }

            if dateKey == today {
                recentEntries.append(RecentEntry(timestamp: date, tokens: total))
                // L4: 限制 recentEntries 增长，只保留 active 窗口 3 倍内的条目
                if recentEntries.count > 64 {
                    let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
                    recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
                }
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
        // Cursor API 带 conversationId，但同一模型可能跨很多短会话。详情面板按模型聚合，
        // 与 Dashboard 的模型筛选口径一致，也避免产生数百个低价值 session 行。
        let today = DateHelper.todayKey()
        let activeCutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds)
        return (dailyModelUsage[today] ?? [:]).map { model, usage in
            let buckets = dailyModelBuckets[today]?[model]
            return SessionInfo(
                rawId: "cursor:\(model)",
                displayName: model,
                detail: nil,
                todayTokens: usage.tokens,
                todayMessages: usage.messages,
                isActive: (dailyModelLatestActivity[today]?[model] ?? .distantPast) >= activeCutoff,
                model: model,
                todayCost: buckets.map { PricingService.shared.cost(of: [model: $0]) } ?? .zero,
                cacheReadTokens: dailyModelCache[today]?[model] ?? 0
            )
        }.sorted { $0.todayTokens > $1.todayTokens }
    }
}
