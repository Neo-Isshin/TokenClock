#if os(Linux)
import Foundation

/// Linux owns its provider paths. This catalog deliberately does not inherit
/// macOS Application Support paths or Windows AppData paths.
enum LinuxProviderCatalog {
    enum Provider: String, CaseIterable, Sendable {
        case openclaw
        case claudeCode
        case gemini
        case codex
        case hermes
        case opencode
        case qwen
        case copilot
        case grok
        case aider
        case antigravity
        case cline
        case `continue`
        case cursorAgent
    }

    enum CandidateOrigin: Sendable {
        case officialEnvironment
        case compatibilityEnvironment
        case officialDefault
        case linuxConvention
        case alternate
    }

    struct Candidate: Sendable {
        let path: String
        let origin: CandidateOrigin
        let environmentVariable: String?
        let isDirectFile: Bool
    }

    struct Entry: Sendable {
        let provider: Provider
        let service: String
        let displayName: String
        let emoji: String
        let defaultPath: String
        let defaultOrigin: CandidateOrigin
        let environmentVariables: [String]
        let compatibilityEnvironmentVariables: [String]
        let parserInput: String
        let limitation: String?
    }

    private enum EnvironmentTransform: Sendable {
        case directory
        case child(String)
        case file
        case fileParent
    }

    private struct EnvironmentRule: Sendable {
        let name: String
        let transform: EnvironmentTransform
        let official: Bool
    }

    static var homeDirectory: String {
        if let value = ProcessInfo.processInfo.environment["HOME"], !value.isEmpty {
            let expanded = expandEnvironmentVariables(in: value)
            if expanded.hasPrefix("/") {
                return (expanded as NSString).standardizingPath
            }
        }
        return (NSHomeDirectory() as NSString).standardizingPath
    }

    static var configHome: String {
        xdgDirectory(variable: "XDG_CONFIG_HOME", fallbackComponents: [".config"])
    }

    static var dataHome: String {
        xdgDirectory(variable: "XDG_DATA_HOME", fallbackComponents: [".local", "share"])
    }

    static var stateHome: String {
        xdgDirectory(variable: "XDG_STATE_HOME", fallbackComponents: [".local", "state"])
    }

