#if os(Linux)
import Foundation

/// Linux path configuration facade used by the shared parsers.
///
/// Resolution order is: saved custom path, provider environment variables,
/// Linux catalog default. Paths support `~`, `$VAR`, and `${VAR}` expansion.
enum PathConfig {
    private static let prefix = "TC_"

    static func openclawHome() -> String { home(.openclaw, key: "openclawPath") }
    static func claudeCodeHome() -> String { home(.claudeCode, key: "claudeCodePath") }
    static func geminiHome() -> String { home(.gemini, key: "geminiPath") }
    static func codexHome() -> String { home(.codex, key: "codexPath") }
    static func hermesHome() -> String { home(.hermes, key: "hermesPath") }
    static func opencodeHome() -> String { home(.opencode, key: "opencodePath") }
    static func qwenHome() -> String { home(.qwen, key: "qwenPath") }
    static func copilotHome() -> String { home(.copilot, key: "copilotPath") }
    static func grokHome() -> String { home(.grok, key: "grokPath") }
    static func aiderHome() -> String { home(.aider, key: "aiderPath") }
    static func antigravityHome() -> String { home(.antigravity, key: "antigravityPath") }
    static func clineHome() -> String { home(.cline, key: "clinePath") }
    static func continueHome() -> String { home(.continue, key: "continuePath") }
    static func cursorAgentHome() -> String { home(.cursorAgent, key: "cursorAgentPath") }

    static func opencodeDatabasePath() -> String {
        if let custom = customPath(forKey: "opencodePath") {
            return custom.hasSuffix(".db") ? custom : custom + "/opencode.db"
        }
        if let direct = firstDirectEnvironmentFile(.opencode) { return direct }
        return home(.opencode, key: "opencodePath") + "/opencode.db"
    }

    static func copilotOtelFile() -> String? {
        if let custom = customPath(forKey: "copilotPath"), custom.hasSuffix(".jsonl") {
            return custom
        }
        return firstDirectEnvironmentFile(.copilot)
    }

    static func defaultOpenclawHome() -> String { defaultPath(.openclaw) }
    static func defaultClaudeCodeHome() -> String { defaultPath(.claudeCode) }
    static func defaultGeminiHome() -> String { defaultPath(.gemini) }
    static func defaultCodexHome() -> String { defaultPath(.codex) }
    static func defaultHermesHome() -> String { defaultPath(.hermes) }
    static func defaultOpenCodeHome() -> String { defaultPath(.opencode) }
    static func defaultQwenHome() -> String { defaultPath(.qwen) }
    static func defaultCopilotHome() -> String { defaultPath(.copilot) }
    static func defaultGrokHome() -> String { defaultPath(.grok) }
    static func defaultAiderHome() -> String { defaultPath(.aider) }
    static func defaultAntigravityHome() -> String { defaultPath(.antigravity) }
    static func defaultClineHome() -> String { defaultPath(.cline) }
    static func defaultContinueHome() -> String { defaultPath(.continue) }
    static func defaultCursorAgentHome() -> String { defaultPath(.cursorAgent) }

    static func openclawCandidates() -> [String] { candidates(.openclaw) }
    static func claudeCodeCandidates() -> [String] { candidates(.claudeCode) }
    static func geminiCandidates() -> [String] { candidates(.gemini) }
    static func codexCandidates() -> [String] { candidates(.codex) }
    static func hermesCandidates() -> [String] { candidates(.hermes) }
    static func opencodeCandidates() -> [String] { candidates(.opencode) }
    static func qwenCandidates() -> [String] { candidates(.qwen) }
    static func copilotCandidates() -> [String] { candidates(.copilot) }
    static func grokCandidates() -> [String] { candidates(.grok) }
    static func aiderCandidates() -> [String] { candidates(.aider) }
    static func antigravityCandidates() -> [String] { candidates(.antigravity) }
    static func clineCandidates() -> [String] { candidates(.cline) }
    static func continueCandidates() -> [String] { candidates(.continue) }
    static func cursorAgentCandidates() -> [String] { candidates(.cursorAgent) }

