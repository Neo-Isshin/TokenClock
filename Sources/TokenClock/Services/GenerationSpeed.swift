import Foundation
#if canImport(Combine)
import Combine
protocol GenerationSpeedObservable: ObservableObject {}
#else
protocol GenerationSpeedObservable: AnyObject {}
#endif
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

/// Rank only completed attempts, before applying time/timing filters. This
/// replaces quadratic correlated scans without modifying the provider database.
enum ZCodeLedger {
    static let latestCompletedRowsSQL = """
    WITH latest_completed AS (
      SELECT rowid AS ledger_rowid,
        ROW_NUMBER() OVER (
          PARTITION BY logical_request_id,
            CASE WHEN logical_request_id IS NULL OR attempt_index IS NULL THEN rowid ELSE 0 END
          ORDER BY attempt_index DESC, rowid DESC
        ) AS completion_rank
      FROM model_usage WHERE status = 'completed'
    )
    """
}

struct GenerationSpeed: Hashable {
    var outputTokens = 0
    var generationSeconds = 0.0
    var sampleCount = 0
    var estimated = false
    var lastCompletedAt: Date?
    var firstTokenDelayTotal = 0.0
    var firstTokenDelayCount = 0

    var tokensPerSecond: Double? {
        guard outputTokens > 0, generationSeconds > 0, generationSeconds.isFinite else { return nil }
        let rate = Double(outputTokens) / generationSeconds
        return rate.isFinite ? rate : nil
    }
    var timeToFirstToken: Double? { firstTokenDelayCount > 0 ? firstTokenDelayTotal/Double(firstTokenDelayCount) : nil }
    var formattedTTFT: String {
        guard let value=timeToFirstToken else {return "—"}
        return value < 1 ? String(format:"%.0fms",value*1000) : value>=100 ? String(format:"%.0fs",value) : String(format:"%.2fs",value)
    }
    var formatted: String {
        guard let rate = tokensPerSecond else { return "—" }
        return String(format: "%.1f", rate)
    }
    mutating func include(_ sample: GenerationSample) {
        let (sum, overflow) = outputTokens.addingReportingOverflow(sample.outputTokens)
        guard !overflow else { return }
        outputTokens = sum
        generationSeconds += sample.seconds
        sampleCount += 1
        if let value=sample.firstTokenDelay,value.isFinite,value>=0 {
            let next=firstTokenDelayTotal+value
            if next.isFinite {firstTokenDelayTotal=next;firstTokenDelayCount += 1}
        }
        estimated = estimated || sample.estimated
        lastCompletedAt = max(lastCompletedAt ?? sample.completedAt, sample.completedAt)
    }

    var helpText: String {
        let cn=L10n.shared.language.rawValue.hasPrefix("zh")
        let latency = timeToFirstToken == nil ? (cn ? "TTFT：—（缺少可归属的请求开始/首 token 时间）" : "TTFT: — (no request-start / first-token evidence)")
            : "TTFT: \(formattedTTFT) · \(firstTokenDelayCount) " + (cn ? "个请求；独立于输出 t/s" : "requests; separate from output t/s")
        let base = L10n.shared.tr("detail.generationSpeedHelp") + "\n" + latency
        guard let lastCompletedAt else { return base }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return base + "\n" + L10n.shared.tr("detail.generationSpeedAsOf", formatter.string(from: lastCompletedAt))
    }
}

struct GenerationSample: Hashable {
    let id: String
    let model: String
    let completedAt: Date
    let outputTokens: Int
    let seconds: Double
    let estimated: Bool
    var firstTokenDelay: Double? = nil

    var valid: Bool { !id.isEmpty && !model.isEmpty && outputTokens > 0 && seconds > 0 && seconds.isFinite }
}

/// Independent of usage/cost accounting. Readers run on the provider scan queue;
/// UI callers only take the short snapshot lock and never perform I/O.
struct GenerationSpeedRefreshSchedule {
    static let interval: TimeInterval = 180
    private var lastRefresh: Date?
    private var lastTools: Set<String>?

    mutating func shouldRefresh(enabledTools: Set<String>, now: Date) -> Bool {
        if let lastRefresh, lastTools == enabledTools,
           now >= lastRefresh, now.timeIntervalSince(lastRefresh) < Self.interval {
            return false
        }
        lastRefresh = now
        lastTools = enabledTools
        return true
    }
}

