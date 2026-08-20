import Foundation

/// 从 Claude Code 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.claude/projects/*/
final class ClaudeCodeUsageService: @unchecked Sendable {
    private static let assistantLineNeedle = [Data("\"assistant\"".utf8)]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private(set) var dailyCache: [String: Int] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var fileDailyContrib: [String: [String: DayUsage]] = [:]
    private var fileHourlyContrib: [String: [String: HourlyUsage]] = [:]
    private var fileCacheContrib: [String: [String: Int]] = [:]
    private var fileRecentContrib: [String: [RecentEntry]] = [:]
    private var fileLastModel: [String: [String: String]] = [:]
    /// path → dateKey → 归一化模型名 → 计费分桶。费用按需聚合（todayModelBuckets），
    /// 重扫同一文件时整体替换，不参与 dailyData 那套减法镜像。
    private var fileBucketContrib: [String: [String: [String: ModelBuckets]]] = [:]
    /// Nested project logs historically participate in session detail only, not
    /// the tool total. Keep that behavior while avoiding recursive re-parsing.
    private var nestedFileCache: [String: FileMeta] = [:]
    private var nestedDailyContrib: [String: [String: DayUsage]] = [:]
    private var nestedLastModel: [String: [String: String]] = [:]
    private var nestedBucketContrib: [String: [String: [String: ModelBuckets]]] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let claudeHome: String

    init(claudeHome: String? = nil) {
        self.claudeHome = claudeHome ?? PathConfig.claudeCodeHome()
    }

    func fullScan() {
        dailyData.removeAll()
        hourlyData.removeAll()
        dailyCache.removeAll()
        fileCache.removeAll()
        fileDailyContrib.removeAll()
        fileHourlyContrib.removeAll()
        fileCacheContrib.removeAll()
        fileRecentContrib.removeAll()
        fileLastModel.removeAll()
        fileBucketContrib.removeAll()
        nestedFileCache.removeAll()
        nestedDailyContrib.removeAll()
        nestedLastModel.removeAll()
        nestedBucketContrib.removeAll()
        recentEntries = []
        scanProjectsDir()
    }

    func incrementalScan() { scanProjectsDir() }

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

    // MARK: - 内部

    private func scanProjectsDir() {
        let projectsDir = claudeHome + "/projects"
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            evictTopLevelFiles(notIn: [])
            nestedFileCache.removeAll()
            nestedDailyContrib.removeAll()
            nestedLastModel.removeAll()
            nestedBucketContrib.removeAll()
            rebuildRecentEntries()
            return
        }

        var liveTopLevelPaths = Set<String>()
        var liveNestedPaths = Set<String>()

