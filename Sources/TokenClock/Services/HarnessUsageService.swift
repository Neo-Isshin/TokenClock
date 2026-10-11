import Foundation
import CoreFoundation
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif

/// Local, read-only harness integrations. No credentials, keychain prompts, or agent execution.
enum AdditionalHarness: String, CaseIterable, Sendable {
    case kiloCode, pi, omp, freebuff, commandCode

    var name: String {
        switch self {
        case .kiloCode: return "Kilo Code"
        case .pi: return "Pi"
        case .omp: return "OMP"
        case .freebuff: return "Freebuff"
        case .commandCode: return "Command Code"
        }
    }
    var abbreviation: String {
        switch self {
        case .kiloCode: return "KL"
        case .pi: return "PI"
        case .omp: return "OM"
        case .freebuff: return "FB"
        case .commandCode: return "CM"
        }
    }
    var emoji: String {
        switch self {
        case .kiloCode: return "⚡"
        case .pi: return "🥧"
        case .omp: return "🥧"
        case .freebuff: return "🦬"
        case .commandCode: return "⌘"
        }
    }
    var pathKey: SettingsKey {
        switch self {
        case .kiloCode: return .kiloCodePath
        case .pi: return .piPath
        case .omp: return .ompPath
        case .freebuff: return .freebuffPath
        case .commandCode: return .commandCodePath
        }
    }
    var unit: UsageMeasurementUnit { self == .freebuff ? .requests : .tokens }
    var limitation: String? {
        self == .freebuff ? L10n.shared.tr("harness.freebuffLimitation") : nil
    }

    func roots(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
               includeCustom: Bool = true) -> [String] {
        if includeCustom, let custom = UserDefaults.standard.string(for: pathKey), !custom.isEmpty {
            #if os(Windows)
            return [WindowsProviderCatalog.expand(custom)]
            #else
            return [(custom as NSString).expandingTildeInPath]
            #endif
        }
        func env(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return (value as NSString).expandingTildeInPath
        }
        switch self {
        case .pi:
            // OMP shares PI_CODING_AGENT_DIR; never claim its default folder as Pi as well.
            let override = env("PI_CODING_AGENT_DIR")
            // A shared override with an arbitrary name carries no harness identity.
            // Such roots must be assigned explicitly in TokenClock Settings.
            return [override.flatMap { $0.contains("/.pi/") ? $0 : nil } ?? home + "/.pi/agent"]
        case .omp:
            let requestedConfigName = env("PI_CONFIG_DIR") ?? ".omp"
            let configName = requestedConfigName == ".pi" ? ".omp" : requestedConfigName
            let configRoot = configName.hasPrefix("/") ? configName : home + "/" + configName
            var paths = [configRoot + "/agent", configRoot + "/profiles"]
            for key in ["XDG_DATA_HOME", "XDG_STATE_HOME"] {
                if let root = env(key) { paths.append(root + "/omp") }
            }
            if let override = env("PI_CODING_AGENT_DIR"), override.contains(".omp") || override.contains("/omp/") { paths.insert(override, at: 0) }
            return paths
        case .commandCode: return [home + "/.commandcode/projects"]
        case .freebuff: return [env("FREEBUFF_CONFIG_DIR") ?? home + "/.config/manicode/projects"]
        case .kiloCode:
            var paths = [(env("XDG_DATA_HOME") ?? home + "/.local/share") + "/kilo"]
            #if os(macOS)
            let config = home + "/Library/Application Support"
            #elseif os(Windows)
            let config = env("APPDATA") ?? home + "/AppData/Roaming"
            #else
            let config = env("XDG_CONFIG_HOME") ?? home + "/.config"
            #endif
            for app in ["Code", "Code - Insiders", "Cursor", "VSCodium"] {
                paths.append(config + "/" + app + "/User/globalStorage/kilocode.kilo-code/tasks")
            }
            paths.append(home + "/.vscode-server/data/User/globalStorage/kilocode.kilo-code/tasks")
            return paths
        }
    }

    static func byName(_ name: String) -> Self? { allCases.first { $0.name == name } }