final class GenerationSpeedStore: GenerationSpeedObservable, @unchecked Sendable {
    static let shared = GenerationSpeedStore()
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var samples: [String: [GenerationSample]] = [:]
    private var codex = CodexGenerationReader()
    private var sourceHomes: [String: String] = [:]
    private let scheduleLock = NSLock()
    private var schedule = GenerationSpeedRefreshSchedule()
    #if canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    #endif

    /// Native Windows/Linux usage polling may be more frequent than speed
    /// sampling. Keep expensive timing I/O on its own three-minute cadence.
    @discardableResult
    func refreshIfDue(enabledTools: Set<String>, now: Date = Date()) -> Bool {
        scheduleLock.lock()
        let due = schedule.shouldRefresh(enabledTools: enabledTools, now: now)
        scheduleLock.unlock()
        guard due else { return false }
        refresh(enabledTools: enabledTools, now: now)
        return true
    }

    func refresh(enabledTools: Set<String>, now: Date = Date()) {
        #if os(macOS)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Refresh local token generation speed")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        #endif
        scanLock.lock(); defer { scanLock.unlock() }
        if enabledTools.contains("Codex") {
            let home = PathConfig.codexHome()
            resetIfSourceChanged(provider: "Codex", home: home)
            replace(provider: "Codex", with: codex.scan(home: home, now: now), now: now)
        }
        else { clear(provider: "Codex") }
        #if !os(Linux)
        if enabledTools.contains("ZCode") {
            let home = PathConfig.zcodeHome()
            resetIfSourceChanged(provider: "ZCode", home: home)
            replace(provider: "ZCode", with: Self.zcodeSamples(home: home, now: now), now: now)
        }
        else { clear(provider: "ZCode") }
        #endif
        // Idle scans retain the last completed generation window; wall-clock
        // time without output is never added to its denominator.
        publishRefresh()
    }
    private func publishRefresh() {
        #if canImport(Combine)
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        #endif
    }
    private func resetIfSourceChanged(provider: String, home: String) {
        if let previous = sourceHomes[provider], previous != home { clear(provider: provider) }
        sourceHomes[provider] = home
    }
    func replace(provider: String, with values: [GenerationSample], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var byID = Dictionary((samples[provider] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for value in values where value.valid && value.completedAt <= now { byID[value.id] = value }
        let groups = Dictionary(grouping: byID.values, by: \.model)
        samples[provider] = groups.values.flatMap { group -> [GenerationSample] in
            guard let latest = group.map(\.completedAt).max() else { return [] }
            return group.filter { $0.completedAt >= latest.addingTimeInterval(-600) }
        }
    }
    func clear(provider: String) {
        lock.lock(); defer { lock.unlock() }
        samples.removeValue(forKey: provider)
    }
    func summary(model: String, providers: Set<String>, now: Date = Date()) -> GenerationSpeed {
        lock.lock(); let snapshot = samples; lock.unlock()
        return Self.summarize(snapshot, model: model, providers: providers, now: now)
    }
    /// Average request speed across this harness's most recent valid ten-minute
    /// window. Sum generated tokens and generation time, never average model rates.
    func summary(provider: String, now: Date = Date()) -> GenerationSpeed {
        lock.lock(); let snapshot = samples[provider] ?? []; lock.unlock()
        let candidates = snapshot.filter { $0.valid && $0.completedAt <= now }
        guard let latest = candidates.map(\.completedAt).max() else { return GenerationSpeed() }
        var result = GenerationSpeed(), seen = Set<String>()
        for sample in candidates where sample.completedAt >= latest.addingTimeInterval(-600) {
            if seen.insert(sample.id).inserted { result.include(sample) }
        }
        return result
    }
    static func summarize(_ data: [String: [GenerationSample]], model: String, providers: Set<String>, now: Date) -> GenerationSpeed {
        var result = GenerationSpeed()
        var seen = Set<String>()
        guard let canonicalModel = ModelNormalizer.normalize(model.lowercased()) else { return result }
        let candidates = providers.sorted().flatMap { provider in
            (data[provider] ?? []).filter { $0.valid && $0.completedAt <= now
                && ModelNormalizer.normalize($0.model.lowercased()) == canonicalModel }
                .map { (provider, $0) }
        }
        guard let latest = candidates.map({ $0.1.completedAt }).max() else { return result }
        let cutoff = latest.addingTimeInterval(-600)
        for (provider, sample) in candidates where sample.completedAt >= cutoff {
                guard seen.insert(provider + ":" + sample.id).inserted else { continue }
                result.include(sample)
        }
        return result
    }

    static func zcodeSamples(home: String, now: Date) -> [GenerationSample] {
        let file = home.lowercased().hasSuffix(".sqlite") || home.lowercased().hasSuffix(".db")
            ? home : home + "/cli/db/db.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        let query = ZCodeLedger.recentCompletedRowsSQL + "\n" + """
        SELECT m.logical_request_id, m.model_id, m.started_at, m.first_token_at, m.completed_at,
               m.output_tokens, m.reasoning_tokens
        FROM latest_completed latest JOIN model_usage m ON m.rowid = latest.ledger_rowid
        WHERE latest.completion_rank = 1 AND m.first_token_at IS NOT NULL
          AND m.completed_at >= ?1 AND m.completed_at <= ?2
          AND m.first_token_at >= m.started_at AND m.completed_at > m.first_token_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(statement, 2, Int64(now.timeIntervalSince1970 * 1000))
        var result: [GenerationSample] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(statement) }
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let modelPointer = sqlite3_column_text(statement, 1),
                  let model = ModelNormalizer.normalize(String(cString: modelPointer).lowercased()) else { continue }
            let output = max(0, sqlite3_column_int64(statement, 5))
            let reasoning = max(0, sqlite3_column_int64(statement, 6))
            let (generated, overflow) = output.addingReportingOverflow(reasoning)
            guard !overflow, generated <= Int64(Int.max) else { continue }
            let ended = sqlite3_column_double(statement, 4)
            let first = sqlite3_column_double(statement, 3)
            let sample = GenerationSample(id: String(cString: idPointer), model: model,
                completedAt: Date(timeIntervalSince1970: ended / 1000), outputTokens: Int(generated),
                seconds: (ended - first) / 1000, estimated: false, firstTokenDelay: (first - sqlite3_column_double(statement, 2)) / 1000)
            if sample.valid { result.append(sample) }
        }
        return stepResult == SQLITE_DONE ? result : []
    }
}

