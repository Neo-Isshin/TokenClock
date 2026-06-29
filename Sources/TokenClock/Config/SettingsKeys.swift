import Foundation

/// 所有 UserDefaults key 的集中定义
///
/// 用 enum（无 case）+ rawValue 字符串，避免散落各处的 "TC_xxx" 字面量。
/// 改 key 名时有编译期检查，typo 立即报错。
///
/// 用法：
/// ```swift
/// UserDefaults.standard.set(true, forKey: SettingsKey.alwaysOnTop.rawValue)
/// // 或用扩展：
/// UserDefaults.standard.setBool(true, for: .alwaysOnTop)
/// ```
enum SettingsKey: String {
    // MARK: - 通用
    case enabledTools = "TC_enabledTools"
    case alwaysOnTop = "TC_alwaysOnTop"
    case launchAtLogin = "TC_launchAtLogin"
    case language = "TC_language"

    // MARK: - 本地 API 服务
    case apiServerEnabled = "TC_apiServerEnabled"
    case apiServerPort    = "TC_apiServerPort"

    // MARK: - 主题
    case selectedTheme = "TC_selectedTheme"
    case activeCustomThemeId = "TC_activeCustomThemeId"
    case savedCustomThemes = "TC_savedCustomThemes"
    case customThemeConfig = "TC_customThemeConfig"

    // MARK: - 速率/活跃度阈值
    case rateWindow = "TC_rateWindow"
    case rateBurst = "TC_rateBurst"
    case rateHot = "TC_rateHot"
    case rateActive = "TC_rateActive"
    case rateCalm = "TC_rateCalm"

    // MARK: - 工具路径（每工具一个）
    case openclawPath = "TC_openclawPath"
    case claudeCodePath = "TC_claudeCodePath"
    case geminiPath = "TC_geminiPath"
    case codexPath = "TC_codexPath"
    case hermesPath = "TC_hermesPath"
    case opencodePath = "TC_opencodePath"
    case qwenPath = "TC_qwenPath"
    case copilotPath = "TC_copilotPath"
    case grokPath = "TC_grokPath"
    case aiderPath = "TC_aiderPath"
    case antigravityPath = "TC_antigravityPath"
    case clinePath = "TC_clinePath"
    case continuePath = "TC_continuePath"
    case cursorAgentPath = "TC_cursorAgentPath"

    // MARK: - 窗口位置（历史命名，无 TC_ 前缀，保持兼容）
    case windowPosition = "TokenClockWindowPosition"

    // MARK: - 首次启动标记
    case hasRunInitialDetection = "TC_hasRunInitialDetection"

    // MARK: - 日结历史
    case historyLastSettledDateKey = "TC_historyLastSettledDateKey"
}

extension UserDefaults {
    /// 类型安全的 bool 读写
    func setBool(_ value: Bool, for key: SettingsKey) {
        set(value, forKey: key.rawValue)
    }
    func bool(for key: SettingsKey, `default` fallback: Bool = false) -> Bool {
        if object(forKey: key.rawValue) == nil { return fallback }
        return bool(forKey: key.rawValue)
    }

    /// 类型安全的 int 读写
    func setInt(_ value: Int, for key: SettingsKey) {
        set(value, forKey: key.rawValue)
    }
    func int(for key: SettingsKey, `default` fallback: Int = 0) -> Int {
        if object(forKey: key.rawValue) == nil { return fallback }
        return integer(forKey: key.rawValue)
    }

    /// 类型安全的 string 读写
    func setString(_ value: String?, for key: SettingsKey) {
        set(value, forKey: key.rawValue)
    }
    func string(for key: SettingsKey) -> String? {
        string(forKey: key.rawValue)
    }

    /// 类型安全的 stringArray 读写
    func setStringArray(_ value: [String], for key: SettingsKey) {
        set(value, forKey: key.rawValue)
    }
    func stringArray(for key: SettingsKey) -> [String]? {
        stringArray(forKey: key.rawValue)
    }

    /// 移除 key
    func remove(_ key: SettingsKey) {
        removeObject(forKey: key.rawValue)
    }
}
