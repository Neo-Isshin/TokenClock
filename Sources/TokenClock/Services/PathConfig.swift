import Foundation

/// 路径配置：支持用户自定义、环境变量、自动探测各数据源的日志目录
/// 优先级：UserDefaults 自定义 > 环境变量 > 官方默认路径
enum PathConfig {
    private static let prefix = "TC_"

    // MARK: - 环境变量名

    private static let envOpenClaw = "OPENCLAW_HOME"
    private static let envOpenClawState = "OPENCLAW_STATE_DIR"
    private static let envClaudeCode = "CLAUDE_CONFIG_DIR"
    /// Gemini CLI treats GEMINI_CLI_HOME as the *parent* of its `.gemini` data directory.
    /// GEMINI_HOME was used by early community builds; keep it as a compatibility fallback only.
    private static let envGeminiCLIHome = "GEMINI_CLI_HOME"
    private static let envGeminiLegacy = "GEMINI_HOME"
    private static let envCodex = "CODEX_HOME"
    private static let envHermes = "HERMES_HOME"
    private static let envOpenCode = "OPENCODE_HOME"
    private static let envOpenCodeDatabase = "OPENCODE_DB"
    private static let envQwen = "QWEN_HOME"
    private static let envQwenRuntime = "QWEN_RUNTIME_DIR"
    private static let envCopilot = "COPILOT_HOME"
    private static let envCopilotOtelFile = "COPILOT_OTEL_FILE_EXPORTER_PATH"
    private static let envGrok = "GROK_HOME"
    private static let envAiderAnalyticsLog = "AIDER_ANALYTICS_LOG"
    private static let envAiderLegacy = "AIDER_HOME"
    private static let envAntigravity = "ANTIGRAVITY_HOME"
    private static let envCline = "CLINE_HOME"
    private static let envContinue = "CONTINUE_HOME"
    private static let envCursorAgent = "CURSOR_AGENT_HOME"

    // MARK: - 读取路径（含探测缓存）

    static func openclawHome() -> String {
        #if os(Windows)
        if let custom = customPath(forKey: "openclawPath") { return custom }
        if let state = envPath(envOpenClawState) { return state }
        if let parent = envPath(envOpenClaw) { return childDirectory(".openclaw", of: parent) }
        return defaultOpenclawHome()
        #else
        customPath(forKey: "openclawPath") ?? envPath(envOpenClaw) ?? defaultOpenclawHome()
        #endif
    }

    static func claudeCodeHome() -> String {
        customPath(forKey: "claudeCodePath") ?? envPath(envClaudeCode) ?? defaultClaudeCodeHome()
    }

    static func geminiHome() -> String {
        #if os(Windows)
        customPath(forKey: "geminiPath") ?? geminiEnvironmentHome() ?? defaultGeminiHome()
        #else
        customPath(forKey: "geminiPath") ?? envPath(envGeminiLegacy) ?? defaultGeminiHome()
        #endif
    }

    static func codexHome() -> String {
        customPath(forKey: "codexPath") ?? envPath(envCodex) ?? defaultCodexHome()
    }

    static func hermesHome() -> String {
        customPath(forKey: "hermesPath") ?? envPath(envHermes) ?? defaultHermesHome()
    }

    static func opencodeHome() -> String {
        #if os(Windows)
        if let custom = customPath(forKey: "opencodePath") {
            return custom.lowercased().hasSuffix(".db")
                ? (custom as NSString).deletingLastPathComponent
                : custom
        }
        if let compatibilityHome = envPath(envOpenCode) { return compatibilityHome }
        if let xdgData = envPath("XDG_DATA_HOME") { return childDirectory("opencode", of: xdgData) }
        return defaultOpenCodeHome()
        #else
        customPath(forKey: "opencodePath") ?? envPath(envOpenCode) ?? defaultOpenCodeHome()
        #endif
    }

    static func opencodeDatabasePath() -> String {
        #if os(Windows)
        if let custom = customPath(forKey: "opencodePath") { return databaseFile(from: custom) }
        if let officialDatabase = envPath(envOpenCodeDatabase) { return officialDatabase }
        return databaseFile(from: opencodeHome())
        #else
        return opencodeHome() + "/opencode.db"
        #endif
    }

    static func qwenHome() -> String {
        #if os(Windows)
        customPath(forKey: "qwenPath") ?? envPath(envQwenRuntime) ?? envPath(envQwen) ?? defaultQwenHome()
        #else
        customPath(forKey: "qwenPath") ?? envPath(envQwen) ?? defaultQwenHome()
        #endif
    }

    static func copilotHome() -> String {
        customPath(forKey: "copilotPath") ?? envPath(envCopilot) ?? defaultCopilotHome()
    }