/// New Codex app-server records expose item timing. Only complete, tool-free
/// output batches are paired with advancing usage; ambiguous batches are omitted.
struct CodexGenerationParser {
    var minimumDate = Date.distantPast
    private struct Span {
        let id: String
        let start: Double
        let end: Double
    }
    private var model: String?
    private var spans: [Span] = []
    private var ambiguous = false
    private var previousOutput: Int?
    private(set) var samples: [GenerationSample] = []

    mutating func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        let type = payload["type"] as? String ?? object["type"] as? String
        if type == "turn_context" || type == "thread_settings_applied" {
            let raw = payload["model"] as? String ?? (payload["thread_settings"] as? [String: Any])?["model"] as? String
            if let next = ModelNormalizer.normalize(raw), next != model {
                spans.removeAll(); ambiguous = false; model = next
            }
            return
        }
        if type == "item_completed" {
            guard let item = payload["item"] as? [String: Any] else { ambiguous = true; return }
            guard let kind = item["type"] as? String, ["Reasoning", "AgentMessage"].contains(kind) else {
                ambiguous = true; return
            }
            guard let id = item["id"] as? String, !id.isEmpty,
                  let thread = payload["thread_id"] as? String,
                  let turn = payload["turn_id"] as? String,
                  let start = payload["started_at_ms"] as? Double,
                  let end = payload["completed_at_ms"] as? Double,
                  start.isFinite, end.isFinite, end > start else { ambiguous = true; return }
            let key = thread + ":" + turn + ":" + id
            if !spans.contains(where: { $0.id == key }) { spans.append(Span(id: key, start: start, end: end)) }
            return
        }
        guard type == "token_count", let info = payload["info"] as? [String: Any] else { return }
        defer { spans.removeAll(); ambiguous = false }
        let total = (info["total_token_usage"] as? [String: Any])?["output_tokens"] as? Int
        let last = (info["last_token_usage"] as? [String: Any])?["output_tokens"] as? Int
        var output = last
        if let total {
            defer { previousOutput = total }
            if let previousOutput {
                guard total > previousOutput else { return }
                output = total - previousOutput
            }
        }
        guard !ambiguous, !spans.isEmpty, let output, output > 0, let model,
              let timestamp = object["timestamp"] as? String,
              let recordedAt = DateHelper.parseISO8601(timestamp) else { return }
        // Merge overlapping intervals before summing: parallel item notifications
        // must not count the same generation time twice.
        let ordered = spans.sorted { $0.start < $1.start }
        var lower = ordered[0].start, upper = ordered[0].end, duration = 0.0
        for span in ordered.dropFirst() {
            if span.start <= upper { upper = max(upper, span.end) }
            else { duration += upper - lower; lower = span.start; upper = span.end }
        }
        duration += upper - lower
        let end = Date(timeIntervalSince1970: ordered.map(\.end).max()! / 1000)
        guard end >= minimumDate, end.timeIntervalSince(recordedAt) <= 0.005,
              recordedAt.timeIntervalSince(end) <= 10 else { return }
        let sample = GenerationSample(id: spans.map(\.id).sorted().joined(separator: "|"), model: model,
            completedAt: end, outputTokens: output, seconds: duration / 1000, estimated: true)
        if sample.valid { samples.append(sample) }
    }
    mutating func prune(now: Date) {
        samples.removeAll { $0.completedAt < now.addingTimeInterval(-600) }
    }
}

