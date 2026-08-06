import Foundation

/// 路径配置：支持用户自定义、环境变量、自动探测各数据源的日志目录
/// 优先级：UserDefaults 自定义 > 环境变量 > 官方默认路径
enum PathConfig {
    private static let prefix = "TC_"

    // MARK: - 环境变量名

    private static let envOpenClaw = "OPENCLAW_HOME"
    private static let envClaudeCode = "CLAUDE_CONFIG_DIR"
    /// Gemini CLI treats GEMINI_CLI_HOME as the *parent* of its `.gemini` data directory.
    /// GEMINI_HOME was used by early community builds; keep it as a compatibility fallback only.
    private static let envGeminiCLIHome = "GEMINI_CLI_HOME"
    private static let envGeminiLegacy = "GEMINI_HOME"
    private static let envCodex = "CODEX_HOME"
    private static let envHermes = "HERMES_HOME"
    private static let envOpenCode = "OPENCODE_HOME"
    private static let envQwen = "QWEN_HOME"
    private static let envQwenRuntime = "QWEN_RUNTIME_DIR"
    private static let envCopilot = "COPILOT_HOME"
    private static let envGrok = "GROK_HOME"
    private static let envAiderAnalyticsLog = "AIDER_ANALYTICS_LOG"
    private static let envAntigravity = "ANTIGRAVITY_HOME"
    private static let envCline = "CLINE_HOME"
    private static let envContinue = "CONTINUE_HOME"
    private static let envCursorAgent = "CURSOR_AGENT_HOME"

    // MARK: - 读取路径（含探测缓存）

    static func openclawHome() -> String {
        customPath(forKey: "openclawPath") ?? envPath(envOpenClaw) ?? defaultOpenclawHome()
    }

    static func claudeCodeHome() -> String {
        customPath(forKey: "claudeCodePath") ?? envPath(envClaudeCode) ?? defaultClaudeCodeHome()
    }

    static func geminiHome() -> String {
        customPath(forKey: "geminiPath") ?? geminiEnvironmentHome() ?? defaultGeminiHome()
    }

    static func codexHome() -> String {
        customPath(forKey: "codexPath") ?? envPath(envCodex) ?? defaultCodexHome()
    }

    static func hermesHome() -> String {
        customPath(forKey: "hermesPath") ?? envPath(envHermes) ?? defaultHermesHome()
    }

    static func opencodeHome() -> String {
        customPath(forKey: "opencodePath") ?? envPath(envOpenCode) ?? defaultOpenCodeHome()
    }

    static func qwenHome() -> String {
        customPath(forKey: "qwenPath") ?? envPath(envQwenRuntime) ?? envPath(envQwen) ?? defaultQwenHome()
    }

    static func copilotHome() -> String {
        customPath(forKey: "copilotPath") ?? envPath(envCopilot) ?? defaultCopilotHome()
    }

    static func grokHome() -> String {
        customPath(forKey: "grokPath") ?? envPath(envGrok) ?? defaultGrokHome()
    }

    /// Aider does not own a standard data directory. Token usage is available only when the
    /// official `--analytics-log` / `AIDER_ANALYTICS_LOG` option writes a JSONL file. For
    /// compatibility, a directory entered in Settings resolves to `analytics.jsonl` inside it.
    static func aiderAnalyticsPath() -> String {
        if let custom = customPath(forKey: "aiderPath") { return analyticsFile(from: custom) }
        if let environment = envPath(envAiderAnalyticsLog) { return analyticsFile(from: environment) }
        return defaultAiderAnalyticsPath()
    }

    /// Settings-facing value: retain the user's exact file/directory entry.
    static func aiderHome() -> String {
        customPath(forKey: "aiderPath") ?? envPath(envAiderAnalyticsLog) ?? defaultAiderHome()
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
        NSHomeDirectory() + "/.openclaw"
    }

    static func defaultClaudeCodeHome() -> String {
        NSHomeDirectory() + "/.claude"
    }

    static func defaultGeminiHome() -> String {
        NSHomeDirectory() + "/.gemini"
    }

    static func defaultCodexHome() -> String {
        NSHomeDirectory() + "/.codex"
    }

    static func defaultHermesHome() -> String {
        NSHomeDirectory() + "/.hermes"
    }

    static func defaultOpenCodeHome() -> String {
        NSHomeDirectory() + "/.local/share/opencode"
    }

    static func defaultQwenHome() -> String {
        NSHomeDirectory() + "/.qwen"
    }

    static func defaultCopilotHome() -> String {
        NSHomeDirectory() + "/.copilot"
    }

    static func defaultGrokHome() -> String {
        NSHomeDirectory() + "/.grok"
    }

    static func defaultAiderHome() -> String {
        NSHomeDirectory() + "/.aider"
    }

    static func defaultAiderAnalyticsPath() -> String {
        defaultAiderHome() + "/analytics.jsonl"
    }

    static func defaultAntigravityHome() -> String {
        NSHomeDirectory() + "/.gemini/antigravity-cli"
    }