    static func antigravityConversationDirs() -> [String] {
        var roots = [
            defaultPath(.antigravity),
            LinuxProviderCatalog.homeDirectory + "/.gemini/antigravity-ide",
            LinuxProviderCatalog.homeDirectory + "/.gemini/antigravity",
        ]
        if let override = customPath(forKey: "antigravityPath")
            ?? firstEnvironmentPath(.antigravity) {
            roots.insert(override, at: 0)
        }
        var seen = Set<String>()
        return roots.compactMap { root in
            let directory = LinuxProviderCatalog.normalizedPath(root) + "/conversations"
            guard seen.insert(directory).inserted else { return nil }
            return directory
        }
    }

    static func setOpenclawPath(_ path: String) { setCustomPath(path, forKey: "openclawPath") }
    static func setClaudeCodePath(_ path: String) { setCustomPath(path, forKey: "claudeCodePath") }
    static func setGeminiPath(_ path: String) { setCustomPath(path, forKey: "geminiPath") }
    static func setCodexPath(_ path: String) { setCustomPath(path, forKey: "codexPath") }
    static func setHermesPath(_ path: String) { setCustomPath(path, forKey: "hermesPath") }
    static func setOpenCodePath(_ path: String) { setCustomPath(path, forKey: "opencodePath") }
    static func setQwenPath(_ path: String) { setCustomPath(path, forKey: "qwenPath") }
    static func setCopilotPath(_ path: String) { setCustomPath(path, forKey: "copilotPath") }
    static func setGrokPath(_ path: String) { setCustomPath(path, forKey: "grokPath") }
    static func setAiderPath(_ path: String) { setCustomPath(path, forKey: "aiderPath") }
    static func setAntigravityPath(_ path: String) { setCustomPath(path, forKey: "antigravityPath") }
    static func setClinePath(_ path: String) { setCustomPath(path, forKey: "clinePath") }
    static func setContinuePath(_ path: String) { setCustomPath(path, forKey: "continuePath") }
    static func setCursorAgentPath(_ path: String) { setCustomPath(path, forKey: "cursorAgentPath") }

    static var hasRunInitialDetection: Bool {
        get { UserDefaults.standard.bool(forKey: prefix + "hasRunInitialDetection") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "hasRunInitialDetection") }
    }

    private static func home(_ provider: LinuxProviderCatalog.Provider, key: String) -> String {
        customPath(forKey: key)
            ?? firstEnvironmentPath(provider)
            ?? defaultPath(provider)
    }

    private static func defaultPath(_ provider: LinuxProviderCatalog.Provider) -> String {
        LinuxProviderCatalog.entry(for: provider).defaultPath
    }

    private static func candidates(_ provider: LinuxProviderCatalog.Provider) -> [String] {
        LinuxProviderCatalog.candidates(for: provider).map(\.path)
    }

    private static func firstEnvironmentPath(_ provider: LinuxProviderCatalog.Provider) -> String? {
        LinuxProviderCatalog.candidates(for: provider).first {
            guard !$0.isDirectFile else { return false }
            switch $0.origin {
            case .officialEnvironment, .compatibilityEnvironment: return true
            default: return false
            }
        }?.path
    }

    private static func firstDirectEnvironmentFile(
        _ provider: LinuxProviderCatalog.Provider
    ) -> String? {
        LinuxProviderCatalog.candidates(for: provider).first {
            guard $0.isDirectFile else { return false }
            switch $0.origin {
            case .officialEnvironment, .compatibilityEnvironment: return true
            default: return false
            }
        }?.path
    }

    private static func customPath(forKey key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: prefix + key), !value.isEmpty else {
            return nil
        }
        return LinuxProviderCatalog.normalizedPath(value)
    }

    private static func setCustomPath(_ path: String, forKey key: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        } else {
            UserDefaults.standard.set(
                LinuxProviderCatalog.normalizedPath(trimmed),
                forKey: prefix + key
            )
        }
    }
}
#endif
