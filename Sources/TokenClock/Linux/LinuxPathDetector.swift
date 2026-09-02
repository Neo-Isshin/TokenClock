#if os(Linux)
import Foundation
import CSQLite

/// Linux-only provider detection. A declared catalog entry, an existing path,
/// and a parser-readable data source are deliberately reported separately.
enum PathDetector {
    private static let maximumDetectionEntries = 8_000
    private static let maximumDetectionDepth = 8
    private static let maximumDetectionSeconds: TimeInterval = 0.25

    struct DetectionResult {
        let service: String
        let emoji: String
        let detectedPath: String
        let isDefault: Bool
        let catalogDeclared: Bool
        let pathExists: Bool
        let parserReadable: Bool
        let source: PathSource
        let detail: String

        /// Compatibility with the existing settings/model call sites: "found"
        /// means that the parser can actually consume the source, not merely
        /// that a directory happens to exist.
        var exists: Bool { parserReadable }

        enum PathSource: String {
            case userDefaults = "pathSource.userDefaults"
            case envVariable = "pathSource.envVar"
            case officialDefault = "pathSource.official"
            case alternate = "pathSource.alternate"
            case notFound = "pathSource.notFound"
        }

        var localizedSource: String { L10n.shared.tr(source.rawValue) }
    }

    struct DetectionSummary {
        let results: [DetectionResult]
        let declaredCount: Int
        let existingPathCount: Int
        let foundCount: Int
        let totalCount: Int
        var allFound: Bool { foundCount == totalCount }
    }

    private struct Candidate {
        let path: String
        let source: DetectionResult.PathSource
        let isDirectFile: Bool
    }

    static func runFullDetection() -> DetectionSummary {
        let results = LinuxProviderCatalog.Provider.allCases.map(detect)
        return DetectionSummary(
            results: results,
            declaredCount: results.filter(\.catalogDeclared).count,
            existingPathCount: results.filter(\.pathExists).count,
            foundCount: results.filter(\.parserReadable).count,
            totalCount: results.count
        )
    }

    static func detectAll() -> [DetectionResult] {
        runFullDetection().results
    }

    private static func detect(_ provider: LinuxProviderCatalog.Provider) -> DetectionResult {
        let entry = LinuxProviderCatalog.entry(for: provider)
        let custom = customPath(for: provider)
        var candidates: [Candidate] = []
        var seen = Set<String>()

        func append(
            _ rawPath: String,
            source: DetectionResult.PathSource,
            isDirectFile: Bool = false
        ) {
            let path = LinuxProviderCatalog.normalizedPath(rawPath)
            guard seen.insert(path).inserted else { return }
            candidates.append(Candidate(path: path, source: source, isDirectFile: isDirectFile))
        }

        if let custom {
            let directFile = (provider == .opencode && custom.hasSuffix(".db"))
                || (provider == .copilot && custom.hasSuffix(".jsonl"))
            append(custom, source: .userDefaults, isDirectFile: directFile)
        }
        for catalogCandidate in LinuxProviderCatalog.candidates(for: provider) {
            let source: DetectionResult.PathSource
            switch catalogCandidate.origin {
            case .officialEnvironment:
                source = .envVariable
            case .compatibilityEnvironment, .linuxConvention, .alternate:
                source = .alternate
            case .officialDefault:
                source = .officialDefault
            }
            append(
                catalogCandidate.path,
                source: source,
                isDirectFile: catalogCandidate.isDirectFile
            )
        }

        let readable = candidates.first {
            parserCanRead(provider, path: $0.path, isDirectFile: $0.isDirectFile)
        }
        let existing = candidates.first { pathExists($0.path) }
        let selected = readable ?? existing
        let selectedPath = selected?.path ?? entry.defaultPath
        let selectedSource = selected?.source ?? .notFound
        let isReadable = readable != nil
        let doesExist = existing != nil

        let detail: String
        if isReadable {
            switch selectedSource {
            case .userDefaults: detail = L10n.shared.tr("pathDetail.userCustom")
            case .envVariable: detail = L10n.shared.tr("pathDetail.envDetected")
            case .officialDefault: detail = L10n.shared.tr("pathDetail.official")
            case .alternate: detail = L10n.shared.tr("pathDetail.alternate")
            case .notFound: detail = L10n.shared.tr("pathDetail.notFound")
            }
        } else {
            detail = L10n.shared.tr("pathDetail.notFoundDefault")
        }

        return DetectionResult(
            service: entry.service,
            emoji: entry.emoji,
            detectedPath: selectedPath,
            isDefault: custom == nil && selectedSource != .userDefaults,
            catalogDeclared: true,
            pathExists: doesExist,
            parserReadable: isReadable,
            source: selectedSource,
            detail: detail
        )
    }

