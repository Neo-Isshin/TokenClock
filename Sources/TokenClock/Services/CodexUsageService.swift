import Foundation
#if os(Linux) || os(Windows)
import CSQLite
#else
import SQLite3
#endif

/// 从 Codex CLI 读取 token 使用数据
/// Token 计数优先使用 last_token_usage，并用累计 total_token_usage 验证是否推进；
/// 子代理 rollout 开头复制的父任务历史会按父子关系去重。total_tokens 已包含
/// cached_input_tokens，因此主用量必须减去缓存输入；reasoning 已包含在 output 中。
/// Session 列表从 SQLite threads 表读取
final class CodexUsageService: @unchecked Sendable {
    private static let relevantLineNeedles = [
        Data("\"type\":\"session_meta\"".utf8),
        Data("\"type\":\"token_count\"".utf8),
        Data("\"type\":\"turn_context\"".utf8),
        Data("\"type\":\"thread_settings_applied\"".utf8),
    ]
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]
    private var dailyCache: [String: Int] = [:]
    private var recentEntries: [RecentEntry] = []
    private var sessionMessagesByDate: [String: [String: Int]] = [:]
    private var sessionTokensByDate: [String: [String: Int]] = [:]
    /// dateKey → 归一化模型名 → 计费分桶（工具级费用，与 dailyData 同口径重建）
    private var dailyModelBuckets: [String: [String: ModelBuckets]] = [:]
    /// dateKey → request records. Cost must stay request-granular for long-context tiers.
    private var dailyRequests: [String: [ModelUsageRequest]] = [:]
    /// dateKey → sessionId → 归一化模型名 → 计费分桶（session 级费用）
    private var sessionBucketsByDate: [String: [String: [String: ModelBuckets]]] = [:]
    private var sessionRequestsByDate: [String: [String: [ModelUsageRequest]]] = [:]
    /// 每个 session 的代表模型（按 token 占比最高的那个）。
    /// Codex rollout 里模型由 turn_context 事件声明，同一 session 切换模型时取用量最大的。
    private var sessionModels: [String: String] = [:]

    private struct RawUsage: Equatable, Sendable {
        var input: Int
        var cachedInput: Int
        var output: Int
        var reasoningOutput: Int
        var total: Int

        var isEmpty: Bool {
            input <= 0 && cachedInput <= 0 && output <= 0 && reasoningOutput <= 0 && total <= 0
        }

        func subtracting(_ previous: RawUsage?) -> RawUsage {
            guard let previous else { return self }
            return RawUsage(
                input: max(0, input - previous.input),
                cachedInput: max(0, cachedInput - previous.cachedInput),
                output: max(0, output - previous.output),
                reasoningOutput: max(0, reasoningOutput - previous.reasoningOutput),
                total: max(0, total - previous.total)
            )
        }
    }

    private struct TimestampedUsage: Equatable, Sendable {
        let timestamp: Date
        let usage: RawUsage
    }

    private struct ParsedUsageEvent: Sendable {
        let timestamp: Date
        let usage: RawUsage
        let model: String?
        let serviceTier: PricingServiceTier
    }

    private struct ReplaySignature: Equatable, Sendable {
        let parentSessionId: String?
        let count: Int
        let last: TimestampedUsage?

        static let none = ReplaySignature(parentSessionId: nil, count: 0, last: nil)
    }

    private struct SessionMetadata: Sendable {
        let sessionId: String
        let parentSessionId: String?
        let forkedAt: Date?
    }

    private struct RolloutDescriptor: Sendable {
        let path: String
        let metadata: FileMetadata
        let session: SessionMetadata
        let isArchived: Bool
    }

    private struct SessionMetadataCacheEntry: Sendable {
        let fileNumber: UInt64?
        let metadata: SessionMetadata
    }

    /// 每个 rollout 的解析状态。增长中的文件只读取上次 EOF 之后的字节；截断、
    /// 原地替换、父历史变化或重放关系变化时才重读单个文件。
    private struct JSONLFileState {
        var fileSize: UInt64 = 0
        var modificationDate = Date.distantPast
        var fileNumber: UInt64?
        var trailingData = Data()
        var currentModel: String?
        var currentServiceTier: PricingServiceTier = .standard
        var previousTotalUsage: RawUsage?
        /// Derived usage sequence includes replayed events so descendants can match it.
        var usageSequence: [TimestampedUsage] = []
        var replaySignature: ReplaySignature = .none
        var replayMatching = false
        var replayFallbackPending: ParsedUsageEvent?
        var replayBurstLastTimestamp: Date?
        var replayFallbackResolved = false
        var dailyTokens: [String: Int] = [:]
        var dailyMessages: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        var hourlyTokens: [String: Int] = [:]
        var hourlyMessages: [String: Int] = [:]
        var recentEntries: [RecentEntry] = []
        var modelTokens: [String: Int] = [:]
        /// dateKey → 归一化模型名 → 计费分桶（费用估算；input 已扣除 cached 部分）
        var dailyBuckets: [String: [String: ModelBuckets]] = [:]
        var dailyRequests: [String: [ModelUsageRequest]] = [:]
    }

    private var jsonlCache: [String: JSONLFileState] = [:]
    private var sessionMetadataCache: [String: SessionMetadataCacheEntry] = [:]

    private let fm = FileManager.default
    private let codexHome: String
    private let configuredServiceTier: PricingServiceTier

    init(codexHome: String? = nil) {
        let resolvedHome = codexHome ?? PathConfig.codexHome()
        self.codexHome = resolvedHome
        self.configuredServiceTier = Self.readConfiguredServiceTier(codexHome: resolvedHome)
    }

    func fullScan() {
        jsonlCache = [:]
        scanJSONL()
    }

    func incrementalScan() {
        scanJSONL()
    }

    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let d = dailyData[DateHelper.todayKey()]
        let total = d?.tokens ?? 0
        let cache = dailyCache[DateHelper.todayKey()] ?? 0
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

    // MARK: - JSONL 扫描（tokens + messages + cache）

    private func scanJSONL() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(AppConfig.Scan.codexSessionLookbackDays - 1),
            to: startOfToday
        ) ?? startOfToday
        let descriptors = discoverRollouts(modifiedSince: cutoff)
        guard !descriptors.isEmpty else {
            jsonlCache.removeAll()
            rebuildAggregates()
            return
        }

        var livePaths = Set<String>()
        for descriptor in topologicallySorted(descriptors) {
            let path = descriptor.path
            let metadata = descriptor.metadata
            livePaths.insert(path)
            let replayPrefix = replayPrefix(for: descriptor, descriptors: descriptors)
            let signature = ReplaySignature(
                parentSessionId: descriptor.session.parentSessionId,
                count: replayPrefix.count,
                last: replayPrefix.last
            )
            if var state = jsonlCache[path] {
                flushPendingReplayIfSettled(state: &state)
                let sameFile = state.fileNumber == nil || metadata.fileNumber == nil
                    || state.fileNumber == metadata.fileNumber
                if state.replaySignature != signature {
                    jsonlCache[path] = parseJSONLFile(
                        descriptor: descriptor,
                        replayPrefix: replayPrefix,
                        signature: signature
                    )
                } else if sameFile, metadata.size > state.fileSize {
                    appendJSONLFile(
                        path: path,
                        metadata: metadata,
                        replayPrefix: replayPrefix,
                        state: &state
                    )
                    jsonlCache[path] = state
                } else if sameFile,
                          metadata.size == state.fileSize,
                          metadata.modificationDate == state.modificationDate {
                    jsonlCache[path] = state
                    continue
                } else {
                    jsonlCache[path] = parseJSONLFile(
                        descriptor: descriptor,
                        replayPrefix: replayPrefix,
                        signature: signature
                    )
                }
            } else {
                jsonlCache[path] = parseJSONLFile(
                    descriptor: descriptor,
                    replayPrefix: replayPrefix,
                    signature: signature
                )
            }
        }

        jsonlCache = jsonlCache.filter { livePaths.contains($0.key) }
        rebuildAggregates()
    }

    private func parseJSONLFile(
        descriptor: RolloutDescriptor,
        replayPrefix: [TimestampedUsage],
        signature: ReplaySignature
    ) -> JSONLFileState {
        var state = JSONLFileState(
            modificationDate: descriptor.metadata.modificationDate,
            fileNumber: descriptor.metadata.fileNumber,
            currentServiceTier: configuredServiceTier,
            replaySignature: signature,
            replayMatching: !replayPrefix.isEmpty
        )
        appendJSONLFile(
            path: descriptor.path,
            metadata: descriptor.metadata,
            replayPrefix: replayPrefix,
            state: &state
        )
        return state
    }

    private func appendJSONLFile(
        path: String,
        metadata: FileMetadata,
        replayPrefix: [TimestampedUsage],
        state: inout JSONLFileState
    ) {
        let oldOffset = state.fileSize
        let recentCutoff = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
        guard let result = JSONLLineReader.read(
            path: path,
            from: oldOffset,
            prefix: state.trailingData,
            matchingAny: Self.relevantLineNeedles,
            onLine: {
                processJSONLLine(
                    $0,
                    recentCutoff: recentCutoff,
                    replayPrefix: replayPrefix,
                    state: &state
                )
            }
        ) else { return }

        state.fileSize = result.offset
        state.trailingData = JSONLLineReader.consumeCompleteTrailingLine(
            result.trailingData,
            onLine: {
                processJSONLLine(
                    $0,
                    recentCutoff: recentCutoff,
                    replayPrefix: replayPrefix,
                    state: &state
                )
            }
        )
        if let pending = state.replayFallbackPending,
           Date().timeIntervalSince(metadata.modificationDate) > 1 {
            state.replayFallbackPending = nil
            state.replayFallbackResolved = true
            accumulate(pending, recentCutoff: recentCutoff, state: &state)
        }
        state.recentEntries.removeAll { $0.timestamp < recentCutoff }
        state.modificationDate = metadata.modificationDate
        state.fileNumber = metadata.fileNumber
    }

    private func flushPendingReplayIfSettled(state: inout JSONLFileState) {
        guard let pending = state.replayFallbackPending,
              Date().timeIntervalSince(state.modificationDate) > 1 else { return }
        state.replayFallbackPending = nil
        state.replayFallbackResolved = true
        accumulate(
            pending,
            recentCutoff: Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds),
            state: &state
        )
    }

    private func processJSONLLine(
        _ line: String,
        recentCutoff: Date,
        replayPrefix: [TimestampedUsage],
        state: inout JSONLFileState
    ) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        let payloadType = payload["type"] as? String

        if payloadType == "turn_context" || object["type"] as? String == "turn_context" {
            if let model = codexModel(fromPayload: payload) { state.currentModel = model }
            return
        }
        if payloadType == "thread_settings_applied" {
            if let tier = codexServiceTier(fromPayload: payload) { state.currentServiceTier = tier }
            return
        }
        guard payloadType == "token_count",
              let timestamp = object["timestamp"] as? String,
              let date = DateHelper.parseISO8601(timestamp),
              let info = payload["info"] as? [String: Any],
              let usage = advancingUsage(info: info, state: &state), !usage.isEmpty else { return }

        let contextWindow = (info["model_context_window"] as? NSNumber)?.intValue
            ?? extractInt(from: line, key: "\"model_context_window\"")
        let modelForTurn = codexModel(fromPayload: payload)
            ?? codexModel(fromPayload: info)
            ?? state.currentModel
            ?? (contextWindow == 258400 ? "gpt-5.5" : nil)
        let parsedEvent = ParsedUsageEvent(
            timestamp: date,
            usage: usage,
            model: modelForTurn,
            serviceTier: state.currentServiceTier
        )
        let sequenceEvent = TimestampedUsage(timestamp: date, usage: usage)
        let eventIndex = state.usageSequence.count
        state.usageSequence.append(sequenceEvent)
        if state.replayMatching, eventIndex < replayPrefix.count {
            if replayPrefix[eventIndex].usage == usage {
                if eventIndex + 1 == replayPrefix.count { state.replayMatching = false }
                return
            }
            state.replayMatching = false
            if eventIndex > 0 { state.replayFallbackResolved = true }
        }

        // Legacy forks sometimes rewrite the inherited prefix instead of preserving its
        // usage tuples. Two or more leading events within one second form a replay burst;
        // the child's first real request follows after a real pause.
        if let previous = state.replayBurstLastTimestamp {
            let gap = date.timeIntervalSince(previous)
            if (0...1).contains(gap) {
                state.replayBurstLastTimestamp = date
                return
            }
            state.replayBurstLastTimestamp = nil
            state.replayFallbackResolved = true
        } else if let pending = state.replayFallbackPending {
            state.replayFallbackPending = nil
            let gap = date.timeIntervalSince(pending.timestamp)
            if (0...1).contains(gap) {
                state.replayBurstLastTimestamp = date
                return
            }
            state.replayFallbackResolved = true
            accumulate(pending, recentCutoff: recentCutoff, state: &state)
        } else if state.replaySignature.parentSessionId != nil,
                  !state.replayFallbackResolved,
                  eventIndex == 0 {
            state.replayFallbackPending = parsedEvent
            return
        } else {
            state.replayFallbackResolved = true
        }

        accumulate(parsedEvent, recentCutoff: recentCutoff, state: &state)
    }

    private func accumulate(
        _ event: ParsedUsageEvent,
        recentCutoff: Date,
        state: inout JSONLFileState
    ) {
        let usage = event.usage
        let cached = usage.cachedInput
        let tokens = TokenAccounting.excludingCacheRead(inclusiveTotal: usage.total, cacheRead: cached)
        guard tokens > 0 else { return }
        let dateKey = DateHelper.dateKey(from: event.timestamp)
        let hourKey = DateHelper.hourKey(from: event.timestamp)
        guard !dateKey.isEmpty, !hourKey.isEmpty else { return }

        state.dailyTokens[dateKey, default: 0] += tokens
        state.dailyMessages[dateKey, default: 0] += 1
        state.dailyCached[dateKey, default: 0] += cached
        state.hourlyTokens[hourKey, default: 0] += tokens
        state.hourlyMessages[hourKey, default: 0] += 1
        if event.timestamp >= recentCutoff {
            state.recentEntries.append(RecentEntry(timestamp: event.timestamp, tokens: tokens))
        }
        if let rawModel = event.model { state.modelTokens[rawModel, default: 0] += tokens }
        if let model = ModelNormalizer.normalize(event.model) {
            let buckets = ModelBuckets(
                input: max(0, usage.input - cached),
                output: usage.output,
                cacheRead: cached,
                cacheWrite: 0
            )
            state.dailyBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(buckets)
            state.dailyRequests[dateKey, default: []].append(ModelUsageRequest(
                model: model,
                buckets: buckets,
                contextInputTokens: usage.input,
                serviceTier: event.serviceTier
            ))
        }
    }

    // MARK: - Rollout relationships and replay filtering

    /// Discover recent active/archived rollouts, then pull in older ancestors needed to
    /// identify inherited subagent history. Active copies win over archived duplicates.
    private func discoverRollouts(modifiedSince cutoff: Date) -> [RolloutDescriptor] {
        var preferredBySession: [String: (path: String, metadata: FileMetadata, archived: Bool)] = [:]
        for (directory, archived) in [
            (codexHome + "/sessions", false),
            (codexHome + "/archived_sessions", true),
        ] {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                  let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: directory, isDirectory: true),
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                      let sessionId = sessionId(fromJSONLPath: url.path),
                      let metadata = fileMetadata(at: url.path) else { continue }
                if let existing = preferredBySession[sessionId], !existing.archived {
                    continue
                }
                preferredBySession[sessionId] = (url.path, metadata, archived)
            }
        }

        var descriptors: [String: RolloutDescriptor] = [:]
        var queue = preferredBySession.compactMap { sessionId, file in
            file.metadata.modificationDate >= cutoff ? sessionId : nil
        }
        var visited = Set<String>()
        while let sessionId = queue.popLast() {
            guard visited.insert(sessionId).inserted,
                  let file = preferredBySession[sessionId] else { continue }
            let session = cachedSessionMetadata(
                path: file.path,
                fileMetadata: file.metadata,
                fallbackSessionId: sessionId
            )
            descriptors[sessionId] = RolloutDescriptor(
                path: file.path,
                metadata: file.metadata,
                session: session,
                isArchived: file.archived
            )
            if let parent = session.parentSessionId, preferredBySession[parent] != nil {
                queue.append(parent)
            }
        }
        let liveMetadataPaths = Set(preferredBySession.values.map(\.path))
        sessionMetadataCache = sessionMetadataCache.filter { liveMetadataPaths.contains($0.key) }
        return Array(descriptors.values)
    }

    private func cachedSessionMetadata(
        path: String,
        fileMetadata: FileMetadata,
        fallbackSessionId: String
    ) -> SessionMetadata {
        if let cached = sessionMetadataCache[path],
           cached.fileNumber == nil || fileMetadata.fileNumber == nil
            || cached.fileNumber == fileMetadata.fileNumber {
            return cached.metadata
        }
        let metadata = readSessionMetadata(path: path, fallbackSessionId: fallbackSessionId)
        sessionMetadataCache[path] = SessionMetadataCacheEntry(
            fileNumber: fileMetadata.fileNumber,
            metadata: metadata
        )
        return metadata
    }

    private func readSessionMetadata(path: String, fallbackSessionId: String) -> SessionMetadata {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return SessionMetadata(sessionId: fallbackSessionId, parentSessionId: nil, forkedAt: nil)
        }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            data.append(chunk)
            if data.contains(0x0A) { break }
        }
        for line in data.split(separator: 0x0A) where line.range(of: Data("\"session_meta\"".utf8)) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let id = payload["id"] as? String ?? fallbackSessionId
            var parent = payload["parent_id"] as? String
                ?? payload["parent_thread_id"] as? String
            if parent == nil,
               let source = payload["source"] as? [String: Any],
               let subagent = source["subagent"] as? [String: Any],
               let spawn = subagent["thread_spawn"] as? [String: Any] {
                parent = spawn["parent_thread_id"] as? String
            }
            let forkedAt = (object["timestamp"] as? String).flatMap(DateHelper.parseISO8601)
            return SessionMetadata(sessionId: id, parentSessionId: parent, forkedAt: forkedAt)
        }
        return SessionMetadata(sessionId: fallbackSessionId, parentSessionId: nil, forkedAt: nil)
    }

    private func topologicallySorted(_ descriptors: [RolloutDescriptor]) -> [RolloutDescriptor] {
        let byId = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.session.sessionId, $0) })
        var visiting = Set<String>()
        var visited = Set<String>()
        var result: [RolloutDescriptor] = []

        func visit(_ id: String) {
            guard !visited.contains(id), visiting.insert(id).inserted, let descriptor = byId[id] else { return }
            if let parent = descriptor.session.parentSessionId { visit(parent) }
            visiting.remove(id)
            visited.insert(id)
            result.append(descriptor)
        }
        for id in byId.keys.sorted() { visit(id) }
        return result
    }

    private func replayPrefix(
        for descriptor: RolloutDescriptor,
        descriptors: [RolloutDescriptor]
    ) -> [TimestampedUsage] {
        guard let parentId = descriptor.session.parentSessionId,
              let parentPath = descriptors.first(where: { $0.session.sessionId == parentId })?.path,
              let parent = jsonlCache[parentPath] else { return [] }
        guard let forkedAt = descriptor.session.forkedAt else { return parent.usageSequence }
        return parent.usageSequence.prefix { $0.timestamp <= forkedAt }.map { $0 }
    }

    // MARK: - Usage decoding

    private func advancingUsage(info: [String: Any], state: inout JSONLFileState) -> RawUsage? {
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(rawUsage)
        let cumulative = (info["total_token_usage"] as? [String: Any]).flatMap(rawUsage)
        let cumulativeAdvanced = cumulative.map { state.previousTotalUsage != $0 } ?? true
        let usage: RawUsage?
        if cumulativeAdvanced, let last {
            usage = last
        } else if let cumulative {
            usage = cumulative.subtracting(state.previousTotalUsage)
        } else {
            usage = nil
        }
        if let cumulative { state.previousTotalUsage = cumulative }
        return usage
    }

    private func rawUsage(_ object: [String: Any]) -> RawUsage? {
        let input = (object["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = (object["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (object["output_tokens"] as? NSNumber)?.intValue ?? 0
        let reasoning = (object["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0
        let reportedTotal = (object["total_tokens"] as? NSNumber)?.intValue ?? 0
        let total = reportedTotal > 0 ? reportedTotal : input + output
        let result = RawUsage(
            input: max(0, input),
            cachedInput: max(0, cached),
            output: max(0, output),
            reasoningOutput: max(0, reasoning),
            total: max(0, total)
        )
        return result.isEmpty ? nil : result
    }

    private func codexServiceTier(fromPayload payload: [String: Any]) -> PricingServiceTier? {
        let raw = (payload["thread_settings"] as? [String: Any])?["service_tier"] as? String
            ?? payload["service_tier"] as? String
        guard let value = raw?.lowercased() else { return nil }
        switch value {
        case "fast", "priority": return .priority
        case "default", "standard": return .standard
        default: return .standard // an unknown explicit tier must not inherit a stale premium
        }
    }

    private static func readConfiguredServiceTier(codexHome: String) -> PricingServiceTier {
        let path = URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"(?m)^\s*service_tier\s*=\s*\"([^\"]+)\""#
              ),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return .standard }
        switch text[range].lowercased() {
        case "priority", "fast": return .priority
        default: return .standard
        }
    }

    private func rebuildAggregates() {
        dailyData.removeAll(keepingCapacity: true)
        hourlyData.removeAll(keepingCapacity: true)
        dailyCache.removeAll(keepingCapacity: true)
        recentEntries.removeAll(keepingCapacity: true)
        sessionMessagesByDate.removeAll(keepingCapacity: true)
        sessionTokensByDate.removeAll(keepingCapacity: true)
        dailyModelBuckets.removeAll(keepingCapacity: true)
        dailyRequests.removeAll(keepingCapacity: true)
        sessionBucketsByDate.removeAll(keepingCapacity: true)
        sessionRequestsByDate.removeAll(keepingCapacity: true)
        sessionModels.removeAll(keepingCapacity: true)

        for (path, state) in jsonlCache {
            for (dateKey, tokens) in state.dailyTokens {
                dailyData[dateKey, default: DayUsage(tokens: 0, messages: 0)].tokens += tokens
                dailyData[dateKey]!.messages += state.dailyMessages[dateKey] ?? 0
                dailyCache[dateKey, default: 0] += state.dailyCached[dateKey] ?? 0
            }
            for (hourKey, tokens) in state.hourlyTokens {
                hourlyData[hourKey, default: HourlyUsage(tokens: 0, messages: 0)].tokens += tokens
                hourlyData[hourKey]!.messages += state.hourlyMessages[hourKey] ?? 0
            }
            for (dateKey, models) in state.dailyBuckets {
                for (model, b) in models {
                    dailyModelBuckets[dateKey, default: [:]][model, default: ModelBuckets()].merge(b)
                }
            }
            for (dateKey, requests) in state.dailyRequests {
                dailyRequests[dateKey, default: []].append(contentsOf: requests)
            }
            recentEntries.append(contentsOf: state.recentEntries)

            guard let sessionId = sessionId(fromJSONLPath: path), !sessionId.isEmpty else { continue }
            for (dateKey, tokens) in state.dailyTokens {
                sessionMessagesByDate[dateKey, default: [:]][sessionId, default: 0] += state.dailyMessages[dateKey] ?? 0
                sessionTokensByDate[dateKey, default: [:]][sessionId, default: 0] += tokens
            }
            for (dateKey, models) in state.dailyBuckets {
                for (model, b) in models {
                    sessionBucketsByDate[dateKey, default: [:]][sessionId, default: [:]][model, default: ModelBuckets()].merge(b)
                }
            }
            for (dateKey, requests) in state.dailyRequests {
                sessionRequestsByDate[dateKey, default: [:]][sessionId, default: []].append(contentsOf: requests)
            }
            if let dominant = state.modelTokens.max(by: { $0.value < $1.value })?.key {
                sessionModels[sessionId] = dominant
            }
        }

        recentEntries.sort { $0.timestamp < $1.timestamp }
    }

    // MARK: - 费用估算

    /// 今日按归一化模型聚合的计费分桶（保留分桶而非金额，价格更新后无需重扫日志）
    func todayModelBuckets() -> [String: ModelBuckets] {
        dailyModelBuckets[DateHelper.todayKey()] ?? [:]
    }

    /// 今日工具级估算费用
    func todayCost() -> CostEstimate {
        PricingService.shared.cost(of: dailyRequests[DateHelper.todayKey()] ?? [])
    }

    /// 今日缓存读 token 总数（dailyCache 累计的 cached_input_tokens；「包含缓存读」展示用）
    func todayCacheReadTokens() -> Int {
        dailyCache[DateHelper.todayKey()] ?? 0
    }

    private struct FileMetadata {
        let size: UInt64
        let modificationDate: Date
        let fileNumber: UInt64?
    }

    private func fileMetadata(at path: String) -> FileMetadata? {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attrs[.modificationDate] as? Date else { return nil }
        return FileMetadata(
            size: size,
            modificationDate: modificationDate,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func sessionId(fromJSONLPath path: String) -> String? {
        let filename = (path as NSString).lastPathComponent
        guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropFirst("rollout-".count).dropLast(".jsonl".count))
        // Codex filenames are rollout-YYYY-MM-DDTHH-MM-SS-<sessionId>.jsonl.
        guard stem.count > 20 else { return nil }
        return String(stem.dropFirst(20))
    }

    /// 从一条 turn_context 行解析模型名（多键回退，移植自 open-nova `_codex_model_from_payload`）。
    /// 回退顺序：model → model_key → model_slug → collaboration_mode.settings.model → settings.model
    private func codexModel(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return codexModel(fromPayload: payload)
    }

    private func codexModel(fromPayload payload: [String: Any]) -> String? {
        for key in ["model", "model_key", "model_slug"] {
            if let s = payload[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let s = settings["model"] as? String, !s.isEmpty {
            return s
        }
        if let settings = payload["settings"] as? [String: Any],
           let s = settings["model"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    private func extractInt(from str: String, key: String) -> Int {
        guard let range = str.range(of: key) else { return 0 }
        let after = str[range.upperBound...]
        // 跳过可能的冒号和空格
        let digits = after.drop(while: { $0 == ":" || $0 == " " })
        let numStr = digits.prefix(while: { $0.isNumber })
        return Int(numStr) ?? 0
    }

    // MARK: - 今日活跃 Session 列表（从 SQLite）

    private var dbPath: String {
        codexHome + "/state_5.sqlite"
    }

    func todaySessions() -> [SessionInfo] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let todayStart = Date().addingTimeInterval(-AppConfig.Scan.oneDaySeconds)
        let query = """
        SELECT id, updated_at_ms, cwd
        FROM threads
        WHERE updated_at_ms >= ?
        ORDER BY updated_at_ms DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, todayStart.timeIntervalSince1970 * 1000)

        let today = DateHelper.todayKey()
        let sessionMessageCounts = sessionMessagesByDate[today] ?? [:]
        let sessionTokenCounts = sessionTokensByDate[today] ?? [:]
        let sessionBuckets = sessionBucketsByDate[today] ?? [:]
        let sessionRequests = sessionRequestsByDate[today] ?? [:]
        var results: [SessionInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idPtr = sqlite3_column_text(stmt, 0)
            let sessionId = idPtr != nil ? String(cString: idPtr!) : ""
            let updatedAtMs = sqlite3_column_int64(stmt, 1)
            let cwdPtr = sqlite3_column_text(stmt, 2)

            let updatedDate = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000.0)
            let dateKey = DateHelper.dateKey(from: updatedDate)
            guard dateKey == today else { continue }

            let displayId = sessionId.isEmpty ? "unknown" : SessionIdDisplay.format(sessionId)
            let cwd = cwdPtr != nil ? String(cString: cwdPtr!) : ""
            let detail = cwd.isEmpty ? nil : cwd
            let messages = sessionMessageCount(
                for: sessionId,
                in: sessionMessageCounts,
                fallback: 1
            )
            let tokens = sessionTokenCount(
                for: sessionId,
                in: sessionTokenCounts
            )
            guard tokens > 0 else { continue }

            let matchedBuckets = sessionBucketsMatching(sessionId, in: sessionBuckets)
            let matchedRequests = sessionRequestsMatching(sessionId, in: sessionRequests)
            let sessionCacheRead = matchedBuckets.values.reduce(0) { $0 + $1.cacheRead }
            results.append(SessionInfo(
                rawId: sessionId,
                displayName: displayId,
                detail: detail,
                todayTokens: tokens,
                todayMessages: messages,
                isActive: true,
                model: sessionModel(for: sessionId, in: sessionModels),
                todayCost: PricingService.shared.cost(of: matchedRequests),
                cacheReadTokens: sessionCacheRead
            ))
        }

        return results
    }

    private func sessionMessageCount(
        for sessionId: String,
        in counts: [String: Int],
        fallback: Int
    ) -> Int {
        if let exact = counts[sessionId] { return exact }
        if let prefixMatch = counts.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return fallback
    }

    private func sessionTokenCount(
        for sessionId: String,
        in counts: [String: Int]
    ) -> Int {
        if let exact = counts[sessionId] { return exact }
        if let prefixMatch = counts.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return 0
    }

    /// 按 sessionId 查代表模型（与 token 计数采用同样的前缀容错匹配）
    private func sessionModel(for sessionId: String, in models: [String: String]) -> String? {
        if let exact = models[sessionId] { return exact }
        if let prefixMatch = models.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return nil
    }

    /// 按 sessionId 查计费分桶（同样的前缀容错匹配；未命中返回空 → 费用按 $0 处理）
    private func sessionBucketsMatching(
        _ sessionId: String,
        in buckets: [String: [String: ModelBuckets]]
    ) -> [String: ModelBuckets] {
        if let exact = buckets[sessionId] { return exact }
        if let prefixMatch = buckets.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return [:]
    }

    private func sessionRequestsMatching(
        _ sessionId: String,
        in requests: [String: [ModelUsageRequest]]
    ) -> [ModelUsageRequest] {
        if let exact = requests[sessionId] { return exact }
        if let prefixMatch = requests.first(where: { sessionId.hasPrefix($0.key) || $0.key.hasPrefix(sessionId) }) {
            return prefixMatch.value
        }
        return []
    }

}