    static func entry(for provider: Provider) -> Entry {
        switch provider {
        case .openclaw:
            return Entry(
                provider: provider, service: "openclaw", displayName: "OpenClaw", emoji: "⚡",
                defaultPath: home(".openclaw"), defaultOrigin: .officialDefault,
                environmentVariables: ["OPENCLAW_STATE_DIR", "OPENCLAW_HOME"],
                compatibilityEnvironmentVariables: [],
                parserInput: "agents/*/sessions/*.jsonl",
                limitation: "Current SQLite-only OpenClaw transcripts are not parsed; legacy JSONL transcripts are required."
            )
        case .claudeCode:
            return Entry(
                provider: provider, service: "claudeCode", displayName: "Claude Code", emoji: "🧠",
                defaultPath: home(".claude"), defaultOrigin: .officialDefault,
                environmentVariables: ["CLAUDE_CONFIG_DIR"], compatibilityEnvironmentVariables: [],
                parserInput: "projects/**/*.jsonl", limitation: nil
            )
        case .gemini:
            return Entry(
                provider: provider, service: "gemini", displayName: "Gemini CLI", emoji: "💎",
                defaultPath: home(".gemini"), defaultOrigin: .officialDefault,
                environmentVariables: ["GEMINI_CLI_HOME"], compatibilityEnvironmentVariables: ["GEMINI_HOME"],
                parserInput: "tmp/*/chats/session-*.jsonl (or legacy JSON)",
                limitation: "GEMINI_CLI_HOME is a parent directory; Gemini stores data in its .gemini child."
            )
        case .codex:
            return Entry(
                provider: provider, service: "codex", displayName: "Codex", emoji: "🤖",
                defaultPath: home(".codex"), defaultOrigin: .officialDefault,
                environmentVariables: ["CODEX_HOME"], compatibilityEnvironmentVariables: [],
                parserInput: "sessions/YYYY/MM/DD/rollout-*.jsonl", limitation: nil
            )
        case .hermes:
            return Entry(
                provider: provider, service: "hermes", displayName: "Hermes", emoji: "🏔️",
                defaultPath: home(".hermes"), defaultOrigin: .officialDefault,
                environmentVariables: ["HERMES_HOME"], compatibilityEnvironmentVariables: [],
                parserInput: "state.db (sessions table)", limitation: nil
            )
        case .opencode:
            return Entry(
                provider: provider, service: "opencode", displayName: "OpenCode", emoji: "🐙",
                defaultPath: data("opencode"), defaultOrigin: .officialDefault,
                environmentVariables: ["OPENCODE_DB", "XDG_DATA_HOME"], compatibilityEnvironmentVariables: ["OPENCODE_HOME"],
                parserInput: "opencode.db (session table)",
                limitation: "OPENCODE_HOME is retained only as a TokenClock compatibility override."
            )
        case .qwen:
            return Entry(
                provider: provider, service: "qwen", displayName: "Qwen Code", emoji: "🟣",
                defaultPath: home(".qwen"), defaultOrigin: .officialDefault,
                environmentVariables: ["QWEN_RUNTIME_DIR", "QWEN_HOME"], compatibilityEnvironmentVariables: [],
                parserInput: "projects/*/chats/*.jsonl", limitation: nil
            )
        case .copilot:
            return Entry(
                provider: provider, service: "copilot", displayName: "GitHub Copilot CLI", emoji: "🐙",
                defaultPath: home(".copilot"), defaultOrigin: .officialDefault,
                environmentVariables: ["COPILOT_HOME", "COPILOT_OTEL_FILE_EXPORTER_PATH"], compatibilityEnvironmentVariables: [],
                parserInput: "session-state/*/events.jsonl and optional OTel JSONL",
                limitation: "Detailed token fields require Copilot OTel file export; session events can contain less detail."
            )
        case .grok:
            return Entry(
                provider: provider, service: "grok", displayName: "Grok CLI", emoji: "⚡",
                defaultPath: home(".grok"), defaultOrigin: .officialDefault,
                environmentVariables: [], compatibilityEnvironmentVariables: ["GROK_HOME"],
                parserInput: "sessions/*/*/updates.jsonl",
                limitation: "GROK_HOME is a TokenClock compatibility override; no official Grok home override is documented."
            )
        case .aider:
            return Entry(
                provider: provider, service: "aider", displayName: "Aider", emoji: "🤝",
                defaultPath: state("aider"), defaultOrigin: .linuxConvention,
                environmentVariables: ["AIDER_ANALYTICS_LOG", "XDG_STATE_HOME"],
                compatibilityEnvironmentVariables: ["AIDER_HOME"],
                parserInput: "analytics.jsonl",
                limitation: "Aider does not create a default analytics log; pass --analytics-log or set AIDER_ANALYTICS_LOG."
            )
        case .antigravity:
            return Entry(
                provider: provider, service: "antigravity", displayName: "Antigravity", emoji: "🛡️",
                defaultPath: home(".gemini", "antigravity-cli"), defaultOrigin: .officialDefault,
                environmentVariables: [], compatibilityEnvironmentVariables: ["ANTIGRAVITY_HOME"],
                parserInput: "conversations/*.db (steps protobuf telemetry)",
                limitation: "ANTIGRAVITY_HOME is a TokenClock compatibility override."
            )
        case .cline:
            return Entry(
                provider: provider, service: "cline", displayName: "Cline", emoji: "🤖",
                defaultPath: config("Code", "User", "globalStorage", "saoudrizwan.claude-dev"),
                defaultOrigin: .officialDefault,
                environmentVariables: ["XDG_CONFIG_HOME"], compatibilityEnvironmentVariables: ["CLINE_HOME"],
                parserInput: "tasks/*/api_conversation.json",
                limitation: "Portable and remote VS Code installations are probed as alternates; CLINE_HOME remains a compatibility override."
            )
        case .continue:
            return Entry(
                provider: provider, service: "continue", displayName: "Continue", emoji: "▶️",
                defaultPath: home(".continue"), defaultOrigin: .officialDefault,
                environmentVariables: [], compatibilityEnvironmentVariables: ["CONTINUE_HOME"],
                parserInput: "dev_data/*.jsonl and sessions/*.jsonl",
                limitation: "CONTINUE_HOME is a TokenClock compatibility override."
            )
        case .cursorAgent:
            return Entry(
                provider: provider, service: "cursorAgent", displayName: "Cursor Agent", emoji: "🖱️",
                defaultPath: config("Cursor", "User", "globalStorage"), defaultOrigin: .officialDefault,
                environmentVariables: ["XDG_CONFIG_HOME"], compatibilityEnvironmentVariables: ["CURSOR_AGENT_HOME"],
                parserInput: "state.vscdb (cursorAuth/accessToken), then Cursor usage API",
                limitation: "Local detection only verifies credentials; usage still comes from Cursor's authenticated network API."
            )
        }
    }