    static func copilotOtelFileOverride() -> String? {
        #if os(Windows)
        if let custom = customPath(forKey: "copilotPath"), custom.lowercased().hasSuffix(".jsonl") {
            return custom
        }
        return envPath(envCopilotOtelFile)
        #else
        return nil
        #endif
    }

    static func grokHome() -> String {
        customPath(forKey: "grokPath") ?? envPath(envGrok) ?? defaultGrokHome()
    }

    /// Aider does not own a standard data directory. Token usage is available only when the
    /// official `--analytics-log` / `AIDER_ANALYTICS_LOG` option writes a JSONL file. For
    /// compatibility, a directory entered in Settings resolves to `analytics.jsonl` inside it.
    static func aiderAnalyticsPath() -> String {
        #if os(Windows)
        if let custom = customPath(forKey: "aiderPath") { return analyticsFile(from: custom) }
        if let environment = envPath(envAiderAnalyticsLog) { return analyticsFile(from: environment) }
        if let legacyHome = envPath(envAiderLegacy) { return analyticsFile(from: legacyHome) }
        return defaultAiderAnalyticsPath()
        #else
        return aiderHome() + "/analytics.jsonl"
        #endif
    }

    /// Settings-facing value: retain the user's exact file/directory entry.
    static func aiderHome() -> String {
        #if os(Windows)
        customPath(forKey: "aiderPath") ?? envPath(envAiderAnalyticsLog) ?? defaultAiderHome()
        #else
        customPath(forKey: "aiderPath") ?? envPath(envAiderLegacy) ?? defaultAiderHome()
        #endif
    }

    static func antigravityHome() -> String {
        customPath(forKey: "antigravityPath") ?? envPath(envAntigravity) ?? defaultAntigravityHome()
    }

    static func clineHome() -> String {
        customPath(forKey: "clinePath") ?? envPath(envCline) ?? defaultClineHome()
    }

    static func continueHome() -> String {
        customPath(forKey: "continuePath") ?? envPath(envContinue) ?? defaultContinueHome()
    }

    static func cursorAgentHome() -> String {
        customPath(forKey: "cursorAgentPath") ?? envPath(envCursorAgent) ?? defaultCursorAgentHome()
    }

    // MARK: - 默认路径