    private static func customPath(for provider: LinuxProviderCatalog.Provider) -> String? {
        let key: SettingsKey
        switch provider {
        case .openclaw: key = .openclawPath
        case .claudeCode: key = .claudeCodePath
        case .gemini: key = .geminiPath
        case .codex: key = .codexPath
        case .hermes: key = .hermesPath
        case .opencode: key = .opencodePath
        case .qwen: key = .qwenPath
        case .copilot: key = .copilotPath
        case .grok: key = .grokPath
        case .aider: key = .aiderPath
        case .antigravity: key = .antigravityPath
        case .cline: key = .clinePath
        case .continue: key = .continuePath
        case .cursorAgent: key = .cursorAgentPath
        case .zcode: key = .zcodePath
        }
        guard let rawValue = UserDefaults.standard.string(for: key), !rawValue.isEmpty else { return nil }
        return LinuxProviderCatalog.normalizedPath(rawValue)
    }

    private static func parserCanRead(
        _ provider: LinuxProviderCatalog.Provider,
        path home: String,
        isDirectFile: Bool
    ) -> Bool {
        switch provider {
        case .openclaw:
            return containsReadableJSON(in: home + "/agents", extensions: ["jsonl"])
                || containsReadableJSON(in: home + "/sessions", extensions: ["jsonl"])
        case .claudeCode:
            return containsReadableJSON(in: home + "/projects", extensions: ["jsonl"])
        case .gemini:
            return containsReadableJSON(in: home + "/tmp", extensions: ["jsonl", "json"])
        case .codex:
            return containsReadableJSON(
                in: home + "/sessions",
                extensions: ["jsonl"],
                filenamePrefix: "rollout-"
            )
        case .hermes:
            return sqliteHasColumns(
                path: home + "/state.db",
                table: "sessions",
                columns: [
                    "started_at", "input_tokens", "output_tokens", "cache_read_tokens",
                    "cache_write_tokens", "message_count",
                ]
            )
        case .opencode:
            return sqliteHasColumns(
                path: isDirectFile ? home : home + "/opencode.db",
                table: "session",
                columns: [
                    "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read",
                    "tokens_cache_write", "time_created",
                ]
            )
        case .qwen:
            return containsReadableJSON(in: home + "/projects", extensions: ["jsonl"])
        case .copilot:
            return (isDirectFile && readableJSONFile(home))
                || containsReadableJSON(in: home + "/session-state", extensions: ["jsonl"])
                || containsReadableJSON(in: home + "/otel", extensions: ["jsonl"])
        case .grok:
            return containsReadableJSON(
                in: home + "/sessions",
                extensions: ["jsonl"],
                filename: "updates.jsonl"
            )
        case .aider:
            return readableJSONFile(home + "/analytics.jsonl")
        case .antigravity:
            return containsReadableSQLite(
                in: home + "/conversations",
                table: "steps",
                columns: ["step_payload", "metadata"]
            )
        case .cline:
            return containsReadableFile(
                in: home + "/tasks",
                filename: "api_conversation.json",
                validator: readableJSONFile
            )
        case .continue:
            return containsReadableJSON(in: home + "/dev_data", extensions: ["jsonl"])
                || containsReadableJSON(in: home + "/sessions", extensions: ["jsonl"])
        case .cursorAgent:
            return cursorCredentialsAreReadable(at: home)
        case .zcode:
            return sqliteHasColumns(
                path: (home.hasSuffix(".sqlite") || home.hasSuffix(".db"))
                    ? home : home + "/cli/db/db.sqlite",
                table: "model_usage",
                columns: [
                    "session_id", "model_id", "started_at", "input_tokens", "output_tokens",
                    "reasoning_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
                ]
            )
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func containsReadableJSON(
        in directory: String,
        extensions: Set<String>,
        filenamePrefix: String? = nil,
        filename: String? = nil
    ) -> Bool {
        containsReadableFile(in: directory, filename: filename) { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard extensions.contains(fileExtension) else { return false }
            if let filenamePrefix, !name.hasPrefix(filenamePrefix) { return false }
            return readableJSONFile(path)
        }
    }

    private static func containsReadableFile(
        in directory: String,
        filename: String? = nil,
        validator: (String) -> Bool
    ) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
                options: [.skipsHiddenFiles]
              ) else { return false }
        let startedAt = Date()
        var visitedEntries = 0
        for case let url as URL in enumerator {
            visitedEntries += 1
            if visitedEntries > maximumDetectionEntries
                || Date().timeIntervalSince(startedAt) > maximumDetectionSeconds {
                return false
            }
            if enumerator.level > maximumDetectionDepth {
                enumerator.skipDescendants()
                continue
            }
            if let filename, url.lastPathComponent != filename { continue }
            guard validator(url.path) else { continue }
            return true
        }
        return false
    }