    /// One-time upgrade: add only tools with local records. Preserve explicitly disabled tools thereafter.
    static func enabled(saved: [String]?, defaults: [String]) -> Set<String> {
        var result = Set(saved ?? (defaults + allCases.map(\.name)))
        let key = "TC_additionalHarnessMigration_v1"
        if let saved, !saved.isEmpty, !UserDefaults.standard.bool(forKey: key) {
            for harness in allCases where !HarnessUsageService.sourceFiles(roots: harness.roots(), harness: harness).isEmpty {
                result.insert(harness.name)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.setStringArray(Array(result).sorted(), for: .enabledTools)
        return result
    }
}

/// Parses request receipts, not context occupancy or cumulative session counters.
/// Metadata-cached snapshots are replaced atomically; deleted files are evicted.
final class HarnessUsageService: @unchecked Sendable {
    struct Receipt {
        var id: String
        var session: String
        var name: String
        var model: String?
        var date: Date
        var buckets: ModelBuckets
        var path: String
        var requestsOnly = false
        var tokens: Int { requestsOnly ? 0 : buckets.input + buckets.output + buckets.cacheWrite }
        var cost: CostEstimate {
            guard !requestsOnly, let model else { return .unavailable }
            return PricingService.shared.cost(of: [ModelUsageRequest(model: model, buckets: buckets,
                contextInputTokens: buckets.input + buckets.cacheRead + buckets.cacheWrite)])
        }
    }
    private struct CachedFile {
        var modified: Date
        var size: UInt64
        var receipts: [Receipt]
    }
    let harness: AdditionalHarness
    private let overrideRoots: [String]?
    private var files: [String: CachedFile] = [:]
    private var receipts: [Receipt] = []
    private(set) var dailyData: [String: DayUsage] = [:]
    private(set) var hourlyData: [String: HourlyUsage] = [:]

    init(_ harness: AdditionalHarness, roots: [String]? = nil) {
        self.harness = harness
        overrideRoots = roots
    }
    func fullScan() { files.removeAll(); receipts = []; dailyData = [:]; hourlyData = [:]; incrementalScan() }
    func incrementalScan() {
        let paths = Self.sourceFiles(roots: overrideRoots ?? harness.roots(), harness: harness)
        var live = Set<String>()
        var changed = false
        for path in paths {
            live.insert(path)
            guard let attrs = FileManager.default.attributes(path), let modified = attrs[.modificationDate] as? Date else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            // SQLite changes can be entirely in WAL; don't use only the main file's mtime.
            let walModified = FileManager.default.attributes(path + "-wal")?[.modificationDate] as? Date ?? .distantPast
            let metaPath = harness == .freebuff
                ? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("chat-meta.json").path
                : URL(fileURLWithPath: path).deletingPathExtension().path + ".meta.json"
            let metaModified = [.commandCode, .freebuff].contains(harness) ? FileManager.default.attributes(metaPath)?[.modificationDate] as? Date ?? .distantPast : .distantPast
            let stamp = max(max(modified, walModified), metaModified)
            let walSize = (FileManager.default.attributes(path + "-wal")?[.size] as? NSNumber)?.uint64Value ?? 0
            let signatureSize = size &+ walSize
            if let old = files[path], old.modified == stamp, old.size == signatureSize { continue }
            guard let parsed = parse(path) else { continue } // Keep last complete snapshot on I/O/schema errors.
            files[path] = CachedFile(modified: stamp, size: signatureSize, receipts: parsed)
            changed = true
        }
        if files.keys.contains(where: { !live.contains($0) }) { changed = true }
        files = files.filter { live.contains($0.key) }
        guard changed else { return }
        var seen = Set<String>()
        receipts = []
        // Original files precede cloned transcripts. Stable request IDs prevent fork replay double counting.
        for path in files.keys.sorted() {
            for receipt in files[path]?.receipts ?? [] where seen.insert(receipt.id).inserted { receipts.append(receipt) }
        }
        dailyData = [:]; hourlyData = [:]
        for receipt in receipts {
            let day = DateHelper.dateKey(from: receipt.date), hour = DateHelper.hourKey(from: receipt.date)
            var d = dailyData[day] ?? DayUsage(tokens: 0, messages: 0)
            d.tokens += receipt.tokens; d.messages += 1; dailyData[day] = d
            if !receipt.requestsOnly {
                var h = hourlyData[hour] ?? HourlyUsage(tokens: 0, messages: 0)
                h.tokens += receipt.tokens; h.messages += 1
                h.recordMetadata(tokens: receipt.tokens, cache: receipt.buckets.cacheRead, model: receipt.model, cost: receipt.cost)
                hourlyData[hour] = h
            }
        }
    }
    private var today: [Receipt] { receipts.filter { DateHelper.dateKey(from: $0.date) == DateHelper.todayKey() } }
    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double) {
        let values = today, tokens = values.reduce(0) { $0 + $1.tokens }
        return (tokens, values.count, TokenAccounting.cacheReadShare(freshTokens: tokens, cacheRead: values.reduce(0) { $0 + $1.buckets.cacheRead }))
    }
    func todayCacheReadTokens() -> Int { today.reduce(0) { $0 + $1.buckets.cacheRead } }
    private static func estimate(_ values: [Receipt]) -> CostEstimate {
        var result = CostEstimate.unavailable
        var missing = false
        for value in values { let cost = value.cost; missing = missing || !cost.available; result.merge(cost) }
        if missing && result.available { result.complete = false }
        return result
    }
    func todayCost() -> CostEstimate { Self.estimate(today) }
    func currentHourTokens() -> Int { hourlyData[DateHelper.currentHourKey()]?.tokens ?? 0 }
    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let recent = receipts.filter { $0.date >= Date().addingTimeInterval(-Double(minutes) * 60) }
        return (recent.reduce(0) { $0 + $1.tokens }, recent.count)
    }
    func isActive() -> Bool { receipts.contains { $0.date >= Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds) } }
    func todaySessions() -> [SessionInfo] {
        Dictionary(grouping: today, by: \.session).map { id, values in
            let cost = Self.estimate(values)
            var models: [String: SessionModelUsage] = [:]
            for value in values {
                let key = value.model ?? "Unknown"
                let old = models[key]
                var modelCost = old?.cost ?? .unavailable; modelCost.merge(value.cost)
                models[key] = SessionModelUsage(model: key, tokens: (old?.tokens ?? 0) + value.tokens,
                    messages: (old?.messages ?? 0) + 1, cost: modelCost,
                    cacheReadTokens: (old?.cacheReadTokens ?? 0) + value.buckets.cacheRead)
            }
            return SessionInfo(rawId: id, displayName: values.last?.name ?? id, detail: harness.limitation,
                todayTokens: values.reduce(0) { $0 + $1.tokens }, todayMessages: values.count,
                isActive: values.contains { $0.date >= Date().addingTimeInterval(-AppConfig.Scan.activeThresholdSeconds) },
                source: harness == .freebuff ? "Local responses · tokens unavailable" : nil,
                model: models.count == 1 ? models.keys.first : nil, todayCost: cost,
                cacheReadTokens: values.reduce(0) { $0 + $1.buckets.cacheRead },
                modelBreakdown: models.values.sorted { $0.model < $1.model }, sourceLogPath: values.first?.path)
        }.sorted { $0.todayTokens == $1.todayTokens ? $0.rawId < $1.rawId : $0.todayTokens > $1.todayTokens }
    }

    func historicalSnapshots(retentionDays: Int) -> [String: ToolSnapshot] {
        guard harness.unit == .tokens else { return [:] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, retentionDays) + 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let firstDay = DateHelper.dateKey(from: cutoff), lastDay = DateHelper.todayKey()
        var snapshots: [String: ToolSnapshot] = [:]
        for (day, values) in Dictionary(grouping: receipts, by: { DateHelper.dateKey(from: $0.date) }) where day >= firstDay && day <= lastDay {
            let tokens = values.reduce(0) { $0 + $1.tokens }, cache = values.reduce(0) { $0 + $1.buckets.cacheRead }
            let cost = Self.estimate(values)
            let sessions = Dictionary(grouping: values, by: \.session).map { id, records in
                let sessionCost = Self.estimate(records)
                let models = Set(records.compactMap(\.model))
                return SessionSnapshot(id: id, displayName: records.last?.name ?? id,
                    tokens: records.reduce(0) { $0 + $1.tokens }, messages: records.count, isActive: false,
                    model: models.count == 1 && records.allSatisfy { $0.model != nil } ? models.first : nil, cost: sessionCost,
                    cacheReadTokens: records.reduce(0) { $0 + $1.buckets.cacheRead })
            }
            snapshots[day] = ToolSnapshot(name: harness.name, tokens: tokens, messages: values.count,
                cacheRate: TokenAccounting.cacheReadShare(freshTokens: tokens, cacheRead: cache), isActive: false,
                cost: cost, cacheReadTokens: cache, sessions: sessions)
        }
        return snapshots
    }

    func importHistoryIfNeeded() {
        let key = "TC_harnessHistory_v1_" + harness.rawValue
        let roots = (overrideRoots ?? harness.roots()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: roots), let signature = String(data: data, encoding: .utf8),
              harness.unit == .tokens, UserDefaults.standard.string(forKey: key) != signature else { return }
        let snapshots = historicalSnapshots(retentionDays: AppConfig.History.retentionDays)
        guard let first = snapshots.keys.min(), !snapshots.isEmpty else { return }
        if HistoryStore.shared.replaceToolHistory(toolName: harness.name, snapshotsByDate: snapshots,
                from: first, through: DateHelper.todayKey()) { UserDefaults.standard.set(signature, forKey: key) }
    }

    static func sourceFiles(roots: [String], harness: AdditionalHarness) -> [String] {
        var found = Set<String>()
        func accepts(_ path: String) -> Bool {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if harness == .freebuff { return name == "chat-messages.json" }
            if harness == .kiloCode { return name == "ui_messages.json" || ["kilo.db", "kilocode.db", "opencode.db"].contains(name) }
            return name.hasSuffix(".jsonl") && !name.contains(".checkpoints.") && !name.contains(".prompts.")
        }
        for root in roots {
            let url = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if !directory.boolValue { if accepts(url.path) { found.insert(url.path) }; continue }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                if file.pathComponents.count - url.pathComponents.count > 8 { enumerator.skipDescendants(); continue }
                if ["node_modules", "debug", "log", "logs", "cache", "backups"].contains(file.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard accepts(file.path), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.insert(file.resolvingSymlinksInPath().path)
            }
        }
        return found.sorted()
    }

    private func parse(_ path: String) -> [Receipt]? {
        if path.hasSuffix(".db") { return parseKiloDatabase(path) }
        var records: [[String: Any]] = []
        if path.hasSuffix(".jsonl") {
            guard JSONLLineReader.read(path: path, onLine: { line in
                guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                records.append(object)
            }) != nil else { return nil }
        } else {
            guard let data = FileManager.default.contents(atPath: path), let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            records = array
        }
        var session = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if harness == .kiloCode || harness == .freebuff { session = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
        var name = session
        var currentModel: String?
        for record in records {
            if record["type"] as? String == "session", let id = record["id"] as? String { session = id; name = id }
            if record["type"] as? String == "session_info", let title = record["name"] as? String, !title.isEmpty { name = title }
        }
        if harness == .commandCode {
            let meta = URL(fileURLWithPath: path).deletingPathExtension().path + ".meta.json"
            if let data = FileManager.default.contents(atPath: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let title = obj["title"] as? String, !title.isEmpty { name = title }
        }
        if harness == .freebuff {
            let meta = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("chat-meta.json").path
            if let data = FileManager.default.contents(atPath: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let title = obj["firstPrompt"] as? String, !title.isEmpty { name = title }
        }
        var result: [Receipt] = []
        for (index, record) in records.enumerated() {
            if record["type"] as? String == "model_change" { currentModel = ModelNormalizer.normalize(record["modelId"] as? String) }
            guard let date = Self.date(record["timestamp"] ?? record["ts"]) else { continue }
            if harness == .freebuff {
                guard record["isComplete"] as? Bool == true, record["variant"] as? String == "ai" else { continue }
                result.append(Receipt(id: "freebuff:" + (record["id"] as? String ?? path + ":\(index)"), session: session,
                    name: name, model: nil, date: date, buckets: ModelBuckets(), path: path, requestsOnly: true))
                continue
            }
            if harness == .kiloCode {
                guard record["say"] as? String == "api_req_started", let text = record["text"] as? String,
                    let data = text.data(using: .utf8), let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let buckets = Self.buckets(usage, format: .kiloCode) else { continue }
                result.append(Receipt(id: "kilo-ui:" + session + ":\(date.timeIntervalSince1970)", session: session, name: name,
                    model: ModelNormalizer.normalize(usage["modelId"] as? String), date: date, buckets: buckets, path: path))
                continue
            }
            let type = record["type"] as? String ?? ""
            let message = record["message"] as? [String: Any] ?? [:]
            guard (["message", ""].contains(type) && message["role"] as? String == "assistant") || ["usage", "compaction", "branch_summary"].contains(type) else { continue }
            guard let usage = (record["usage"] as? [String: Any]) ?? (message["usage"] as? [String: Any]),
                  let buckets = Self.buckets(usage, format: harness) else { continue }
            let model = ModelNormalizer.normalize(record["model"] as? String ?? message["model"] as? String) ?? currentModel
            let id = record["id"] as? String ?? path + ":\(index)"
            result.append(Receipt(id: "receipt:" + id + ":\(date.timeIntervalSince1970)", session: session, name: name,
                model: model, date: date, buckets: buckets, path: path))
        }
        return result
    }
    static func date(_ raw: Any?) -> Date? {
        if let string = raw as? String { return DateHelper.parseISO8601(string) }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }
    static func buckets(_ usage: [String: Any], format: AdditionalHarness) -> ModelBuckets? {
        func count(_ keys: [String]) -> Int? {
            for key in keys where usage[key] != nil {
                return Self.nonNegativeCount(usage[key])
            }
            return 0
        }
        let keys: ([String], [String], [String], [String])
        switch format {
        case .kiloCode: keys = (["tokensIn"], ["tokensOut"], ["cacheReads"], ["cacheWrites"])
        case .commandCode: keys = (["inputTokens"], ["outputTokens"], ["cacheReadTokens"], ["cacheWriteTokens"])
        default: keys = (["input"], ["output"], ["cacheRead"], ["cacheWrite"])
        }
        guard let input = count(keys.0), let output = count(keys.1), let read = count(keys.2), let write = count(keys.3), input + output + read + write > 0 else { return nil }
        // Command Code records AI SDK inputTokens (cache-inclusive); Pi and the
        // Kilo extension report fresh input separately. Never add cache twice.
        let freshInput = format == .commandCode ? max(0, input - read - write) : input
        return ModelBuckets(input: freshInput, output: output, cacheRead: read, cacheWrite: write)
    }
    private static func nonNegativeCount(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        // A request cannot contain billions of tokens. Bound corrupt receipts
        // before summing them, rather than letting a few near-Int.max counters crash the app.
        guard value.isFinite, value >= 0, value <= 1_000_000_000, value.rounded(.down) == value else { return nil }
        return Int(value)
    }
    private func parseKiloDatabase(_ path: String) -> [Receipt]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT m.id, m.session_id, m.data, s.title FROM message m LEFT JOIN session s ON s.id=m.session_id", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [Receipt] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            let id = text(0), session = text(1), title = text(3)
            if let data = text(2).data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["role"] as? String == "assistant", let tokens = obj["tokens"] as? [String: Any],
               let time = obj["time"] as? [String: Any], let date = Self.date(time["completed"] ?? time["created"]) {
                let cache = tokens["cache"] as? [String: Any] ?? [:]
                // Current Kilo storage explicitly separates visible output and reasoning.
                guard let output = Self.nonNegativeCount(tokens["output"] ?? 0),
                      let reasoning = Self.nonNegativeCount(tokens["reasoning"] ?? 0) else {
                    status = sqlite3_step(statement); continue
                }
                let raw: [String: Any] = ["input": tokens["input"] ?? 0, "output": output + reasoning,
                                         "cacheRead": cache["read"] ?? 0, "cacheWrite": cache["write"] ?? 0]
                if let buckets = Self.buckets(raw, format: .pi) {
                    result.append(Receipt(id: "kilo-db:" + id, session: session, name: title.isEmpty ? session : title,
                        model: ModelNormalizer.normalize(obj["modelID"] as? String), date: date, buckets: buckets, path: path))
                }
            }
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? result : nil
    }
}

private extension FileManager {
    func attributes(_ path: String) -> [FileAttributeKey: Any]? { try? attributesOfItem(atPath: path) }
}