    static func defaultOpenclawHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.openclaw).defaultPath
        #else
        NSHomeDirectory() + "/.openclaw"
        #endif
    }

    static func defaultClaudeCodeHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.claudeCode).defaultPath
        #else
        NSHomeDirectory() + "/.claude"
        #endif
    }

    static func defaultGeminiHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.gemini).defaultPath
        #else
        NSHomeDirectory() + "/.gemini"
        #endif
    }

    static func defaultCodexHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.codex).defaultPath
        #else
        NSHomeDirectory() + "/.codex"
        #endif
    }

    static func defaultHermesHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.hermes).defaultPath
        #else
        NSHomeDirectory() + "/.hermes"
        #endif
    }

    static func defaultOpenCodeHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.opencode).defaultPath
        #else
        NSHomeDirectory() + "/.local/share/opencode"
        #endif
    }

    static func defaultQwenHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.qwen).defaultPath
        #else
        NSHomeDirectory() + "/.qwen"
        #endif
    }

    static func defaultCopilotHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.copilot).defaultPath
        #else
        NSHomeDirectory() + "/.copilot"
        #endif
    }

    static func defaultGrokHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.grok).defaultPath
        #else
        NSHomeDirectory() + "/.grok"
        #endif
    }

    static func defaultAiderHome() -> String {
        #if os(Windows)
        return (WindowsProviderCatalog.entry(.aider).defaultPath as NSString).deletingLastPathComponent
        #else
        NSHomeDirectory() + "/.aider"
        #endif
    }

    static func defaultAiderAnalyticsPath() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.aider).defaultPath
        #else
        defaultAiderHome() + "/analytics.jsonl"
        #endif
    }

    static func defaultAntigravityHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.antigravity).defaultPath
        #else
        NSHomeDirectory() + "/.gemini/antigravity-cli"
        #endif
    }

    static func defaultClineHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.cline).defaultPath
        #else
        AppPaths.appSupport("Code", "User", "globalStorage", "saoudrizwan.claude-dev")
        #endif
    }

    static func defaultContinueHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.continue).defaultPath
        #else
        NSHomeDirectory() + "/.continue"
        #endif
    }

    static func defaultCursorAgentHome() -> String {
        #if os(Windows)
        return WindowsProviderCatalog.entry(.cursorAgent).defaultPath
        #else
        return NSHomeDirectory() + "/.cursor"
        #endif
    }

    // MARK: - 备选探测路径（官方文档中的其他常见位置）

    /// OpenClaw 的所有可能数据目录候选
    static func openclawCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let env = envPath(envOpenClawState) { candidates.append(env) }
        if let parent = envPath(envOpenClaw) { candidates.append(childDirectory(".openclaw", of: parent)) }
        #else
        if let env = envPath(envOpenClaw) { candidates.append(env) }
        #endif
        candidates.append(defaultOpenclawHome())
        #if !os(Windows)
        // OpenClaw 也可能通过 LaunchAgent 安装，检查日志目录
        candidates.append(NSHomeDirectory() + "/Library/Logs/OpenClaw")
        #endif
        return candidates
    }

    /// Claude Code 的所有可能数据目录候选
    static func claudeCodeCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envClaudeCode) { candidates.append(env) }
        candidates.append(defaultClaudeCodeHome())
        #if !os(Windows)
        // Claude Desktop 日志位置（部分 session 数据可能在此）
        candidates.append(AppPaths.appSupport("Claude"))
        #endif
        return candidates
    }

    /// Gemini CLI 的所有可能数据目录候选
    static func geminiCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let env = geminiEnvironmentHome() { candidates.append(env) }
        #else
        if let env = envPath(envGeminiLegacy) { candidates.append(env) }
        #endif
        candidates.append(defaultGeminiHome())
        return candidates
    }

    /// Codex 的所有可能数据目录候选
    static func codexCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envCodex) { candidates.append(env) }
        candidates.append(defaultCodexHome())
        #if !os(Windows)
        // Codex 也可能在 .config 下（XDG 规范）
        candidates.append(NSHomeDirectory() + "/.config/codex")
        #endif
        return candidates
    }

    /// Hermes 的所有可能数据目录候选
    static func hermesCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envHermes) { candidates.append(env) }
        candidates.append(defaultHermesHome())
        #if os(Windows)
        candidates.append(contentsOf: WindowsProviderCatalog.entry(.hermes).alternatePaths)
        #endif
        return candidates
    }

    static func opencodeCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let database = envPath(envOpenCodeDatabase) { candidates.append(database) }
        if let env = envPath(envOpenCode) { candidates.append(env) }
        if let xdg = envPath("XDG_DATA_HOME") { candidates.append(childDirectory("opencode", of: xdg)) }
        candidates.append(defaultOpenCodeHome())
        candidates.append(contentsOf: WindowsProviderCatalog.entry(.opencode).alternatePaths)
        #else
        if let env = envPath(envOpenCode) { candidates.append(env) }
        candidates.append(defaultOpenCodeHome())
        candidates.append(NSHomeDirectory() + "/.opencode")
        #endif
        return candidates
    }

    static func qwenCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let env = envPath(envQwenRuntime) { candidates.append(env) }
        #endif
        if let env = envPath(envQwen) { candidates.append(env) }
        candidates.append(defaultQwenHome())
        return candidates
    }

    static func copilotCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let otelFile = envPath(envCopilotOtelFile) { candidates.append(otelFile) }
        #endif
        if let env = envPath(envCopilot) { candidates.append(env) }
        candidates.append(defaultCopilotHome())
        return candidates
    }

    static func grokCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envGrok) { candidates.append(env) }
        candidates.append(defaultGrokHome())
        return candidates
    }

    static func aiderCandidates() -> [String] {
        var candidates: [String] = []
        #if os(Windows)
        if let env = envPath(envAiderAnalyticsLog) { candidates.append(analyticsFile(from: env)) }
        candidates.append(defaultAiderAnalyticsPath())
        #else
        if let env = envPath(envAiderLegacy) { candidates.append(env) }
        candidates.append(defaultAiderHome())
        #endif
        return candidates
    }

    static func antigravityCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envAntigravity) { candidates.append(env) }
        candidates.append(defaultAntigravityHome())
        return candidates
    }

    /// Antigravity 会话数据库目录列表。
    /// CLI / IDE / 主应用各自把对话存到 `~/.gemini/{antigravity-cli,antigravity-ide,antigravity}/conversations/*.db`，
    /// 三者 SQLite schema 与 protobuf 遥测格式同源，统计逻辑统一处理。
    ///
    /// 始终扫描这三个标准目录——IDE 的对话就活在 antigravity-ide 下，绝不能漏。
    /// 设置了自定义路径或 `ANTIGRAVITY_HOME` 时，作为【额外】目录追加（用于真正移动过安装的用户），
    /// 而非替换标准目录：历史上自动检测会把 CLI 子路径写进 override，若用它早返回，就会把 IDE 整个旁路掉，
    /// 导致 Antigravity 今日用量恒为 0。重复目录由 AntigravityUsageService 的全局 tracking_id 去重兜底。
    static func antigravityConversationDirs() -> [String] {
        let gemini = NSHomeDirectory() + "/.gemini"
        var dirs = ["antigravity-cli", "antigravity-ide", "antigravity"].map {
            gemini + "/" + $0 + "/conversations"
        }
        if var override = customPath(forKey: "antigravityPath") ?? envPath(envAntigravity) {
            while override.hasSuffix("/") { override.removeLast() }
            let overrideDir = override + "/conversations"
            if !dirs.contains(overrideDir) { dirs.append(overrideDir) }
        }
        return dirs
    }

    static func clineCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envCline) { candidates.append(env) }
        candidates.append(defaultClineHome())
        // Cursor 扩展位置
        #if os(Windows)
        candidates.append(contentsOf: WindowsProviderCatalog.entry(.cline).alternatePaths)
        #else
        candidates.append(AppPaths.appSupport("Cursor", "User", "globalStorage", "saoudrizwan.claude-dev"))
        #endif
        return candidates
    }

    static func continueCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envContinue) { candidates.append(env) }
        candidates.append(defaultContinueHome())
        return candidates
    }

    static func cursorAgentCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envCursorAgent) { candidates.append(env) }
        candidates.append(defaultCursorAgentHome())
        return candidates
    }

    // MARK: - 写入路径

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

    // MARK: - 首次启动标记

    #if os(Windows)
    static var hasRunInitialDetection: Bool {
        get { UserDefaults.standard.bool(for: .hasRunInitialDetection) }
        set { UserDefaults.standard.setBool(newValue, for: .hasRunInitialDetection) }
    }
    #else
    static var hasRunInitialDetection: Bool {
        get { UserDefaults.standard.bool(forKey: prefix + "hasRunInitialDetection") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "hasRunInitialDetection") }
    }
    #endif

    // MARK: - 内部

    private static func customPath(forKey key: String) -> String? {
        #if os(Windows)
        guard let settingsKey = SettingsKey(rawValue: prefix + key) else { return nil }
        let val = UserDefaults.standard.string(for: settingsKey)
        #else
        let val = UserDefaults.standard.string(forKey: prefix + key)
        #endif
        guard let val, !val.isEmpty else { return nil }
        #if os(Windows)
        return expandedPath(val)
        #else
        return val
        #endif
    }

    private static func setCustomPath(_ path: String, forKey key: String) {
        #if os(Windows)
        guard let settingsKey = SettingsKey(rawValue: prefix + key) else { return }
        if path.isEmpty {
            UserDefaults.standard.remove(settingsKey)
        } else {
            UserDefaults.standard.setString(path, for: settingsKey)
        }
        #else
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        } else {
            UserDefaults.standard.set(path, forKey: prefix + key)
        }
        #endif
    }

    private static func envPath(_ name: String) -> String? {
        let val = ProcessInfo.processInfo.environment[name]
        guard let val, !val.isEmpty else { return nil }
        #if os(Windows)
        return expandedPath(val)
        #else
        return val
        #endif
    }

    /// Expand the path forms users naturally paste into Settings. Foundation's tilde expansion
    /// is not consistent across Windows Foundation builds, so handle it explicitly as well as
    /// `%APPDATA%`, `$env:APPDATA`, `${APPDATA}` and `$APPDATA` forms.
    static func expandedPath(_ raw: String) -> String {
        #if os(Windows)
        return WindowsProviderCatalog.expand(raw)
        #else
        return (raw as NSString).standardizingPath
        #endif
    }

    private static func geminiEnvironmentHome() -> String? {
        if let parent = envPath(envGeminiCLIHome) {
            let normalized = parent.replacingOccurrences(of: "\\", with: "/")
            if normalized.hasSuffix("/.gemini") { return parent }
            return parent + "/.gemini"
        }
        return envPath(envGeminiLegacy)
    }

    private static func analyticsFile(from path: String) -> String {
        let expanded = expandedPath(path)
        return expanded.lowercased().hasSuffix(".jsonl") ? expanded : expanded + "/analytics.jsonl"
    }

    private static func databaseFile(from path: String) -> String {
        let expanded = expandedPath(path)
        return expanded.lowercased().hasSuffix(".db") ? expanded : expanded + "/opencode.db"
    }

    private static func childDirectory(_ child: String, of parent: String) -> String {
        let expanded = expandedPath(parent)
        let normalized = expanded.replacingOccurrences(of: "\\", with: "/")
        if normalized.lowercased().hasSuffix("/\(child.lowercased())") { return expanded }
        return expandedPath(expanded + "/" + child)
    }
}
