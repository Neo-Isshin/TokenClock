#if os(Windows)
import Foundation

/// Windows-only provider path declarations.
///
/// Parsers are shared across platforms, but their discovery roots are not. Keeping every
/// Windows default and environment-variable priority here prevents AppData paths and Windows
/// expansion syntax from silently changing the macOS or Linux builds of `windows-port`.
enum WindowsProviderCatalog {
    enum ProviderID: String, CaseIterable {
        case openclaw, claudeCode, gemini, codex, hermes, opencode, qwen
        case copilot, grok, aider, antigravity, cline, `continue`, cursorAgent
    }

    enum DataKind: String {
        case jsonlDirectory
        case jsonDirectory
        case sqliteDirectory
        case analyticsJSONL
        case cursorStateDatabase
    }

    enum ContractStatus: String {
        case official
        case tokenClockCompatibility
    }

    struct EnvironmentOverride {
        let name: String
        let status: ContractStatus
        let semantics: String
    }

    struct Entry {
        let id: ProviderID
        let displayName: String
        let environmentOverrides: [EnvironmentOverride]
        let defaultPath: String
        let alternatePaths: [String]
        let dataKind: DataKind
    }

    private static func official(_ name: String, _ semantics: String = "direct") -> EnvironmentOverride {
        EnvironmentOverride(name: name, status: .official, semantics: semantics)
    }

    private static func compatibility(_ name: String, _ semantics: String = "direct") -> EnvironmentOverride {
        EnvironmentOverride(name: name, status: .tokenClockCompatibility, semantics: semantics)
    }

    private static var userProfile: String {
        ProcessInfo.processInfo.environment["USERPROFILE"] ?? NSHomeDirectory()
    }

    private static var roamingAppData: String {
        ProcessInfo.processInfo.environment["APPDATA"]
            ?? userProfile + "\\AppData\\Roaming"
    }

    private static var localAppData: String {
        ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? userProfile + "\\AppData\\Local"
    }