    static func candidates(for provider: Provider) -> [Candidate] {
        let entry = entry(for: provider)
        var result: [Candidate] = []
        var seen = Set<String>()

        func append(
            _ rawPath: String,
            origin: CandidateOrigin,
            variable: String? = nil,
            isDirectFile: Bool = false
        ) {
            let path = normalizedPath(rawPath)
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            result.append(Candidate(
                path: path,
                origin: origin,
                environmentVariable: variable,
                isDirectFile: isDirectFile
            ))
        }

        for rule in environmentRules(for: provider) {
            guard let rawValue = ProcessInfo.processInfo.environment[rule.name], !rawValue.isEmpty else {
                continue
            }
            if rule.name.hasPrefix("XDG_") {
                let expanded = expandEnvironmentVariables(in: rawValue)
                guard expanded.hasPrefix("/") else { continue }
            }
            guard
                  let resolved = environmentPath(rawValue, transform: rule.transform) else { continue }
            append(
                resolved.path,
                origin: rule.official ? .officialEnvironment : .compatibilityEnvironment,
                variable: rule.name,
                isDirectFile: resolved.isDirectFile
            )
        }

        append(entry.defaultPath, origin: entry.defaultOrigin)
        for alternate in alternatePaths(for: provider) {
            append(alternate, origin: .alternate)
        }
        return result
    }

