#if os(Linux)
import Foundation
import Glibc
import CSQLite

@main
struct LinuxCatalogSmoke {
    private static var failures: [String] = []

    static func main() throws {
        guard let testRoot = ProcessInfo.processInfo.environment["TOKENCLOCK_CATALOG_TEST_ROOT"] else {
            fatalError("TOKENCLOCK_CATALOG_TEST_ROOT is required")
        }
        let root = LinuxProviderCatalog.normalizedPath(testRoot)
        try? FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        expect(LinuxProviderCatalog.Provider.allCases.count == 15, "catalog contains 15 providers")
        testPathExpansion(root: root)
        try testDetectionStates(root: root)
        try testDetectionBudget(root: root)
        testSettingsKeyCompatibility(root: root)
        testPlatformBoundaries()

        if failures.isEmpty {
            print("PASS linux catalog smoke (15 providers, expansion, JSONL/JSON/SQLite, TC_* keys)")
            return
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }

    private static func testPathExpansion(root: String) {
        setenv("TC_SMOKE_ROOT", root, 1)
        setenv("TC_SMOKE_ROOT_LONG", root + "/long", 1)
        expect(
            LinuxProviderCatalog.expandEnvironmentVariables(
                in: "$TC_SMOKE_ROOT/a:${TC_SMOKE_ROOT_LONG}/b"
            ) == "\(root)/a:\(root)/long/b",
            "prefix-overlapping $VAR and ${VAR} expand independently"
        )
        expect(
            LinuxProviderCatalog.normalizedPath("~/catalog-home").hasSuffix("/catalog-home"),
            "tilde expands"
        )
        let originalXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", "relative-xdg-is-invalid", 1)
        expect(
            LinuxProviderCatalog.candidates(for: .cline).allSatisfy {
                !$0.path.contains("relative-xdg-is-invalid")
            },
            "relative XDG base-directory values are ignored"
        )
        if let originalXDG {
            setenv("XDG_CONFIG_HOME", originalXDG, 1)
        } else {
            unsetenv("XDG_CONFIG_HOME")
        }
    }

    private static func testDetectionStates(root: String) throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? root

        let codexHome = home + "/.codex"
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        var summary = PathDetector.runFullDetection()
        guard let emptyCodex = summary.results.first(where: { $0.service == "codex" }) else {
            failures.append("Codex catalog result exists")
            return
        }
        expect(emptyCodex.catalogDeclared, "Codex catalog declared")
        expect(emptyCodex.pathExists, "empty Codex directory reports pathExists")
        expect(!emptyCodex.parserReadable, "empty Codex directory is not parserReadable")

        let openclawLog = home + "/.openclaw/agents/main/sessions/smoke.jsonl"
        try write("{\"type\":\"message\"}\n", to: openclawLog)
        let geminiJSON = home + "/.gemini/tmp/project/chats/session-smoke.json"
        try write("{\"messages\":[]}", to: geminiJSON)
        let hermesDB = home + "/.hermes/state.db"
        try createHermesDatabase(at: hermesDB)
        let zcodeDB = home + "/.zcode/cli/db/db.sqlite"
        try createZCodeDatabase(at: zcodeDB)
        let opencodeDB = root + "/direct/opencode-custom.sqlite"
        try createOpenCodeDatabase(at: opencodeDB)
        setenv("OPENCODE_DB", opencodeDB, 1)
        let copilotOtel = root + "/direct/copilot-otel.jsonl"
        try write(
            "{\"attributes\":{\"gen_ai.usage.input_tokens\":1},\"timestamp\":\"2026-08-06T00:00:00Z\"}\n",
            to: copilotOtel
        )
        setenv("COPILOT_OTEL_FILE_EXPORTER_PATH", copilotOtel, 1)

        summary = PathDetector.runFullDetection()
        assertReadable("openclaw", in: summary, format: "JSONL")
        assertReadable("gemini", in: summary, format: "JSON")
        assertReadable("hermes", in: summary, format: "SQLite")
        assertReadable("opencode", in: summary, format: "OPENCODE_DB SQLite")
        assertReadable("copilot", in: summary, format: "direct OTel JSONL")
        assertReadable("zcode", in: summary, format: "model_usage SQLite")
        expect(PathConfig.opencodeDatabasePath() == opencodeDB, "OPENCODE_DB reaches parser adapter")
        expect(PathConfig.copilotOtelFile() == copilotOtel, "Copilot OTel file reaches parser adapter")
        expect(summary.declaredCount == 15, "summary declares all 15 providers")
    }