    static let entries: [ProviderID: Entry] = {
        let user = userProfile
        let roaming = roamingAppData
        let local = localAppData
        let values: [Entry] = [
            Entry(id: .openclaw, displayName: "OpenClaw", environmentOverrides: [
                    official("OPENCLAW_STATE_DIR"), official("OPENCLAW_HOME", "home parent; append .openclaw")
                  ],
                  defaultPath: user + "\\.openclaw", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .claudeCode, displayName: "Claude Code", environmentOverrides: [official("CLAUDE_CONFIG_DIR")],
                  defaultPath: user + "\\.claude", alternatePaths: [], dataKind: .jsonlDirectory),
            // GEMINI_CLI_HOME is the parent directory; PathConfig appends `.gemini`.
            Entry(id: .gemini, displayName: "Gemini CLI", environmentOverrides: [
                    official("GEMINI_CLI_HOME", "home parent; append .gemini"), compatibility("GEMINI_HOME")
                  ],
                  defaultPath: user + "\\.gemini", alternatePaths: [], dataKind: .jsonDirectory),
            Entry(id: .codex, displayName: "Codex", environmentOverrides: [official("CODEX_HOME")],
                  defaultPath: user + "\\.codex", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .hermes, displayName: "Hermes", environmentOverrides: [official("HERMES_HOME")],
                  defaultPath: local + "\\hermes", alternatePaths: [user + "\\.hermes"], dataKind: .sqliteDirectory),
            // OpenCode uses the platform data directory on Windows. Keep the historical
            // ~/.local/share location as a compatibility probe for older installations.
            Entry(id: .opencode, displayName: "OpenCode", environmentOverrides: [
                    official("OPENCODE_DB", "direct SQLite database"),
                    official("XDG_DATA_HOME", "parent data directory; append opencode"),
                    compatibility("OPENCODE_HOME")
                  ],
                  defaultPath: user + "\\.local\\share\\opencode",
                  alternatePaths: [local + "\\opencode", user + "\\.opencode"],
                  dataKind: .sqliteDirectory),
            Entry(id: .qwen, displayName: "Qwen Code", environmentOverrides: [official("QWEN_RUNTIME_DIR"), official("QWEN_HOME")],
                  defaultPath: user + "\\.qwen", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .copilot, displayName: "GitHub Copilot CLI", environmentOverrides: [
                    official("COPILOT_OTEL_FILE_EXPORTER_PATH", "direct JSONL file"),
                    official("COPILOT_HOME")
                  ],
                  defaultPath: user + "\\.copilot", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .grok, displayName: "Grok CLI", environmentOverrides: [compatibility("GROK_HOME")],
                  defaultPath: user + "\\.grok", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .aider, displayName: "Aider", environmentOverrides: [official("AIDER_ANALYTICS_LOG"), compatibility("AIDER_HOME")],
                  defaultPath: user + "\\.aider\\analytics.jsonl", alternatePaths: [], dataKind: .analyticsJSONL),
            Entry(id: .antigravity, displayName: "Antigravity", environmentOverrides: [compatibility("ANTIGRAVITY_HOME")],
                  defaultPath: user + "\\.gemini\\antigravity-cli", alternatePaths: [], dataKind: .sqliteDirectory),
            Entry(id: .cline, displayName: "Cline", environmentOverrides: [compatibility("CLINE_HOME")],
                  defaultPath: roaming + "\\Code\\User\\globalStorage\\saoudrizwan.claude-dev",
                  alternatePaths: [roaming + "\\Cursor\\User\\globalStorage\\saoudrizwan.claude-dev"],
                  dataKind: .jsonDirectory),
            Entry(id: .continue, displayName: "Continue", environmentOverrides: [compatibility("CONTINUE_HOME")],
                  defaultPath: user + "\\.continue", alternatePaths: [], dataKind: .jsonlDirectory),
            Entry(id: .cursorAgent, displayName: "Cursor Agent", environmentOverrides: [compatibility("CURSOR_AGENT_HOME")],
                  defaultPath: roaming + "\\Cursor\\User\\globalStorage", alternatePaths: [],
                  dataKind: .cursorStateDatabase),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }()

    static func entry(_ id: ProviderID) -> Entry {
        guard let entry = entries[id] else { preconditionFailure("Missing Windows provider catalog entry: \(id.rawValue)") }
        return entry
    }

    /// Expands Windows path forms accepted by the settings panel. Unknown variables are retained
    /// verbatim so a typo never turns into a surprising path.
    static func expand(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if value == "~" || value.hasPrefix("~/") || value.hasPrefix("~\\") {
            value = userProfile + String(value.dropFirst())
        }
        value = replaceEnvironmentTokens(in: value, pattern: #"%([A-Za-z_][A-Za-z0-9_]*)%"#)
        value = replaceEnvironmentTokens(in: value, pattern: #"\$env:([A-Za-z_][A-Za-z0-9_]*)"#,
                                         caseInsensitive: true)
        value = replaceEnvironmentTokens(in: value, pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        value = replaceEnvironmentTokens(in: value, pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)
        return (value as NSString).standardizingPath.replacingOccurrences(of: "/", with: "\\")
    }

    private static func replaceEnvironmentTokens(
        in input: String,
        pattern: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        var environment: [String: String] = [:]
        for (name, value) in ProcessInfo.processInfo.environment {
            environment[name.uppercased()] = value
        }
        let original = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: original.length))
        var output = input
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = original.substring(with: nameRange).uppercased()
            guard let replacement = environment[name],
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    /// Machine-readable diagnostic used by the Windows catalog smoke test. A catalog entry is a
    /// declaration; `pathExists` and `parserReadable` are deliberately reported separately.
    static func writeDiagnosticReport(to outputPath: String) throws {
        let detectionByID = Dictionary(uniqueKeysWithValues:
            PathDetector.runFullDetection().results.map { ($0.service, $0) })
        let providers: [[String: Any]] = ProviderID.allCases.map { id in
            let declaration = entry(id)
            let detected = detectionByID[id.rawValue]
            return [
                "id": id.rawValue,
                "displayName": declaration.displayName,
                "environmentOverrides": declaration.environmentOverrides.map {
                    ["name": $0.name, "status": $0.status.rawValue, "semantics": $0.semantics]
                },
                "defaultPath": declaration.defaultPath,
                "alternatePaths": declaration.alternatePaths,
                "dataKind": declaration.dataKind.rawValue,
                "selectedPath": detected?.detectedPath ?? declaration.defaultPath,
                "pathExists": detected?.pathExists ?? false,
                "parserReadable": detected?.parserReadable ?? false,
                "source": detected?.source.rawValue ?? PathDetector.DetectionResult.PathSource.notFound.rawValue,
            ]
        }
        let report: [String: Any] = [
            "platform": "windows",
            "providers": providers,
            "pathExpansion": [
                "%LOCALAPPDATA%\\TokenClock": expand("%LOCALAPPDATA%\\TokenClock"),
                "$env:APPDATA\\TokenClock": expand("$env:APPDATA\\TokenClock"),
                "$TC_EXPAND_SHORT\\child": expand("$TC_EXPAND_SHORT\\child"),
                "$TC_EXPAND_LONG\\child": expand("$TC_EXPAND_LONG\\child"),
                "$TC_EXPAND_LONGER\\child": expand("$TC_EXPAND_LONGER\\child"),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
#endif
