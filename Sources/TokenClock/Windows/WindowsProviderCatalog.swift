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
        case kiro, codeBuddy
    }

    enum DataKind: String {
        case jsonlDirectory
        case jsonDirectory
        case sqliteDirectory
        case analyticsJSONL
        case cursorStateDatabase
        case kiroSessionDirectory
        case loopbackStatsAPI
    }

    enum StatisticsSupport: String {
        /// The existing shared reader has a documented, field-level statistics contract.
        case parsed
        /// Parsed from an official published artifact, but not yet fully described by the
        /// provider's public OpenAPI schema. The decoder is strict and fails closed on drift.
        case experimental
        /// The official storage/API contract can be detected, but upstream has not published
        /// stable numeric field semantics that TokenClock can safely aggregate.
        case contractOnly
    }

    enum SourceKind: String {
        case fileSystem
        case loopbackAPI
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
        let abbreviation: String
        let emoji: String
        let environmentOverrides: [EnvironmentOverride]
        let defaultPath: String
        let alternatePaths: [String]
        let dataKind: DataKind
        let measurementUnit: UsageMeasurementUnit
        let measurementScope: UsageMeasurementScope
        let statisticsSupport: StatisticsSupport
        let sourceKind: SourceKind
        let defaultEnabled: Bool

        var supportsFolderPicker: Bool { sourceKind == .fileSystem }
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
            Entry(id: .openclaw, displayName: "OpenClaw", abbreviation: "OC", emoji: "🦞", environmentOverrides: [
                    official("OPENCLAW_STATE_DIR"), official("OPENCLAW_HOME", "home parent; append .openclaw")
                  ],
                  defaultPath: user + "\\.openclaw", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .claudeCode, displayName: "Claude Code", abbreviation: "CC", emoji: "✳️", environmentOverrides: [official("CLAUDE_CONFIG_DIR")],
                  defaultPath: user + "\\.claude", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            // GEMINI_CLI_HOME is the parent directory; PathConfig appends `.gemini`.
            Entry(id: .gemini, displayName: "Gemini CLI", abbreviation: "GC", emoji: "✨", environmentOverrides: [
                    official("GEMINI_CLI_HOME", "home parent; append .gemini"), compatibility("GEMINI_HOME")
                  ],
                  defaultPath: user + "\\.gemini", alternatePaths: [], dataKind: .jsonDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .codex, displayName: "Codex", abbreviation: "CX", emoji: "🤖", environmentOverrides: [official("CODEX_HOME")],
                  defaultPath: user + "\\.codex", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .hermes, displayName: "Hermes", abbreviation: "HM", emoji: "⚕️", environmentOverrides: [official("HERMES_HOME")],
                  defaultPath: local + "\\hermes", alternatePaths: [user + "\\.hermes"], dataKind: .sqliteDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            // OpenCode uses the platform data directory on Windows. Keep the historical
            // ~/.local/share location as a compatibility probe for older installations.
            Entry(id: .opencode, displayName: "OpenCode", abbreviation: "OD", emoji: "🐙", environmentOverrides: [
                    official("OPENCODE_DB", "direct SQLite database"),
                    official("XDG_DATA_HOME", "parent data directory; append opencode"),
                    compatibility("OPENCODE_HOME")
                  ],
                  defaultPath: user + "\\.local\\share\\opencode",
                  alternatePaths: [local + "\\opencode", user + "\\.opencode"],
                  dataKind: .sqliteDirectory, measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed,
                  sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .qwen, displayName: "Qwen Code", abbreviation: "QW", emoji: "🟣", environmentOverrides: [official("QWEN_RUNTIME_DIR"), official("QWEN_HOME")],
                  defaultPath: user + "\\.qwen", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .copilot, displayName: "Copilot", abbreviation: "CP", emoji: "🐙", environmentOverrides: [
                    official("COPILOT_OTEL_FILE_EXPORTER_PATH", "direct JSONL file"),
                    official("COPILOT_HOME")
                  ],
                  defaultPath: user + "\\.copilot", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .grok, displayName: "Grok", abbreviation: "GK", emoji: "⚡", environmentOverrides: [compatibility("GROK_HOME")],
                  defaultPath: user + "\\.grok", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .aider, displayName: "Aider", abbreviation: "AI", emoji: "🤝", environmentOverrides: [official("AIDER_ANALYTICS_LOG"), compatibility("AIDER_HOME")],
                  defaultPath: user + "\\.aider\\analytics.jsonl", alternatePaths: [], dataKind: .analyticsJSONL,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .antigravity, displayName: "Antigravity", abbreviation: "AG", emoji: "🛡️", environmentOverrides: [compatibility("ANTIGRAVITY_HOME")],
                  defaultPath: user + "\\.gemini\\antigravity-cli", alternatePaths: [], dataKind: .sqliteDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .cline, displayName: "Cline", abbreviation: "CL", emoji: "🤖", environmentOverrides: [compatibility("CLINE_HOME")],
                  defaultPath: roaming + "\\Code\\User\\globalStorage\\saoudrizwan.claude-dev",
                  alternatePaths: [roaming + "\\Cursor\\User\\globalStorage\\saoudrizwan.claude-dev"],
                  dataKind: .jsonDirectory, measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed,
                  sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .continue, displayName: "Continue", abbreviation: "CN", emoji: "▶️", environmentOverrides: [compatibility("CONTINUE_HOME")],
                  defaultPath: user + "\\.continue", alternatePaths: [], dataKind: .jsonlDirectory,
                  measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed, sourceKind: .fileSystem, defaultEnabled: true),
            Entry(id: .cursorAgent, displayName: "Cursor Agent", abbreviation: "CA", emoji: "🖱️", environmentOverrides: [compatibility("CURSOR_AGENT_HOME")],
                  defaultPath: roaming + "\\Cursor\\User\\globalStorage", alternatePaths: [],
                  dataKind: .cursorStateDatabase, measurementUnit: .tokens, measurementScope: .today, statisticsSupport: .parsed,
                  sourceKind: .fileSystem, defaultEnabled: true),
            // Kiro documents KIRO_HOME plus this exact session location, but does not publish
            // stable usage fields in either file. Detect the contract without inventing counts.
            Entry(id: .kiro, displayName: "Kiro CLI", abbreviation: "KI", emoji: "🟦", environmentOverrides: [
                    official("KIRO_HOME", "home directory; append sessions\\cli")
                  ],
                  defaultPath: user + "\\.kiro\\sessions\\cli", alternatePaths: [],
                  dataKind: .kiroSessionDirectory, measurementUnit: .requests, measurementScope: .contractOnly,
                  statisticsSupport: .contractOnly, sourceKind: .fileSystem, defaultEnabled: false),
            // CodeBuddy's public Beta API documents both routes and the unified `data` envelope.
            // Current-session field mapping comes from the bundled OpenAPI in its official
            // 2.133.1 npm artifact. Keep it experimental while the public API remains Beta.
            Entry(id: .codeBuddy, displayName: "CodeBuddy CLI", abbreviation: "CB", emoji: "🧩", environmentOverrides: [
                    compatibility("CODEBUDDY_STATS_ENDPOINT", "loopback HTTP base URL")
                  ],
                  defaultPath: "http://127.0.0.1:8080", alternatePaths: [],
                  dataKind: .loopbackStatsAPI, measurementUnit: .tokens, measurementScope: .currentSession,
                  statisticsSupport: .experimental, sourceKind: .loopbackAPI, defaultEnabled: false),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }()

    static func entry(_ id: ProviderID) -> Entry {
        guard let entry = entries[id] else { preconditionFailure("Missing Windows provider catalog entry: \(id.rawValue)") }
        return entry
    }

    static var orderedEntries: [Entry] { ProviderID.allCases.map(entry) }

    /// A single source of truth for first-run and Settings defaults. An explicitly saved empty
    /// array remains empty; only a missing preference falls back to defaultEnabled providers.
    static func enabledDisplayNames(saved: [String]?) -> Set<String> {
        let entries = orderedEntries
        let defaults = entries.filter(\.defaultEnabled).map(\.displayName)
        return Set(saved ?? defaults).intersection(Set(entries.map(\.displayName)))
    }

    static func entry(serviceID: String) -> Entry? {
        ProviderID(rawValue: serviceID).map(entry)
    }

    static func entry(displayName: String) -> Entry? {
        orderedEntries.first { $0.displayName == displayName }
    }

    /// Single settings/path router used by the Windows settings panel, detector and model.
    /// The provider list/order/name metadata all live above; this switch only binds IDs to the
    /// existing strongly-typed PathConfig accessors.
    static func configuredSource(for id: ProviderID) -> String {
        switch id {
        case .openclaw: return PathConfig.openclawHome()
        case .claudeCode: return PathConfig.claudeCodeHome()
        case .gemini: return PathConfig.geminiHome()
        case .codex: return PathConfig.codexHome()
        case .hermes: return PathConfig.hermesHome()
        case .opencode: return PathConfig.opencodeHome()
        case .qwen: return PathConfig.qwenHome()
        case .copilot: return PathConfig.copilotHome()
        case .grok: return PathConfig.grokHome()
        case .aider: return PathConfig.aiderHome()
        case .antigravity: return PathConfig.antigravityHome()
        case .cline: return PathConfig.clineHome()
        case .continue: return PathConfig.continueHome()
        case .cursorAgent: return PathConfig.cursorAgentHome()
        case .kiro: return PathConfig.kiroSessionsHome()
        case .codeBuddy: return PathConfig.codeBuddyEndpoint()
        }
    }

    static func setConfiguredSource(_ value: String, for id: ProviderID) {
        switch id {
        case .openclaw: PathConfig.setOpenclawPath(value)
        case .claudeCode: PathConfig.setClaudeCodePath(value)
        case .gemini: PathConfig.setGeminiPath(value)
        case .codex: PathConfig.setCodexPath(value)
        case .hermes: PathConfig.setHermesPath(value)
        case .opencode: PathConfig.setOpenCodePath(value)
        case .qwen: PathConfig.setQwenPath(value)
        case .copilot: PathConfig.setCopilotPath(value)
        case .grok: PathConfig.setGrokPath(value)
        case .aider: PathConfig.setAiderPath(value)
        case .antigravity: PathConfig.setAntigravityPath(value)
        case .cline: PathConfig.setClinePath(value)
        case .continue: PathConfig.setContinuePath(value)
        case .cursorAgent: PathConfig.setCursorAgentPath(value)
        case .kiro: PathConfig.setKiroSessionsPath(value)
        case .codeBuddy: PathConfig.setCodeBuddyEndpoint(value)
        }
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
            PathDetector.runFullDetection(probeLoopbackServices: true).results.map { ($0.service, $0) })
        let providers: [[String: Any]] = ProviderID.allCases.map { id in
            let declaration = entry(id)
            let detected = detectionByID[id.rawValue]
            return [
                "id": id.rawValue,
                "displayName": declaration.displayName,
                "abbreviation": declaration.abbreviation,
                "emoji": declaration.emoji,
                "environmentOverrides": declaration.environmentOverrides.map {
                    ["name": $0.name, "status": $0.status.rawValue, "semantics": $0.semantics]
                },
                "defaultPath": declaration.defaultPath,
                "alternatePaths": declaration.alternatePaths,
                "dataKind": declaration.dataKind.rawValue,
                "measurementUnit": declaration.measurementUnit.rawValue,
                "measurementScope": declaration.measurementScope.rawValue,
                "statisticsSupport": declaration.statisticsSupport.rawValue,
                "sourceKind": declaration.sourceKind.rawValue,
                "defaultEnabled": declaration.defaultEnabled,
                "contractReadable": detected?.contractReadable ?? false,
                "sourceAvailable": detected?.sourceAvailable ?? false,
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