    private static func testSettingsKeyCompatibility(root: String) {
        let cases: [(SettingsKey, (String) -> Void)] = [
            (.openclawPath, PathConfig.setOpenclawPath),
            (.claudeCodePath, PathConfig.setClaudeCodePath),
            (.geminiPath, PathConfig.setGeminiPath),
            (.codexPath, PathConfig.setCodexPath),
            (.hermesPath, PathConfig.setHermesPath),
            (.opencodePath, PathConfig.setOpenCodePath),
            (.qwenPath, PathConfig.setQwenPath),
            (.copilotPath, PathConfig.setCopilotPath),
            (.grokPath, PathConfig.setGrokPath),
            (.aiderPath, PathConfig.setAiderPath),
            (.antigravityPath, PathConfig.setAntigravityPath),
            (.clinePath, PathConfig.setClinePath),
            (.continuePath, PathConfig.setContinuePath),
            (.cursorAgentPath, PathConfig.setCursorAgentPath),
            (.zcodePath, PathConfig.setZCodePath),
        ]
        for (index, item) in cases.enumerated() {
            let path = root + "/saved/\(index)"
            item.1(path)
            expect(
                UserDefaults.standard.string(forKey: item.0.rawValue) == path,
                "\(item.0.rawValue) matches settings-panel persistence key"
            )
            UserDefaults.standard.remove(item.0)
        }
    }

    private static func testDetectionBudget(root: String) throws {
        let stressHome = root + "/stress-claude"
        let projects = stressHome + "/projects/project"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        for index in 0...LinuxProviderCatalog.Provider.allCases.count * 600 {
            _ = FileManager.default.createFile(
                atPath: projects + "/invalid-\(index).jsonl",
                contents: Data()
            )
        }
        PathConfig.setClaudeCodePath(stressHome)
        let startedAt = Date()
        let result = PathDetector.runFullDetection().results.first { $0.service == "claudeCode" }
        let elapsed = Date().timeIntervalSince(startedAt)
        expect(result?.pathExists == true, "bounded detector preserves pathExists")
        expect(result?.parserReadable == false, "bounded detector rejects unreadable JSONL tree")
        expect(elapsed < 1.5, "full catalog detection remains bounded (\(elapsed)s)")
        PathConfig.setClaudeCodePath("")
    }

    private static func testPlatformBoundaries() {
        for provider in LinuxProviderCatalog.Provider.allCases {
            for candidate in LinuxProviderCatalog.candidates(for: provider) {
                expect(!candidate.path.contains("/Library/Application Support/"), "no macOS candidate for \(provider.rawValue)")
                expect(!candidate.path.localizedCaseInsensitiveContains("AppData"), "no Windows candidate for \(provider.rawValue)")
            }
        }
    }

    private static func assertReadable(
        _ service: String,
        in summary: PathDetector.DetectionSummary,
        format: String
    ) {
        guard let result = summary.results.first(where: { $0.service == service }) else {
            failures.append("\(service) result exists for \(format)")
            return
        }
        expect(result.pathExists, "\(service) \(format) path exists")
        expect(result.parserReadable, "\(service) \(format) parser readable")
    }

    private static func createHermesDatabase(at path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LinuxCatalogSmoke", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE sessions (
          started_at REAL, input_tokens INTEGER, output_tokens INTEGER,
          cache_read_tokens INTEGER, cache_write_tokens INTEGER, message_count INTEGER
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LinuxCatalogSmoke", code: 2)
        }
    }

    private static func createZCodeDatabase(at path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LinuxCatalogSmoke", code: 3)
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, """
            CREATE TABLE model_usage(
              session_id TEXT, model_id TEXT, started_at INTEGER,
              input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
              cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER
            );
            """, nil, nil, nil)
    }

    private static func createOpenCodeDatabase(at path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LinuxCatalogSmoke", code: 3)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE session (
          tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
          tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LinuxCatalogSmoke", code: 4)
        }
    }

    private static func write(_ value: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
#endif
