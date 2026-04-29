import Foundation

/// 路径配置：支持用户自定义各数据源的日志目录
/// 留空则使用默认路径
enum PathConfig {
    // MARK: - UserDefaults Keys

    private static let prefix = "TC_"

    // MARK: - 读取路径

    static func openclawHome() -> String {
        customPath(forKey: "openclawPath") ?? defaultOpenclawHome()
    }

    static func claudeCodeHome() -> String {
        customPath(forKey: "claudeCodePath") ?? defaultClaudeCodeHome()
    }

    static func geminiHome() -> String {
        customPath(forKey: "geminiPath") ?? defaultGeminiHome()
    }

    static func codexHome() -> String {
        customPath(forKey: "codexPath") ?? defaultCodexHome()
    }

    static func hermesHome() -> String {
        customPath(forKey: "hermesPath") ?? defaultHermesHome()
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

    // MARK: - 写入路径

    static func setOpenclawPath(_ path: String) {
        setCustomPath(path, forKey: "openclawPath")
    }

    static func setClaudeCodePath(_ path: String) {
        setCustomPath(path, forKey: "claudeCodePath")
    }

    static func setGeminiPath(_ path: String) {
        setCustomPath(path, forKey: "geminiPath")
    }

    static func setCodexPath(_ path: String) {
        setCustomPath(path, forKey: "codexPath")
    }

    static func setHermesPath(_ path: String) {
        setCustomPath(path, forKey: "hermesPath")
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
}
