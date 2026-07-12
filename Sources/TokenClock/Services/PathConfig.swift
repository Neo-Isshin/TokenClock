import Foundation

/// 路径配置：支持用户自定义、环境变量、自动探测各数据源的日志目录
/// 优先级：UserDefaults 自定义 > 环境变量 > 官方默认路径
enum PathConfig {
    private static let prefix = "TC_"

    // MARK: - 环境变量名

    private static let envOpenClaw = "OPENCLAW_HOME"
    private static let envClaudeCode = "CLAUDE_CONFIG_DIR"
    private static let envGemini = "GEMINI_HOME"
    private static let envCodex = "CODEX_HOME"
    private static let envHermes = "HERMES_HOME"
    private static let envOpenCode = "OPENCODE_HOME"
    private static let envQwen = "QWEN_HOME"
    private static let envCopilot = "COPILOT_HOME"
    private static let envGrok = "GROK_HOME"
    private static let envAider = "AIDER_HOME"
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
        customPath(forKey: "geminiPath") ?? envPath(envGemini) ?? defaultGeminiHome()
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
        customPath(forKey: "qwenPath") ?? envPath(envQwen) ?? defaultQwenHome()
    }

    static func copilotHome() -> String {
        customPath(forKey: "copilotPath") ?? envPath(envCopilot) ?? defaultCopilotHome()
    }

    static func grokHome() -> String {
        customPath(forKey: "grokPath") ?? envPath(envGrok) ?? defaultGrokHome()
    }

    static func aiderHome() -> String {
        customPath(forKey: "aiderPath") ?? envPath(envAider) ?? defaultAiderHome()
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
        NSHomeDirectory() + "/.cursor"
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
        if let env = envPath(envGemini) { candidates.append(env) }
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
        if let env = envPath(envAider) { candidates.append(env) }
        candidates.append(defaultAiderHome())
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
    /// 设置了自定义路径或 `ANTIGRAVITY_HOME` 时，仅扫描该覆盖目录（向后兼容旧行为）。
    static func antigravityConversationDirs() -> [String] {
        if let override = customPath(forKey: "antigravityPath") ?? envPath(envAntigravity) {
            return [override + "/conversations"]
        }
        let gemini = NSHomeDirectory() + "/.gemini"
        return ["antigravity-cli", "antigravity-ide", "antigravity"].map {
            gemini + "/" + $0 + "/conversations"
        }
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
        get { UserDefaults.standard.bool(forKey: prefix + "hasRunInitialDetection") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "hasRunInitialDetection") }
    }

    // MARK: - 内部

    private static func customPath(forKey key: String) -> String? {
        let val = UserDefaults.standard.string(forKey: prefix + key)
        guard let val, !val.isEmpty else { return nil }
        return val
    }

    private static func setCustomPath(_ path: String, forKey key: String) {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        } else {
            UserDefaults.standard.set(path, forKey: prefix + key)
        }
    }

    private static func envPath(_ name: String) -> String? {
        let val = ProcessInfo.processInfo.environment[name]
        guard let val, !val.isEmpty else { return nil }
        return val
    }
}