    static func defaultClineHome() -> String {
        AppPaths.appSupport("Code", "User", "globalStorage", "saoudrizwan.claude-dev")
    }

    static func defaultContinueHome() -> String {
        NSHomeDirectory() + "/.continue"
    }

    static func defaultCursorAgentHome() -> String {
        // Cursor IDE stores the credential used by Cursor Agent's cloud usage endpoint here.
        AppPaths.appSupport("Cursor", "User", "globalStorage")
    }

    // MARK: - 备选探测路径（官方文档中的其他常见位置）

    /// OpenClaw 的所有可能数据目录候选
    static func openclawCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envOpenClaw) { candidates.append(env) }
        candidates.append(defaultOpenclawHome())
        // OpenClaw 也可能通过 LaunchAgent 安装，检查日志目录
        candidates.append(NSHomeDirectory() + "/Library/Logs/OpenClaw")
        return candidates
    }

    /// Claude Code 的所有可能数据目录候选
    static func claudeCodeCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envClaudeCode) { candidates.append(env) }
        candidates.append(defaultClaudeCodeHome())
        // Claude Desktop 日志位置（部分 session 数据可能在此）
        candidates.append(AppPaths.appSupport("Claude"))
        return candidates
    }

    /// Gemini CLI 的所有可能数据目录候选
    static func geminiCandidates() -> [String] {
        var candidates: [String] = []
        if let env = geminiEnvironmentHome() { candidates.append(env) }
        candidates.append(defaultGeminiHome())
        return candidates
    }

    /// Codex 的所有可能数据目录候选
    static func codexCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envCodex) { candidates.append(env) }
        candidates.append(defaultCodexHome())
        // Codex 也可能在 .config 下（XDG 规范）
        candidates.append(NSHomeDirectory() + "/.config/codex")
        return candidates
    }

    /// Hermes 的所有可能数据目录候选
    static func hermesCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envHermes) { candidates.append(env) }
        candidates.append(defaultHermesHome())
        return candidates
    }

    static func opencodeCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envOpenCode) { candidates.append(env) }
        candidates.append(defaultOpenCodeHome())
        candidates.append(NSHomeDirectory() + "/.opencode")
        return candidates
    }

    static func qwenCandidates() -> [String] {
        var candidates: [String] = []
        if let env = envPath(envQwenRuntime) { candidates.append(env) }
        if let env = envPath(envQwen) { candidates.append(env) }
        candidates.append(defaultQwenHome())
        return candidates
    }

    static func copilotCandidates() -> [String] {
        var candidates: [String] = []
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
        if let env = envPath(envAiderAnalyticsLog) { candidates.append(analyticsFile(from: env)) }
        candidates.append(defaultAiderAnalyticsPath())
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
        candidates.append(AppPaths.appSupport("Cursor", "User", "globalStorage", "saoudrizwan.claude-dev"))
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

    static var hasRunInitialDetection: Bool {
        get { UserDefaults.standard.bool(for: .hasRunInitialDetection) }
        set { UserDefaults.standard.setBool(newValue, for: .hasRunInitialDetection) }
    }

    // MARK: - 内部

    private static func customPath(forKey key: String) -> String? {
        guard let settingsKey = SettingsKey(rawValue: prefix + key) else { return nil }
        let val = UserDefaults.standard.string(for: settingsKey)
        guard let val, !val.isEmpty else { return nil }
        return expandedPath(val)
    }

    private static func setCustomPath(_ path: String, forKey key: String) {
        guard let settingsKey = SettingsKey(rawValue: prefix + key) else { return }
        if path.isEmpty {
            UserDefaults.standard.remove(settingsKey)
        } else {
            UserDefaults.standard.setString(path, for: settingsKey)
        }
    }

    private static func envPath(_ name: String) -> String? {
        let val = ProcessInfo.processInfo.environment[name]
        guard let val, !val.isEmpty else { return nil }
        return expandedPath(val)
    }

    /// Expand the path forms users naturally paste into Settings. Foundation's tilde expansion
    /// is not consistent across Windows Foundation builds, so handle it explicitly as well as
    /// `%APPDATA%`, `$env:APPDATA`, `${APPDATA}` and `$APPDATA` forms.
    static func expandedPath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = ProcessInfo.processInfo.environment

        if value == "~" || value.hasPrefix("~/") || value.hasPrefix("~\\") {
            value = NSHomeDirectory() + String(value.dropFirst())
        }

        for (name, replacement) in environment where !name.isEmpty {
            value = value.replacingOccurrences(of: "%\(name)%", with: replacement, options: .caseInsensitive)
            value = value.replacingOccurrences(of: "$env:\(name)", with: replacement, options: .caseInsensitive)
            value = value.replacingOccurrences(of: "${\(name)}", with: replacement)
            value = value.replacingOccurrences(of: "$\(name)", with: replacement)
        }
        return (value as NSString).standardizingPath
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
}