final class CodexGenerationReader {
    /// Cheap cold-start filter for canonical UTC logs. Noncanonical timestamps
    /// fall back to the full parser rather than being incorrectly discarded.
    static func precedesWindow(_ line: String, cutoffSecond: String) -> Bool {
        guard let key = line.range(of: "\"timestamp\":\""),
              let end = line[key.upperBound...].firstIndex(of: "\"") else { return false }
        let stamp = line[key.upperBound..<end]
        guard stamp.hasSuffix("Z"), stamp.count >= 20 else { return false }
        let second = String(stamp.prefix(19))
        guard second.count == 19, second[second.index(second.startIndex, offsetBy: 10)] == "T" else { return false }
        return second < cutoffSecond
    }
    private struct State {
        var offset: UInt64 = 0
        var tail = Data()
        var modified = Date.distantPast
        var inode: UInt64 = 0
        var parser = CodexGenerationParser()
    }
    private var root: String?
    private var states: [String: State] = [:]
    private static let needles = ["\"type\":\"item_completed\"", "\"type\":\"token_count\"",
                                   "\"type\":\"turn_context\"", "\"type\":\"thread_settings_applied\""].map { Data($0.utf8) }

    func scan(home: String, now: Date) -> [GenerationSample] {
        if root != home { root = home; states.removeAll() }
        let fm = FileManager.default
        let cutoffSecond = String(ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)).prefix(19))
        var live = Set<String>()
        for directory in ["sessions", "archived_sessions"] {
            let path = URL(fileURLWithPath: home).appendingPathComponent(directory).resolvingSymlinksInPath()
            guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let modified = attrs[.modificationDate] as? Date,
                      modified >= now.addingTimeInterval(-600) else { continue }
                live.insert(file.path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var state = states[file.path] ?? State()
                if state.inode != inode || size < state.offset || (size == state.offset && modified != state.modified) { state = State() }
                state.parser.minimumDate = now.addingTimeInterval(-600)
                if size != state.offset || modified != state.modified {
                    let coldStart = state.offset == 0
                    var previousCount: String?
                    let consume: (String) -> Void = { line in
                        if coldStart && Self.precedesWindow(line, cutoffSecond: cutoffSecond) {
                            // Native event headers precede the potentially huge
                            // tool payload. Never search that payload for an
                            // absent token_count key just to skip an old item.
                            let header = String(decoding: line.utf8.prefix(512), as: UTF8.self)
                            if header.contains("\"type\":\"item_completed\"") { return }
                            if header.contains("\"type\":\"token_count\"") { previousCount = line; return }
                            state.parser.consume(line) // model context still matters
                            return
                        }
                        if let baseline = previousCount { state.parser.consume(baseline); previousCount = nil }
                        state.parser.consume(line)
                    }
                    if let result = JSONLLineReader.read(path: file.path, from: state.offset, prefix: state.tail, matchingAny: Self.needles, onLine: consume) {
                        state.offset = result.offset
                        state.tail = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData, onLine: consume)
                        if let baseline = previousCount { state.parser.consume(baseline) }
                        state.modified = modified
                        state.inode = inode
                    }
                }
                state.parser.prune(now: now)
                states[file.path] = state
            }
        }
        states = states.filter { live.contains($0.key) }
        return states.values.flatMap { $0.parser.samples }
    }
}