    private static func readableJSONFile(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 256 * 1_024), !prefix.isEmpty else {
            return false
        }
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "json" {
            if let attributes = try? fm.attributesOfItem(atPath: path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > prefix.count,
               let fullData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return (try? JSONSerialization.jsonObject(with: fullData)) != nil
            }
            return (try? JSONSerialization.jsonObject(with: prefix)) != nil
        }
        for line in prefix.split(separator: 0x0A) where !line.isEmpty {
            if (try? JSONSerialization.jsonObject(with: Data(line))) != nil { return true }
        }
        return false
    }

    private static func containsReadableSQLite(
        in directory: String,
        table: String,
        columns: Set<String>
    ) -> Bool {
        containsReadableFile(in: directory) { path in
            guard URL(fileURLWithPath: path).pathExtension.lowercased() == "db" else { return false }
            return sqliteHasColumns(path: path, table: table, columns: columns)
        }
    }

    private static func sqliteHasColumns(
        path: String,
        table: String,
        columns: Set<String>
    ) -> Bool {
        guard FileManager.default.isReadableFile(atPath: path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        var found = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) {
                found.insert(String(cString: pointer))
            }
        }
        return columns.isSubset(of: found)
    }

    private static func cursorCredentialsAreReadable(at home: String) -> Bool {
        let possiblePaths: [String]
        if home.hasSuffix(".vscdb") {
            possiblePaths = [home]
        } else {
            possiblePaths = [
                home + "/state.vscdb",
                home + "/User/globalStorage/state.vscdb",
            ]
        }
        for path in possiblePaths where FileManager.default.isReadableFile(atPath: path) {
            var database: OpaquePointer?
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database else {
                if database != nil { sqlite3_close(database) }
                continue
            }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { continue }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW,
               let pointer = sqlite3_column_text(statement, 0),
               !String(cString: pointer).isEmpty {
                return true
            }
        }
        return false
    }

    // Compatibility helpers retained for code outside the Linux target.
    static func findJSONLFiles(in basePath: String, subpath: String? = nil, recursive: Bool = false) -> Bool {
        let directory = subpath.map { basePath + "/" + $0 } ?? basePath
        if recursive { return containsReadableJSON(in: directory, extensions: ["jsonl"]) }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        return contents.contains { readableJSONFile(directory + "/" + $0) && $0.hasSuffix(".jsonl") }
    }

    static func findJSONFiles(in basePath: String, subpath: String? = nil, recursive: Bool = false) -> Bool {
        let directory = subpath.map { basePath + "/" + $0 } ?? basePath
        if recursive { return containsReadableJSON(in: directory, extensions: ["json"]) }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        return contents.contains { readableJSONFile(directory + "/" + $0) && $0.hasSuffix(".json") }
    }

    static func findRolloutJSONLFiles(in basePath: String, subpath: String) -> Bool {
        containsReadableJSON(
            in: basePath + "/" + subpath,
            extensions: ["jsonl"],
            filenamePrefix: "rollout-"
        )
    }

    static func checkSSHConfig(for host: String) -> Bool {
        let path = LinuxProviderCatalog.homeDirectory + "/.ssh/config"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host ") else { return false }
            let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return value == host || value == "*"
        }
    }
}
#endif
