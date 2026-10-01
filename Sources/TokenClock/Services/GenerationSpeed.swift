import Foundation
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

struct GenerationSpeed: Hashable {
    var outputTokens = 0
    var generationSeconds = 0.0
    var sampleCount = 0
    var estimated = false

    var tokensPerSecond: Double? {
        guard outputTokens > 0, generationSeconds > 0, generationSeconds.isFinite else { return nil }
        let rate = Double(outputTokens) / generationSeconds
        return rate.isFinite ? rate : nil
    }
    var formatted: String {
        guard let rate = tokensPerSecond else { return "—" }
        return (estimated ? "≈" : "") + String(format: "%.1f", rate)
    }
    mutating func include(_ sample: GenerationSample) {
        let (sum, overflow) = outputTokens.addingReportingOverflow(sample.outputTokens)
        guard !overflow else { return }
        outputTokens = sum
        generationSeconds += sample.seconds
        sampleCount += 1
        estimated = estimated || sample.estimated
    }
}

struct GenerationSample: Hashable {
    let id: String
    let model: String
    let completedAt: Date
    let outputTokens: Int
    let seconds: Double
    let estimated: Bool

    var valid: Bool { !id.isEmpty && !model.isEmpty && outputTokens > 0 && seconds > 0 && seconds.isFinite }
}

/// Independent of usage/cost accounting. Readers run on the provider scan queue;
/// UI callers only take the short snapshot lock and never perform I/O.
final class GenerationSpeedStore: @unchecked Sendable {
    static let shared = GenerationSpeedStore()
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var samples: [String: [GenerationSample]] = [:]
    private var codex = CodexGenerationReader()

    func refresh(enabledTools: Set<String>, now: Date = Date()) {
        scanLock.lock(); defer { scanLock.unlock() }
        replace(provider: "Codex", with: enabledTools.contains("Codex") ? codex.scan(home: PathConfig.codexHome(), now: now) : [])
        #if !os(Linux)
        replace(provider: "ZCode", with: enabledTools.contains("ZCode") ? Self.zcodeSamples(home: PathConfig.zcodeHome(), now: now) : [])
        #endif
    }
    func replace(provider: String, with values: [GenerationSample]) {
        lock.lock(); defer { lock.unlock() }
        samples[provider] = values.filter(\.valid)
    }
    func summary(model: String, providers: Set<String>, now: Date = Date()) -> GenerationSpeed {
        lock.lock(); let snapshot = samples; lock.unlock()
        return Self.summarize(snapshot, model: model, providers: providers, now: now)
    }
    static func summarize(_ data: [String: [GenerationSample]], model: String, providers: Set<String>, now: Date) -> GenerationSpeed {
        var result = GenerationSpeed()
        var seen = Set<String>()
        let cutoff = now.addingTimeInterval(-600)
        for provider in providers.sorted() {
            for sample in data[provider] ?? [] where sample.valid && sample.model == model
                && sample.completedAt >= cutoff && sample.completedAt <= now {
                guard seen.insert(provider + ":" + sample.id).inserted else { continue }
                result.include(sample)
            }
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
        let query = """
        SELECT m.logical_request_id, m.model_id, m.started_at, m.first_token_at, m.completed_at,
               m.output_tokens, m.reasoning_tokens
        FROM model_usage m
        WHERE m.status = 'completed' AND m.first_token_at IS NOT NULL
          AND m.completed_at >= ? AND m.completed_at <= ?
          AND m.first_token_at >= m.started_at AND m.completed_at > m.first_token_at
          AND NOT EXISTS (SELECT 1 FROM model_usage newer
            WHERE newer.logical_request_id = m.logical_request_id AND newer.status = 'completed'
              AND (newer.attempt_index > m.attempt_index
                OR (newer.attempt_index = m.attempt_index AND newer.rowid > m.rowid)))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(statement, 2, Int64(now.timeIntervalSince1970 * 1000))
        var result: [GenerationSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let modelPointer = sqlite3_column_text(statement, 1),
                  let model = ModelNormalizer.normalize(String(cString: modelPointer)) else { continue }
            let output = max(0, sqlite3_column_int64(statement, 5))
            let reasoning = max(0, sqlite3_column_int64(statement, 6))
            let (generated, overflow) = output.addingReportingOverflow(reasoning)
            guard !overflow, generated <= Int64(Int.max) else { continue }
            let ended = sqlite3_column_double(statement, 4)
            let first = sqlite3_column_double(statement, 3)
            let sample = GenerationSample(id: String(cString: idPointer), model: model,
                completedAt: Date(timeIntervalSince1970: ended / 1000), outputTokens: Int(generated),
                seconds: (ended - first) / 1000, estimated: false)
            if sample.valid { result.append(sample) }
        }
        return result
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
    private var hasAnswer = false
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
                spans.removeAll(); ambiguous = false; hasAnswer = false; model = next
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
            if kind == "AgentMessage" { hasAnswer = true }
            if !spans.contains(where: { $0.id == key }) { spans.append(Span(id: key, start: start, end: end)) }
            return
        }
        guard type == "token_count", let info = payload["info"] as? [String: Any] else { return }
        defer { spans.removeAll(); ambiguous = false; hasAnswer = false }
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
        guard !ambiguous, hasAnswer, !spans.isEmpty, let output, output > 0, let model,
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
        var live = Set<String>()
        for directory in ["sessions", "archived_sessions"] {
            let path = URL(fileURLWithPath: home).appendingPathComponent(directory)
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
                    if let result = JSONLLineReader.read(path: file.path, from: state.offset, prefix: state.tail, matchingAny: Self.needles, onLine: { state.parser.consume($0) }) {
                        state.offset = result.offset
                        state.tail = JSONLLineReader.consumeCompleteTrailingLine(result.trailingData) { state.parser.consume($0) }
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
