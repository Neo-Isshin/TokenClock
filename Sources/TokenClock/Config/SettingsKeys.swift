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

    // MARK: - 表盘大小
    case clockSize = "TC_clockSize"
    /// 用户是否手动选择过表盘大小（置 true 后不再自动按分辨率调整）
    case clockSizeUserChosen = "TC_clockSizeUserChosen"

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
    case kiroSessionsPath = "TC_kiroSessionsPath"
    case codeBuddyEndpoint = "TC_codeBuddyEndpoint"

    // MARK: - 窗口位置（历史命名，无 TC_ 前缀，保持兼容）
    case windowPosition = "TokenClockWindowPosition"
    case windowsWindowX = "TCWinWindowX"
    case windowsWindowY = "TCWinWindowY"

    // MARK: - 启动持久化设置（窗口透明度 / 城市 / 时区 / 华氏度）
    case windowOpacity = "TC_windowOpacity"
    case selectedCity = "TC_selectedCity"
    case selectedTimezone = "TC_selectedTimezone"
    case useFahrenheit = "TC_useFahrenheit"
    /// 0=跟随主题 1=白 2=黑 3=自定义
    case dialTextMode = "TC_dialTextMode"
    case dialTextColor = "TC_dialTextColor"
    /// 下拉详情面板主文字色 #RRGGBB（空=跟随主题）
    case dropdownTextColor = "TC_dropdownTextColor"
    /// Linux/Windows 详情面板快捷对比色预设；不覆盖用户自定义颜色。
    case quickContrastPreset = "TC_quickContrastPreset"
    /// Cursor 用量是否从云端获取（关闭则不向 cursor.com 发凭证请求）
    case cursorCloudFetchEnabled = "TC_cursorCloudFetchEnabled"

    // MARK: - 下拉面板
    /// 分组模式：0=按会话 1=按模型
    case dropdownGrouping = "TC_dropdownGrouping"
    /// 数值列显示模式：0=用量 1=占比 2=费用（DetailValueMode）
    case dropdownValueMode = "TC_dropdownValueMode"
    /// 用量口径：token 展示是否包含缓存读（默认 false=排除，与 Codex 官方一致）
    case usageIncludesCacheRead = "TC_usageIncludesCacheRead"
    /// 旧版开关：用量列是否以「占总数百分比」显示（迁移到 dropdownValueMode 后弃用，仅读取）
    case dropdownShowPercentage = "TC_dropdownShowPercentage"

    // MARK: - 首次启动标记
    case hasRunInitialDetection = "TC_hasRunInitialDetection"

    // MARK: - 日结历史
    case historyLastSettledDateKey = "TC_historyLastSettledDateKey"

    // MARK: - 费用估算
    /// 最近一次价格目录成功刷新的 Unix 时间戳
    case pricingLastRefresh = "TC_pricingLastRefresh"
    /// 自定义模型价格表（JSON：模型名 → {in,out,cr,cw}，USD/MTok）
    case customModelPrices = "TC_customModelPrices"
}

extension UserDefaults {
    /// 类型安全的 bool 读写
    func setBool(_ value: Bool, for key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.set(value, forKey: key.rawValue)
        #else
        set(value, forKey: key.rawValue)
        #endif
    }
    func bool(for key: SettingsKey, `default` fallback: Bool = false) -> Bool {
        #if os(Windows)
        if WindowsPreferences.shared.object(forKey: key.rawValue) == nil { return fallback }
        return WindowsPreferences.shared.bool(forKey: key.rawValue)
        #else
        if object(forKey: key.rawValue) == nil { return fallback }
        return bool(forKey: key.rawValue)
        #endif
    }

    /// 类型安全的 int 读写
    func setInt(_ value: Int, for key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.set(value, forKey: key.rawValue)
        #else
        set(value, forKey: key.rawValue)
        #endif
    }
    func int(for key: SettingsKey, `default` fallback: Int = 0) -> Int {
        #if os(Windows)
        if WindowsPreferences.shared.object(forKey: key.rawValue) == nil { return fallback }
        return WindowsPreferences.shared.integer(forKey: key.rawValue)
        #else
        if object(forKey: key.rawValue) == nil { return fallback }
        return integer(forKey: key.rawValue)
        #endif
    }

    /// 类型安全的 string 读写
    func setString(_ value: String?, for key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.set(value, forKey: key.rawValue)
        #else
        set(value, forKey: key.rawValue)
        #endif
    }
    func string(for key: SettingsKey) -> String? {
        #if os(Windows)
        return WindowsPreferences.shared.string(forKey: key.rawValue)
        #else
        string(forKey: key.rawValue)
        #endif
    }

    /// 类型安全的 stringArray 读写
    func setStringArray(_ value: [String], for key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.set(value, forKey: key.rawValue)
        #else
        set(value, forKey: key.rawValue)
        #endif
    }
    func stringArray(for key: SettingsKey) -> [String]? {
        #if os(Windows)
        return WindowsPreferences.shared.stringArray(forKey: key.rawValue)
        #else
        stringArray(forKey: key.rawValue)
        #endif
    }

    /// 类型安全的 double 读写（object==nil 区分「未存」与「存了 0」）
    func setDouble(_ value: Double, for key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.set(value, forKey: key.rawValue)
        #else
        set(value, forKey: key.rawValue)
        #endif
    }
    func double(for key: SettingsKey, `default` fallback: Double = 0) -> Double {
        #if os(Windows)
        if WindowsPreferences.shared.object(forKey: key.rawValue) == nil { return fallback }
        return WindowsPreferences.shared.double(forKey: key.rawValue)
        #else
        if object(forKey: key.rawValue) == nil { return fallback }
        return double(forKey: key.rawValue)
        #endif
    }

    /// 移除 key
    func remove(_ key: SettingsKey) {
        #if os(Windows)
        WindowsPreferences.shared.removeObject(forKey: key.rawValue)
        #else
        removeObject(forKey: key.rawValue)
        #endif
    }
}