    static func normalizedPath(_ rawPath: String) -> String {
        var expanded = expandEnvironmentVariables(in: rawPath)
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + String(expanded.dropFirst())
        } else {
            expanded = (expanded as NSString).expandingTildeInPath
        }
        if !expanded.hasPrefix("/") {
            expanded = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded).path
        }
        return (expanded as NSString).standardizingPath
    }

    static func expandEnvironmentVariables(in rawValue: String) -> String {
        let expression = try? NSRegularExpression(
            pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
        )
        guard let expression else { return rawValue }
        let environment = ProcessInfo.processInfo.environment
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        var value = rawValue
        for match in expression.matches(in: rawValue, range: range).reversed() {
            let nameRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let swiftNameRange = Range(nameRange, in: rawValue),
                  let swiftMatchRange = Range(match.range, in: value),
                  let replacement = environment[String(rawValue[swiftNameRange])] else { continue }
            value.replaceSubrange(swiftMatchRange, with: replacement)
        }
        return value
    }

    private static func environmentRules(for provider: Provider) -> [EnvironmentRule] {
        switch provider {
        case .openclaw:
            return [
                EnvironmentRule(name: "OPENCLAW_STATE_DIR", transform: .directory, official: true),
                EnvironmentRule(name: "OPENCLAW_HOME", transform: .child(".openclaw"), official: true),
            ]
        case .claudeCode:
            return [EnvironmentRule(name: "CLAUDE_CONFIG_DIR", transform: .directory, official: true)]
        case .gemini:
            return [
                EnvironmentRule(name: "GEMINI_CLI_HOME", transform: .child(".gemini"), official: true),
                EnvironmentRule(name: "GEMINI_HOME", transform: .directory, official: false),
            ]
        case .codex:
            return [EnvironmentRule(name: "CODEX_HOME", transform: .directory, official: true)]
        case .hermes:
            return [EnvironmentRule(name: "HERMES_HOME", transform: .directory, official: true)]
        case .opencode:
            return [
                EnvironmentRule(name: "OPENCODE_DB", transform: .file, official: true),
                EnvironmentRule(name: "OPENCODE_HOME", transform: .directory, official: false),
                EnvironmentRule(name: "XDG_DATA_HOME", transform: .child("opencode"), official: true),
            ]
        case .qwen:
            return [
                EnvironmentRule(name: "QWEN_RUNTIME_DIR", transform: .directory, official: true),
                EnvironmentRule(name: "QWEN_HOME", transform: .directory, official: true),
            ]
        case .copilot:
            return [
                EnvironmentRule(name: "COPILOT_HOME", transform: .directory, official: true),
                EnvironmentRule(name: "COPILOT_OTEL_FILE_EXPORTER_PATH", transform: .file, official: true),
            ]
        case .grok:
            return [EnvironmentRule(name: "GROK_HOME", transform: .directory, official: false)]
        case .aider:
            return [
                EnvironmentRule(name: "AIDER_ANALYTICS_LOG", transform: .fileParent, official: true),
                EnvironmentRule(name: "AIDER_HOME", transform: .directory, official: false),
                EnvironmentRule(name: "XDG_STATE_HOME", transform: .child("aider"), official: false),
            ]
        case .antigravity:
            return [EnvironmentRule(name: "ANTIGRAVITY_HOME", transform: .directory, official: false)]
        case .cline:
            return [
                EnvironmentRule(name: "CLINE_HOME", transform: .directory, official: false),
                EnvironmentRule(
                    name: "XDG_CONFIG_HOME",
                    transform: .child("Code/User/globalStorage/saoudrizwan.claude-dev"),
                    official: true
                ),
            ]
        case .continue:
            return [EnvironmentRule(name: "CONTINUE_HOME", transform: .directory, official: false)]
        case .cursorAgent:
            return [
                EnvironmentRule(name: "CURSOR_AGENT_HOME", transform: .directory, official: false),
                EnvironmentRule(name: "XDG_CONFIG_HOME", transform: .child("Cursor/User/globalStorage"), official: true),
            ]
        }
    }

    private static func alternatePaths(for provider: Provider) -> [String] {
        switch provider {
        case .opencode:
            return [home(".local", "share", "opencode"), home(".opencode")]
        case .aider:
            return [home(".aider")]
        case .antigravity:
            return [home(".gemini", "antigravity-ide"), home(".gemini", "antigravity")]
        case .cline:
            return [
                config("VSCodium", "User", "globalStorage", "saoudrizwan.claude-dev"),
                config("Code - OSS", "User", "globalStorage", "saoudrizwan.claude-dev"),
                config("Cursor", "User", "globalStorage", "saoudrizwan.claude-dev"),
                home(".vscode-server", "data", "User", "globalStorage", "saoudrizwan.claude-dev"),
                home(".vscode-server-insiders", "data", "User", "globalStorage", "saoudrizwan.claude-dev"),
                home(".cursor-server", "data", "User", "globalStorage", "saoudrizwan.claude-dev"),
            ]
        case .cursorAgent:
            return [home(".cursor-server", "data", "User", "globalStorage")]
        default:
            return []
        }
    }

    private static func environmentPath(
        _ rawValue: String,
        transform: EnvironmentTransform
    ) -> (path: String, isDirectFile: Bool)? {
        let value = expandEnvironmentVariables(in: rawValue)
        guard value != "-" else { return nil }
        let normalized = normalizedPath(value)
        switch transform {
        case .directory:
            return (normalized, false)
        case .child(let child):
            return (
                URL(fileURLWithPath: normalized, isDirectory: true)
                    .appendingPathComponent(child, isDirectory: true).path,
                false
            )
        case .file:
            return (normalized, true)
        case .fileParent:
            return (URL(fileURLWithPath: normalized).deletingLastPathComponent().path, false)
        }
    }

    private static func xdgDirectory(variable: String, fallbackComponents: [String]) -> String {
        if let rawValue = ProcessInfo.processInfo.environment[variable], !rawValue.isEmpty {
            let expanded = expandEnvironmentVariables(in: rawValue)
            if expanded.hasPrefix("/") { return normalizedPath(expanded) }
        }
        return home(fallbackComponents)
    }

    private static func home(_ components: String...) -> String { home(components) }

    private static func home(_ components: [String]) -> String {
        path(root: homeDirectory, components: components)
    }

    private static func config(_ components: String...) -> String {
        path(root: configHome, components: components)
    }

    private static func data(_ components: String...) -> String {
        path(root: dataHome, components: components)
    }

    private static func state(_ components: String...) -> String {
        path(root: stateHome, components: components)
    }

    private static func path(root: String, components: [String]) -> String {
        components.reduce(root) { partial, component in
            URL(fileURLWithPath: partial, isDirectory: true)
                .appendingPathComponent(component, isDirectory: true).path
        }
    }
}
#endif
