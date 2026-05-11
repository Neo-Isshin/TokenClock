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
        candidates.append(NSHomeDirectory() + "/Library/Application Support/Claude")
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

    // MARK: - 写入路径

    static func setOpenclawPath(_ path: String) { setCustomPath(path, forKey: "openclawPath") }
    static func setClaudeCodePath(_ path: String) { setCustomPath(path, forKey: "claudeCodePath") }
    static func setGeminiPath(_ path: String) { setCustomPath(path, forKey: "geminiPath") }
    static func setCodexPath(_ path: String) { setCustomPath(path, forKey: "codexPath") }
    static func setHermesPath(_ path: String) { setCustomPath(path, forKey: "hermesPath") }

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