        for project in projects {
            let projectPath = projectsDir + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let fullPath = url.path
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                if url.deletingLastPathComponent().standardizedFileURL.path
                    == projectURL.standardizedFileURL.path {
                    liveTopLevelPaths.insert(fullPath)
                    if fileCache[fullPath]?.modDate == modDate { continue }

                    if let old = fileDailyContrib[fullPath] { subtractDaily(old) }
                    if let old = fileHourlyContrib[fullPath] { subtractHourly(old) }
                    if let old = fileCacheContrib[fullPath] { subtractCache(old) }

                    parseFile(path: fullPath)
                    fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
                } else {
                    liveNestedPaths.insert(fullPath)
                    if nestedFileCache[fullPath]?.modDate == modDate { continue }
                    parseNestedDetailFile(path: fullPath)
                    nestedFileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
                }
            }
        }
        evictTopLevelFiles(notIn: liveTopLevelPaths)
        nestedFileCache = nestedFileCache.filter { liveNestedPaths.contains($0.key) }
        nestedDailyContrib = nestedDailyContrib.filter { liveNestedPaths.contains($0.key) }
        nestedLastModel = nestedLastModel.filter { liveNestedPaths.contains($0.key) }
        nestedBucketContrib = nestedBucketContrib.filter { liveNestedPaths.contains($0.key) }
        rebuildRecentEntries()
    }

    private func evictTopLevelFiles(notIn livePaths: Set<String>) {
        let removed = Set(fileCache.keys).subtracting(livePaths)
        for path in removed {
            if let old = fileDailyContrib[path] { subtractDaily(old) }
            if let old = fileHourlyContrib[path] { subtractHourly(old) }
            if let old = fileCacheContrib[path] { subtractCache(old) }
            fileCache.removeValue(forKey: path)
            fileDailyContrib.removeValue(forKey: path)
            fileHourlyContrib.removeValue(forKey: path)
            fileCacheContrib.removeValue(forKey: path)
            fileRecentContrib.removeValue(forKey: path)
            fileLastModel.removeValue(forKey: path)
            fileBucketContrib.removeValue(forKey: path)
        }
    }

    private func subtractDaily(_ contrib: [String: DayUsage]) {
        for (k, u) in contrib {
            if var e = dailyData[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { dailyData.removeValue(forKey: k) }
                else { dailyData[k] = e }
            }
        }
    }

    private func subtractHourly(_ contrib: [String: HourlyUsage]) {
        for (k, u) in contrib {
            if var e = hourlyData[k] {
                e.tokens -= u.tokens; e.messages -= u.messages
                if e.tokens <= 0 && e.messages <= 0 { hourlyData.removeValue(forKey: k) }
                else { hourlyData[k] = e }
            }
        }
    }

    private func subtractCache(_ contrib: [String: Int]) {
        for (k, v) in contrib {
            if var e = dailyCache[k] {
                e -= v
                if e <= 0 { dailyCache.removeValue(forKey: k) }
                else { dailyCache[k] = e }
            }
        }
    }

    private func parseFile(path: String) {
        let today = DateHelper.todayKey()
        var newDaily: [String: DayUsage] = [:]
        var newHourly: [String: HourlyUsage] = [:]
        var newCache: [String: Int] = [:]
        var newRecent: [RecentEntry] = []
        var newLastModels: [String: String] = [:]
        var newBuckets: [String: [String: ModelBuckets]] = [:]

        guard let result = JSONLLineReader.read(path: path, matchingAny: Self.assistantLineNeedle, onLine: { line in
            if line.contains("\"assistant\""), let r = parseLine(line) {
                accumulate(
                    r, today: today, daily: &newDaily, hourly: &newHourly,
                    cache: &newCache, recent: &newRecent, lastModels: &newLastModels,
                    buckets: &newBuckets
                )
            }
        }) else { return }
        _ = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData) { line in
            if line.contains("\"assistant\""), let r = parseLine(line) {
                accumulate(
                    r, today: today, daily: &newDaily, hourly: &newHourly,
                    cache: &newCache, recent: &newRecent, lastModels: &newLastModels,
                    buckets: &newBuckets
                )
            }
        }

        fileDailyContrib[path] = newDaily
        fileHourlyContrib[path] = newHourly
        fileCacheContrib[path] = newCache
        fileRecentContrib[path] = newRecent
        fileLastModel[path] = newLastModels
        fileBucketContrib[path] = newBuckets
    }

    private struct R {
        let dateKey: String
        let hourKey: String
        let tokens: Int
        let cacheTokens: Int
        let ts: Date?
        let model: String?
        /// 计费分桶（按原始 model 归一化后的键累计，由调用方合并）
        let buckets: ModelBuckets
    }

    private func parseLine(_ line: String) -> R? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        // Anthropic reports uncached input, cache read and cache creation as separate fields.
        // Cache creation is fresh input for this turn; only cache reads are excluded.
        // （口径与 main 分支 TokenAccounting 一致：主用量不含缓存读，缓存写按新输入计入）
        let tokens = TokenAccounting.separateCacheFields(
            input: inputTokens, cacheWrite: cacheCreation, output: outputTokens
        )
        guard tokens > 0 else { return nil }
        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.localDateKey(from: timestamp)
        guard dateKey.count == 10 else { return nil }
        return R(dateKey: dateKey, hourKey: DateHelper.localHourKey(from: timestamp),
                 tokens: tokens, cacheTokens: cacheRead,
                 ts: DateHelper.parseISO8601(timestamp),
                 model: msg["model"] as? String,
                 buckets: ModelBuckets(input: inputTokens, output: outputTokens,
                                       cacheRead: cacheRead, cacheWrite: cacheCreation))
    }

    private func accumulate(_ r: R, today: String, daily: inout [String: DayUsage],
                            hourly: inout [String: HourlyUsage], cache: inout [String: Int],
                            recent: inout [RecentEntry], lastModels: inout [String: String],
                            buckets: inout [String: [String: ModelBuckets]]) {
        if var e = dailyData[r.dateKey] { e.tokens += r.tokens; e.messages += 1; dailyData[r.dateKey] = e }
        else { dailyData[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = daily[r.dateKey] { e.tokens += r.tokens; e.messages += 1; daily[r.dateKey] = e }
        else { daily[r.dateKey] = DayUsage(tokens: r.tokens, messages: 1) }
        if var e = hourlyData[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourlyData[r.hourKey] = e }
        else { hourlyData[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        if var e = hourly[r.hourKey] { e.tokens += r.tokens; e.messages += 1; hourly[r.hourKey] = e }
        else { hourly[r.hourKey] = HourlyUsage(tokens: r.tokens, messages: 1) }
        // cache tokens
        dailyCache[r.dateKey, default: 0] += r.cacheTokens
        cache[r.dateKey, default: 0] += r.cacheTokens
        // 费用分桶（按归一化模型名累计，跨日期后缀的同模型自动合并）
        if let model = ModelNormalizer.normalize(r.model) {
            buckets[r.dateKey, default: [:]][model, default: ModelBuckets()].merge(r.buckets)
        }
        // recent
        if r.dateKey == today, let ts = r.ts {
            recent.append(RecentEntry(timestamp: ts, tokens: r.tokens))
        }
        if let model = r.model, !model.isEmpty {
            lastModels[r.dateKey] = model
        }
    }

    // MARK: - 费用估算

    /// 今日（顶层文件，与工具总数同口径）按归一化模型聚合的计费分桶。
    /// 保留分桶而非金额：价格目录刷新/自定义价修改后无需重扫日志即可重算。
    func todayModelBuckets() -> [String: ModelBuckets] {
        let today = DateHelper.todayKey()
        var result: [String: ModelBuckets] = [:]
        for (_, dates) in fileBucketContrib {
            guard let models = dates[today] else { continue }
            for (model, b) in models {
                result[model, default: ModelBuckets()].merge(b)
            }
        }
        return result
    }

    /// 今日工具级估算费用
    func todayCost() -> CostEstimate {
        PricingService.shared.cost(of: todayModelBuckets())
    }

    /// 今日缓存读 token 总数（顶层文件口径，与工具总数同源；「包含缓存读」展示用）
    func todayCacheReadTokens() -> Int {
        let today = DateHelper.todayKey()
        var result = 0
        for (_, dates) in fileBucketContrib {
            guard let models = dates[today] else { continue }
            for (_, b) in models { result += b.cacheRead }
        }
        return result
    }

    private func parseNestedDetailFile(path: String) {
        var daily: [String: DayUsage] = [:]
        var lastModels: [String: String] = [:]
        var buckets: [String: [String: ModelBuckets]] = [:]
        guard let result = JSONLLineReader.read(path: path, matchingAny: Self.assistantLineNeedle, onLine: { line in
            accumulateDetailLine(line, daily: &daily, lastModels: &lastModels, buckets: &buckets)
        }) else { return }
        _ = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData) { line in
            accumulateDetailLine(line, daily: &daily, lastModels: &lastModels, buckets: &buckets)
        }
        nestedDailyContrib[path] = daily
        nestedLastModel[path] = lastModels
        nestedBucketContrib[path] = buckets
    }

    private func accumulateDetailLine(
        _ line: String,
        daily: inout [String: DayUsage],
        lastModels: inout [String: String],
        buckets: inout [String: [String: ModelBuckets]]
    ) {
        guard line.contains("\"assistant\""), let result = parseLine(line) else { return }
        daily[result.dateKey, default: DayUsage(tokens: 0, messages: 0)].tokens += result.tokens
        daily[result.dateKey]!.messages += 1
        if let model = ModelNormalizer.normalize(result.model) {
            buckets[result.dateKey, default: [:]][model, default: ModelBuckets()].merge(result.buckets)
        }
        if let model = result.model, !model.isEmpty {
            lastModels[result.dateKey] = model
        }
    }

    /// recentEntries 是各文件 recent 贡献的派生聚合：每轮扫描从 fileRecentContrib 重建，
    /// 而非在逐行累加时直接 append —— 否则增量重读已变化文件时 recent 会双计。
    private func rebuildRecentEntries() {
        recentEntries = fileRecentContrib.values.flatMap { $0 }
        if recentEntries.count > 64 {
            let cutoff = Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds * 3)
            recentEntries = recentEntries.filter { $0.timestamp >= cutoff }
        }
    }

    // MARK: - 今日活跃 Session 列表

    /// Claude Code session 存储十分零碎：session 元数据在 ~/.claude/sessions/*.json 中，
    /// 实际对话记录在 ~/.claude/projects/<path>/<sessionId>.jsonl 中。
    /// 需要先读取 sessions 目录获取 sessionId，再在 projects 中定位对应文件。
    func todaySessions() -> [SessionInfo] {
        let sessionsDir = claudeHome + "/sessions"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let sessionFiles = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        let today = DateHelper.todayKey()
        let cachedUsage = cachedSessionUsage(for: today)
        var seen = Set<String>()
        var results: [SessionInfo] = []

        for file in sessionFiles where file.hasSuffix(".json") {
            let metaPath = sessionsDir + "/" + file
            guard let metaData = fm.contents(atPath: metaPath),
                  let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  let sessionId = meta["sessionId"] as? String else { continue }

            guard seen.insert(sessionId).inserted else { continue }

            let usage = cachedUsage[sessionId]
            let tokens = usage?.tokens ?? 0
            let messages = usage?.messages ?? 0
            let model = usage?.model
            guard tokens > 0 || messages > 0 else { continue }

            let displayId = SessionIdDisplay.format(sessionId)
            let cwd = meta["cwd"] as? String ?? ""
            let detail = cwd.isEmpty ? nil : cwd

            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: detail,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true,
                model: model,
                todayCost: usage.map { PricingService.shared.cost(of: $0.buckets) } ?? .zero,
                cacheReadTokens: usage?.cacheReadTokens ?? 0
            ))
        }

        return results.sorted { $0.todayTokens > $1.todayTokens }
    }

    private struct CachedSessionUsage {
        var tokens = 0
        var messages = 0
        var model: String?
        /// 该 session 今日的计费分桶（与 tokens 同源：顶层优先，其次嵌套明细）
        var buckets: [String: ModelBuckets] = [:]
        /// 分桶中的缓存读合计（「包含缓存读」展示用）
        var cacheReadTokens: Int {
            buckets.values.reduce(0) { $0 + $1.cacheRead }
        }
    }

    private func cachedSessionUsage(for dateKey: String) -> [String: CachedSessionUsage] {
        var result: [String: CachedSessionUsage] = [:]

        // Top-level files have always been scanned for tool totals; reuse those
        // contributions first so the detail result retains the old lookup order.
        for (path, dates) in fileDailyContrib {
            guard let usage = dates[dateKey] else { continue }
            let sessionId = sessionId(fromJSONLPath: path)
            guard !sessionId.isEmpty, result[sessionId] == nil else { continue }
            result[sessionId] = CachedSessionUsage(
                tokens: usage.tokens,
                messages: usage.messages,
                model: fileLastModel[path]?[dateKey],
                buckets: fileBucketContrib[path]?[dateKey] ?? [:]
            )
        }

        // Nested files remain detail-only, matching the baseline aggregation
        // boundary while preserving recursive session discovery.
        for (path, dates) in nestedDailyContrib {
            guard let usage = dates[dateKey] else { continue }
            let sessionId = sessionId(fromJSONLPath: path)
            guard !sessionId.isEmpty, result[sessionId] == nil else { continue }
            result[sessionId] = CachedSessionUsage(
                tokens: usage.tokens,
                messages: usage.messages,
                model: nestedLastModel[path]?[dateKey],
                buckets: nestedBucketContrib[path]?[dateKey] ?? [:]
            )
        }
        return result
    }

    private func sessionId(fromJSONLPath path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        guard filename.hasSuffix(".jsonl") else { return "" }
        return String(filename.dropLast(".jsonl".count))
    }
}
