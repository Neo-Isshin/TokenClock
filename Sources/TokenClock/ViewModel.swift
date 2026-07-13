import SwiftUI
import Combine
import AppKit

/// 表盘文字颜色覆盖模式（「表盘外观 ▸ 文字颜色」）
enum DialTextMode: Int {
    case theme = 0    // 跟随主题
    case white = 1
    case black = 2
    case custom = 3   // dialTextColorHex
}

/// 下拉面板的分组模式：按会话（工具 → session）或按模型（跨工具归并）
enum GroupingMode: Int {
    case session = 0
    case model = 1
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var tools: [ToolUsage] {
        didSet { updateSortedTools() }
    }

    /// 预计算排序后的工具列表，避免每次展开时重新排序
    @Published private(set) var sortedTools: [ToolUsage] = []

    /// 用户启用的工具名集合（默认全选）
    @Published var enabledTools: Set<String>

    /// 只包含已启用工具的排序列表
    var visibleTools: [ToolUsage] {
        sortedTools.filter { enabledTools.contains($0.name) }
    }

    @Published var currentTime = Date()
    @Published var language: AppLanguage = L10n.shared.language
    @Published var isExpanded = false {
        didSet {
            // 直接触发面板大小调整，跳过 NotificationCenter 绕路
            onExpandChanged?(isExpanded)
        }
    }

    /// 展开状态变化时的回调（由 AppDelegate 设置）
    var onExpandChanged: ((Bool) -> Void)?

    /// 下拉面板分组模式（按会话 / 按模型），持久化
    @Published var groupingMode: GroupingMode = {
        GroupingMode(rawValue: UserDefaults.standard.int(for: .dropdownGrouping, default: 0)) ?? .session
    }() {
        didSet { UserDefaults.standard.setInt(groupingMode.rawValue, for: .dropdownGrouping) }
    }

    @Published var windowOpacity: Double = 1.0 { didSet { UserDefaults.standard.set(windowOpacity, forKey: SettingsKey.windowOpacity.rawValue) } }
    @Published var alwaysOnTop: Bool = {
        UserDefaults.standard.bool(for: .alwaysOnTop, default: true)
    }()
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(for: .launchAtLogin, default: false) {
        didSet { UserDefaults.standard.setBool(launchAtLogin, for: .launchAtLogin) }
    }

    /// 表盘主题
    @Published var selectedTheme: ClockFaceTheme = .classic

    /// 表盘大小（4 档）。首启按主屏分辨率自动选；手动改过后不再自动调整。
    @Published var clockSize: ClockSize = .medium

    /// 表盘大小变化回调（AppDelegate 据此重设浮动面板尺寸 + 重定位下拉详情面板）。
    var onClockSizeChanged: (() -> Void)?

    /// 天气数据
    @Published var weather = WeatherInfo()
    @Published var useFahrenheit = false { didSet { UserDefaults.standard.setBool(useFahrenheit, for: .useFahrenheit) } }
    /// Cursor 用量是否从云端获取（默认开；关闭则不向 cursor.com 发凭证请求）
    @Published var cursorCloudFetchEnabled: Bool = true { didSet { UserDefaults.standard.setBool(cursorCloudFetchEnabled, for: .cursorCloudFetchEnabled) } }
    @Published var selectedCity: String = "auto" { didSet { UserDefaults.standard.setString(selectedCity, for: .selectedCity) } }
    /// IP 定位解析到的城市名（用于菜单动态标签）
    @Published var resolvedCityName: String = ""

    // MARK: - 表盘外观（液态玻璃：文字颜色 / 材质档位 / 玻璃底色）
    /// 表盘文字颜色模式。变更触发 SwiftUI 重渲染：数字经 numberColorOverride 重绘，
    /// 叠加层文字经 effectiveDialPrimary/Secondary 重绘。
    @Published var dialTextMode: DialTextMode = .theme {
        didSet { UserDefaults.standard.setInt(dialTextMode.rawValue, for: .dialTextMode) }
    }
    /// 自定义文字颜色 #RRGGBB（仅 dialTextMode == .custom 时使用）。
    @Published var dialTextColorHex: String = "#FFFFFF" {
        didSet { UserDefaults.standard.setString(dialTextColorHex, for: .dialTextColor) }
    }
    /// 私有 NSGlassEffectView 材质配方（set_variant:）。2=标准(dock) 13=清透(clearGlass) 8=磨砂(controlCenter)。
    /// 经 .id(glassMaterialVariant) 触发 LiquidGlassDial 重建 —— variant 会重建内部子层，重建比 in-place 改更可靠。
    @Published var glassMaterialVariant: Int = 2 {
        didSet { UserDefaults.standard.setInt(glassMaterialVariant, for: .glassVariant) }
    }
    /// 私有玻璃底色 #RRGGBB（nil = 纯净玻璃，随壁纸自适应）。变更触发 updateNSView 重设 tintColor。
    @Published var glassTintHex: String? = nil {
        didSet { UserDefaults.standard.setString(glassTintHex, for: .glassTint) }
    }

    /// 液态玻璃折射总开关（默认开；关 → 回退公开 .clear 玻璃）。表盘立即切换；
    /// 但 FloatingPanel 的 _hasActiveAppearance 覆写在启动时据 TC_GLASS_DISABLE 决定，彻底关闭需重启。
    @Published var glassRefractionEnabled: Bool = true {
        didSet { UserDefaults.standard.set(!glassRefractionEnabled, forKey: "TC_GLASS_DISABLE") }
    }

    /// 折射玻璃下层毛玻璃底板透明度 0…1（0=无底板，纯玻璃）。公开 NSVisualEffectView.alphaValue。
    @Published var glassBackingAlpha: Double = 0 {
        didSet { UserDefaults.standard.set(glassBackingAlpha, forKey: SettingsKey.glassBackingAlpha.rawValue) }
    }

    /// 表盘文字主色（受 dialTextMode 覆盖；custom 解析失败回退主题色）。
    var effectiveDialPrimary: Color {
        switch dialTextMode {
        case .theme:  return selectedTheme.textPrimaryColor
        case .white:  return .white
        case .black:  return .black
        case .custom: return CodableColor(hex: dialTextColorHex)?.swiftUIColor ?? selectedTheme.textPrimaryColor
        }
    }
    /// 表盘文字副色（custom/white/black = 主色 72% 透明，保留主副层级关系）。
    var effectiveDialSecondary: Color {
        switch dialTextMode {
        case .theme:  return selectedTheme.textSecondaryColor
        case .white, .black, .custom: return effectiveDialPrimary.opacity(0.72)
        }
    }
    /// 表盘数字颜色覆盖（theme = nil 跟随主题；注入 ClockFaceView.numberColorOverride）。
    var effectiveDialNumberColor: Color? {
        switch dialTextMode {
        case .theme:  return nil
        case .white:  return .white
        case .black:  return .black
        case .custom: return CodableColor(hex: dialTextColorHex)?.swiftUIColor
        }
    }

    /// 可选城市列表（auto = 自动定位）
    static let cityOptions = ["auto", "Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York"]
    static let cityLabels: [String: String] = [
        "auto": "自动(城市名)", "Hong Kong": "Hong Kong",
        "Shanghai": "Shanghai", "Beijing": "Beijing",
        "Tokyo": "Tokyo", "Singapore": "Singapore",
        "New York": "New York",
    ]

    /// 时区设置
    @Published var selectedTimezone: String = "auto" { didSet { UserDefaults.standard.setString(selectedTimezone, for: .selectedTimezone) } }

    /// 热力统计周期（分钟）
    @Published var rateWindowMinutes: Int = 10

    /// 已保存的自定义主题列表
    @Published var savedCustomThemes: [SavedCustomTheme] = []
    /// 当前激活的自定义主题 ID（nil 表示使用默认未命名配置）
    @Published var activeCustomThemeId: UUID? = nil

    /// 首次真实数据扫描完成前的加载状态：true 期间不展示（基于 mock 占位生成的）数字，
    /// 避免启动瞬间显示假用量造成误导。首次 runBackgroundScan 完成后置 false。
    @Published var isInitialLoading = true

    /// 可用时区列表（label 为 L10n key，运行时通过 tr() 解析）
    static let timezoneOptions: [(label: String, identifier: String)] = [
        ("tz.auto", "auto"),
        ("tz.hongKong", "Asia/Hong_Kong"),
        ("tz.shanghai", "Asia/Shanghai"),
        ("tz.tokyo", "Asia/Tokyo"),
        ("tz.singapore", "Asia/Singapore"),
        ("tz.newYork", "America/New_York"),
        ("tz.london", "Europe/London"),
        ("tz.losAngeles", "America/Los_Angeles"),
    ]

    private var clockTimer: Timer?
    private var dataTimer: Timer?
    private var recentResetTimer: Timer?
    private var weatherTimer: Timer?
    private var historyTimer: Timer?

    /// 后台扫描重入守卫：防止 dataTimer/全量扫描并发触发同一时刻多扫描
    private var isScanning = false

    // 真实数据服务
    private let openclawService = OpenClawUsageService()
    private let claudeCodeService = ClaudeCodeUsageService()
    private let geminiService = GeminiUsageService()
    private let codexService = CodexUsageService()
    private let hermesService = HermesUsageService()
    private let opencodeService = OpenCodeUsageService()
    private let qwenService = QwenCodeUsageService()
    private let copilotService = CopilotUsageService()
    private let grokService = GrokUsageService()
    private let aiderService = AiderUsageService()
    private let antigravityService = AntigravityUsageService()
    private let clineService = ClineUsageService()
    private let continueService = ContinueUsageService()
    private let cursorAgentService = CursorAgentUsageService()

    private static let allToolNames = ["OpenClaw", "Claude Code", "Gemini CLI", "Codex", "Hermes", "OpenCode", "Qwen Code", "Copilot", "Grok", "Aider", "Antigravity", "Cline", "Continue", "Cursor Agent"]

    init() {
        // 加载启用的工具集合
        let saved = UserDefaults.standard.stringArray(for: .enabledTools)
        let enabledTools = Set(saved ?? Self.allToolNames)
        self.enabledTools = enabledTools

        // 为启用的工具生成占位 mock 数据，禁用的工具留 0（避免误导）
        self.tools = MockUsageService.generateInitialData(enabledTools: enabledTools)
        updateSortedTools()

        // 加载持久化用户设置（透明度 / 城市 / 时区 / 华氏度）—— 启动前注入，避免每次重启归零
        if UserDefaults.standard.object(forKey: SettingsKey.useFahrenheit.rawValue) != nil { useFahrenheit = UserDefaults.standard.bool(for: .useFahrenheit) }
        if let s = UserDefaults.standard.string(for: .selectedCity) { selectedCity = s }
        if let s = UserDefaults.standard.string(for: .selectedTimezone) { selectedTimezone = s }
        if UserDefaults.standard.object(forKey: SettingsKey.windowOpacity.rawValue) != nil { windowOpacity = UserDefaults.standard.double(forKey: SettingsKey.windowOpacity.rawValue) }
        if UserDefaults.standard.object(forKey: SettingsKey.cursorCloudFetchEnabled.rawValue) != nil { cursorCloudFetchEnabled = UserDefaults.standard.bool(for: .cursorCloudFetchEnabled) }

        // 表盘外观（液态玻璃文字/材质/底色）
        if let raw = UserDefaults.standard.object(forKey: SettingsKey.dialTextMode.rawValue) as? Int,
           let mode = DialTextMode(rawValue: raw) { dialTextMode = mode }
        if let hex = UserDefaults.standard.string(for: .dialTextColor) { dialTextColorHex = hex }
        if UserDefaults.standard.object(forKey: SettingsKey.glassVariant.rawValue) != nil {
            glassMaterialVariant = UserDefaults.standard.int(for: .glassVariant, default: 2)
        }
        if UserDefaults.standard.object(forKey: SettingsKey.glassBackingAlpha.rawValue) != nil {
            glassBackingAlpha = UserDefaults.standard.double(forKey: SettingsKey.glassBackingAlpha.rawValue)
        }
        if let tintHex = UserDefaults.standard.string(for: .glassTint), CodableColor(hex: tintHex) != nil {
            glassTintHex = tintHex
        }
        glassRefractionEnabled = !UserDefaults.standard.bool(forKey: "TC_GLASS_DISABLE")

        loadTheme()
        // 表盘大小：首启按主屏分辨率自动选档（用户手动改过后跳过），再加载到 @Published
        runInitialClockSizeDetection()
        loadClockSize()
        loadRateWindow()
        loadSavedCustomThemes()
        // 首次启动时自动探测各工具日志路径
        runInitialPathDetection()
        startTimers()
        // 日结历史:启动时检查上次结算日(漏了不补打,SQLite 有啥返回啥)
        performStartupHistoryCatchup()
        scheduleNextDailySettlement()
        fetchInitialWeather()
        // 首次全量扫描
        performFullScan()
    }

    func shutdown() {
        stopTimers()
    }

    // MARK: - 首次启动路径探测

    /// 应用首次启动时自动探测各工具日志路径
    private func runInitialPathDetection() {
        guard !PathConfig.hasRunInitialDetection else { return }
        PathConfig.hasRunInitialDetection = true

        let summary = PathDetector.runFullDetection()
        var savedPaths: [String] = []

        for result in summary.results where result.exists {
            switch result.service {
            case "openclaw":
                PathConfig.setOpenclawPath(result.detectedPath)
                savedPaths.append("⚡ OpenClaw: \(result.detail)")
            case "claudeCode":
                PathConfig.setClaudeCodePath(result.detectedPath)
                savedPaths.append("🧠 Claude Code: \(result.detail)")
            case "gemini":
                PathConfig.setGeminiPath(result.detectedPath)
                savedPaths.append("💎 Gemini CLI: \(result.detail)")
            case "codex":
                PathConfig.setCodexPath(result.detectedPath)
                savedPaths.append("🤖 Codex: \(result.detail)")
            case "hermes":
                PathConfig.setHermesPath(result.detectedPath)
                savedPaths.append("🏔️ Hermes: \(result.detail)")
            case "opencode":
                PathConfig.setOpenCodePath(result.detectedPath)
                savedPaths.append("🐙 OpenCode: \(result.detail)")
            case "qwen":
                PathConfig.setQwenPath(result.detectedPath)
                savedPaths.append("🟣 Qwen Code: \(result.detail)")
            case "copilot":
                PathConfig.setCopilotPath(result.detectedPath)
                savedPaths.append("🐙 Copilot: \(result.detail)")
            case "grok":
                PathConfig.setGrokPath(result.detectedPath)
                savedPaths.append("⚡ Grok: \(result.detail)")
            case "aider":
                PathConfig.setAiderPath(result.detectedPath)
                savedPaths.append("🤝 Aider: \(result.detail)")
            case "antigravity":
                PathConfig.setAntigravityPath(result.detectedPath)
                savedPaths.append("🛡️ Antigravity: \(result.detail)")
            case "cline":
                PathConfig.setClinePath(result.detectedPath)
                savedPaths.append("🤖 Cline: \(result.detail)")
            case "continue":
                PathConfig.setContinuePath(result.detectedPath)
                savedPaths.append("▶️ Continue: \(result.detail)")
            case "cursorAgent":
                PathConfig.setCursorAgentPath(result.detectedPath)
                savedPaths.append("🖱️ Cursor Agent: \(result.detail)")
            default:
                break
            }
        }

        // 如果探测到至少一个路径，打印摘要到控制台
        if !savedPaths.isEmpty {
            print("[TokenClock] 自动探测到 \(savedPaths.count) 个数据源路径:")
            for path in savedPaths {
                print("  - \(path)")
            }
        }

        // 如果有未探测到的，也记录下来
        let notFound = summary.results.filter { !$0.exists }
        if !notFound.isEmpty {
            print("[TokenClock] 未探测到的数据源（可在设置中手动配置）:")
            for result in notFound {
                print("  - \(result.emoji) \(result.service): \(result.detail)")
            }
        }
    }

    // MARK: - 预排序

    private func updateSortedTools() {
        sortedTools = tools.sorted { $0.todayTokens > $1.todayTokens }
    }

    // MARK: - 工具启用/禁用

    func toggleTool(_ name: String) {
        if enabledTools.contains(name) {
            enabledTools.remove(name)
        } else {
            enabledTools.insert(name)
        }
        UserDefaults.standard.setStringArray(Array(enabledTools), for: .enabledTools)
    }

    // MARK: - 主题持久化

    func saveTheme() {
        UserDefaults.standard.setString(selectedTheme.rawValue, for: .selectedTheme)
    }

    private func loadTheme() {
        if let saved = UserDefaults.standard.string(for: .selectedTheme),
           let theme = ClockFaceTheme(rawValue: saved) {
            selectedTheme = theme
        }
    }

    // MARK: - 表盘大小持久化

    /// 首启（或用户未手动选择时）按当前主屏可用高度自动选档并写入 UserDefaults。
    /// 未手动选择则每次启动都重评一次，从而支持接/拔外接屏后下一启自适应。
    private func runInitialClockSizeDetection() {
        guard !UserDefaults.standard.bool(for: .clockSizeUserChosen) else { return }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let detected = ClockSize.autoDetect(screenHeight: screenHeight)
        UserDefaults.standard.setString(detected.rawValue, for: .clockSize)
    }

    private func loadClockSize() {
        if let saved = UserDefaults.standard.string(for: .clockSize),
           let size = ClockSize(rawValue: saved) {
            clockSize = size
        }
    }

    /// 用户在设置中手动选择表盘大小。写入后置 userChosen，停止后续自动调整。
    func setClockSize(_ size: ClockSize) {
        clockSize = size
        UserDefaults.standard.setString(size.rawValue, for: .clockSize)
        UserDefaults.standard.setBool(true, for: .clockSizeUserChosen)
        onClockSizeChanged?()
    }


    private func loadRateWindow() {
        let saved = UserDefaults.standard.int(for: .rateWindow)
        rateWindowMinutes = saved > 0 ? saved : 10
    }

    // MARK: - 自定义主题管理

    private func loadSavedCustomThemes() {
        savedCustomThemes = SavedCustomTheme.loadAll()
        if let savedIdString = UserDefaults.standard.string(for: .activeCustomThemeId),
           let savedId = UUID(uuidString: savedIdString) {
            activeCustomThemeId = savedId
        }
    }

    func saveNewCustomTheme(name: String, config: CustomThemeConfig) {
        let newTheme = SavedCustomTheme(name: name, config: config)
        savedCustomThemes.append(newTheme)
        SavedCustomTheme.saveAll(savedCustomThemes)
    }

    func deleteCustomTheme(id: UUID) {
        savedCustomThemes.removeAll { $0.id == id }
        SavedCustomTheme.saveAll(savedCustomThemes)
        if activeCustomThemeId == id {
            activeCustomThemeId = nil
            UserDefaults.standard.remove(.activeCustomThemeId)
        }
    }

    func applyCustomTheme(id: UUID) {
        guard let theme = savedCustomThemes.first(where: { $0.id == id }) else { return }
        activeCustomThemeId = id
        UserDefaults.standard.setString(id.uuidString, for: .activeCustomThemeId)
        // 将配置同步到 CustomThemeConfig 的默认存储，供 ClockFaceTheme.custom 读取
        theme.config.save()
    }

    // MARK: - 聚合属性

    var totalTokensFormatted: String {
        if isInitialLoading { return "—" }
        return TokenFormat.compact(UsageAggregator.totalTokens(visibleTools))
    }

    var totalMessagesFormatted: String {
        if isInitialLoading { return "—" }
        let total = UsageAggregator.totalMessages(visibleTools)
        return L10n.shared.tr("clock.messagesCount", total)
    }

    var totalMessagesCount: Int {
        UsageAggregator.totalMessages(visibleTools)
    }

    var activeToolsList: [ToolUsage] {
        isInitialLoading ? [] : UsageAggregator.topToolsByTokens(visibleTools, limit: 2)
    }

    var rateEmoji: String {
        isInitialLoading ? "" : UsageAggregator.rateEmoji(visibleTools)
    }

    // MARK: - 时间属性

    /// 当前使用的时区
    private var effectiveTimezone: TimeZone {
        if selectedTimezone == "auto" {
            return TimeZone.current
        }
        return TimeZone(identifier: selectedTimezone) ?? TimeZone.current
    }

    var hours: Int {
        var cal = Calendar.current
        cal.timeZone = effectiveTimezone
        return cal.component(.hour, from: currentTime)
    }

    var minutes: Int {
        var cal = Calendar.current
        cal.timeZone = effectiveTimezone
        return cal.component(.minute, from: currentTime)
    }

    var seconds: Int {
        var cal = Calendar.current
        cal.timeZone = effectiveTimezone
        return cal.component(.second, from: currentTime)
    }

    var dateString: String {
        let formatter = DateFormatter()
        switch L10n.shared.language {
        case .zhHans:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEEE"
        case .zhHant:
            formatter.locale = Locale(identifier: "zh_TW")
            formatter.dateFormat = "M月d日 EEEE"
        case .en:
            formatter.locale = Locale(identifier: "en_US")
            formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        }
        formatter.timeZone = effectiveTimezone
        return formatter.string(from: currentTime)
    }

    var weatherString: String {
        if useFahrenheit {
            let f = Int(Double(weather.temperature) * 9.0 / 5.0 + 32.0)
            return "\(weather.emoji) \(f)°F"
        } else {
            return "\(weather.emoji) \(weather.temperature)°C"
        }
    }

    /// 根据当前语言返回本地化的城市名
    var localizedCityName: String {
        let name = weather.cityName.isEmpty ? resolvedCityName : weather.cityName
        guard !name.isEmpty else { return name }
        if L10n.shared.language == .en {
            return cityNameEN[name] ?? name
        } else if L10n.shared.language == .zhHant {
            return cityNameHant[name] ?? name
        }
        return name
    }

    private let cityNameEN: [String: String] = [
        "上海": "Shanghai", "北京": "Beijing", "香港": "Hong Kong",
        "东京": "Tokyo", "新加坡": "Singapore", "纽约": "New York",
        "伦敦": "London", "洛杉矶": "Los Angeles", "深圳": "Shenzhen",
        "广州": "Guangzhou", "成都": "Chengdu", "杭州": "Hangzhou",
        "武汉": "Wuhan", "南京": "Nanjing", "台北": "Taipei",
        "大阪": "Osaka", "首尔": "Seoul", "悉尼": "Sydney",
        "旧金山": "San Francisco", "西雅图": "Seattle", "芝加哥": "Chicago",
    ]

    private let cityNameHant: [String: String] = [
        "上海": "上海", "北京": "北京", "香港": "香港",
        "东京": "東京", "新加坡": "新加坡", "纽约": "紐約",
        "伦敦": "倫敦", "洛杉矶": "洛杉磯", "深圳": "深圳",
        "广州": "廣州", "成都": "成都", "杭州": "杭州",
        "武汉": "武漢", "南京": "南京", "台北": "臺北",
        "大阪": "大阪", "首尔": "首爾", "悉尼": "雪梨",
        "旧金山": "舊金山", "西雅图": "西雅圖", "芝加哥": "芝加哥",
    ]

    // MARK: - 天气

    private func fetchInitialWeather() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWeatherUpdate(_:)),
            name: .weatherUpdated, object: nil
        )
        WeatherService.shared.fetchLocalWeather()
    }

    @objc private func handleWeatherUpdate(_ notification: Notification) {
        guard let info = notification.object as? WeatherInfo else { return }
        weather = info
        if !info.cityName.isEmpty {
            resolvedCityName = info.cityName
        }
    }

    private func startTimers() {
        // 时钟：每秒更新
        clockTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.Timers.clock, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = Date()
            }
        }

        // 模拟数据：每 30s 更新
        dataTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.Timers.dataScan, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMockData()
            }
        }

        // 重置 recentTokens：每 10 分钟
        recentResetTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.Timers.recentReset, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard var tools = self?.tools else { return }
                UsageAggregator.resetRecentTokens(tools: &tools)
                self?.tools = tools
            }
        }

        // 天气刷新：每 5 分钟
        weatherTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.Timers.weather, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWeather()
            }
        }

        RunLoop.main.add(clockTimer!, forMode: .common)
        RunLoop.main.add(dataTimer!, forMode: .common)
        RunLoop.main.add(recentResetTimer!, forMode: .common)
        RunLoop.main.add(weatherTimer!, forMode: .common)
    }

    // MARK: - 日结历史(每天 00:01 落盘 viewModel.tools 快照)

    /// 调度下一个 00:01 触发(本地时区)。repeats: false,触发后重新调度。
    private func scheduleNextDailySettlement() {
        historyTimer?.invalidate()
        historyTimer = nil
        let cal = Calendar.current
        let now = Date()
        // 今天的 00:01
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 0
        comps.minute = 1
        let todayMidnight = cal.date(from: comps) ?? now
        // 如果今天 00:01 已过,下一个是明天 00:01
        let next: Date
        if todayMidnight > now {
            next = todayMidnight
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: todayMidnight) {
            next = tomorrow
        } else {
            next = now.addingTimeInterval(86_400)
        }
        let interval = next.timeIntervalSince(now)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performDailySettlement()
                self?.scheduleNextDailySettlement()  // 重新调度下一个 24h
            }
        }
        historyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let intervalMin = Int(interval / 60)
        print("[History] 下次日结: \(DateHelper.dateKey(from: next)) 00:01 (\(intervalMin) 分钟后)")
    }

    /// 抓当前 viewModel.tools 快照,落盘为"昨天"
    private func performDailySettlement() {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else { return }
        let dateKey = DateHelper.dateKey(from: yesterday)

        // 注:ViewModel 内部有自己的 nested ToolSnapshot 私有 struct
        // (L576 附近,14 个 service 的扫描结果用),字段不同。
        // 这里用 module-level 的 UsageServiceProtocol.ToolSnapshot(HistoryStore 需要),
        // 走全限定避免命名冲突。
        let snapshots: [TokenClock.ToolSnapshot] = tools.map { tool in
            TokenClock.ToolSnapshot(
                name: tool.name,
                tokens: tool.todayTokens,
                messages: tool.todayMessages,
                cacheRate: tool.cacheRate,
                isActive: tool.isActive
            )
        }
        HistoryStore.shared.upsertDay(dateKey: dateKey, snapshots: snapshots)
        UserDefaults.standard.setString(dateKey, for: .historyLastSettledDateKey)
        let totalTokens = snapshots.reduce(0) { $0 + $1.tokens }
        print("[History] 落盘 \(dateKey): \(snapshots.count) 工具,\(totalTokens) tokens")
    }

    /// 启动时检查上次结算日;按用户决定"漏了就漏了",不补打
    private func performStartupHistoryCatchup() {
        let lastSettled = UserDefaults.standard.string(for: .historyLastSettledDateKey)
        let today = DateHelper.todayKey()
        guard let last = lastSettled, last < today else { return }
        let cal = Calendar.current
        let lastDate = cal.date(from: DateComponents(year: Int(last.prefix(4)),
                                                      month: Int(last.dropFirst(5).prefix(2)),
                                                      day: Int(last.suffix(2)))) ?? Date()
        let daysBehind = cal.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
        print("[History] 启动检测:上次结算 \(last),今天 \(today),缺 \(max(0, daysBehind)) 天(不补打,SQLite 有啥返回啥)")
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        dataTimer?.invalidate()
        recentResetTimer?.invalidate()
        weatherTimer?.invalidate()
        historyTimer?.invalidate()
        historyTimer = nil
    }

    /// 手动刷新天气
    func refreshWeather() {
        if selectedCity == "auto" {
            WeatherService.shared.fetchLocalWeather()
        } else {
            WeatherService.shared.fetchWeather(forCity: selectedCity) { [weak self] info in
                self?.weather = info
            }
        }
    }


    private func updateMockData() {
        runBackgroundScan(incremental: true)
    }

    private func performFullScan() {
        runBackgroundScan(incremental: false)
    }

    /// 在后台线程执行扫描 + 数据提取，主线程只负责更新 UI
    private func runBackgroundScan(incremental: Bool) {
        // 重入守卫：dataTimer(30s) 与首次全量扫描可能并发触发；同一时刻只允许一个扫描
        guard !isScanning else { return }
        isScanning = true

        let enabled = enabledTools
        let rateWindow = rateWindowMinutes

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else {
                // self 已释放也要重置标志，否则永不能再扫（self 为 weak，这里其实拿不到 self；
                // 但 self==nil 意味着 ViewModel 已 dealloc，标志位随实例一起消失，无需处理）
                return
            }

            // 后台线程：执行所有 I/O 密集的扫描
            if enabled.contains("OpenClaw") { incremental ? self.openclawService.incrementalScan() : self.openclawService.fullScan() }
            if enabled.contains("Claude Code") { incremental ? self.claudeCodeService.incrementalScan() : self.claudeCodeService.fullScan() }
            if enabled.contains("Gemini CLI") { incremental ? self.geminiService.incrementalScan() : self.geminiService.fullScan() }
            if enabled.contains("Codex") { incremental ? self.codexService.incrementalScan() : self.codexService.fullScan() }
            if enabled.contains("Hermes") { incremental ? self.hermesService.incrementalScan() : self.hermesService.fullScan() }
            if enabled.contains("OpenCode") { incremental ? self.opencodeService.incrementalScan() : self.opencodeService.fullScan() }
            if enabled.contains("Qwen Code") { incremental ? self.qwenService.incrementalScan() : self.qwenService.fullScan() }
            if enabled.contains("Copilot") { incremental ? self.copilotService.incrementalScan() : self.copilotService.fullScan() }
            if enabled.contains("Grok") { incremental ? self.grokService.incrementalScan() : self.grokService.fullScan() }
            if enabled.contains("Aider") { incremental ? self.aiderService.incrementalScan() : self.aiderService.fullScan() }
            if enabled.contains("Antigravity") { incremental ? self.antigravityService.incrementalScan() : self.antigravityService.fullScan() }
            if enabled.contains("Cline") { incremental ? self.clineService.incrementalScan() : self.clineService.fullScan() }
            if enabled.contains("Continue") { incremental ? self.continueService.incrementalScan() : self.continueService.fullScan() }
            if enabled.contains("Cursor Agent") { incremental ? self.cursorAgentService.incrementalScan() : self.cursorAgentService.fullScan() }

            // 后台线程：提取数据（避免与主线程读取竞争）
            var results: [String: ToolSnapshot] = [:]
            if enabled.contains("OpenClaw") {
                let u = self.openclawService.todayUsage()
                results["OpenClaw"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.openclawService.recentUsage(minutes: rateWindow).tokens, hourly: self.openclawService.currentHourTokens(), active: self.openclawService.isActive(), cacheRate: u.cacheRate, sessions: self.openclawService.todaySessions())
            }
            if enabled.contains("Claude Code") {
                let u = self.claudeCodeService.todayUsage()
                results["Claude Code"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.claudeCodeService.recentUsage(minutes: rateWindow).tokens, hourly: self.claudeCodeService.currentHourTokens(), active: self.claudeCodeService.isActive(), cacheRate: u.cacheRate, sessions: self.claudeCodeService.todaySessions())
            }
            if enabled.contains("Gemini CLI") {
                let u = self.geminiService.todayUsage()
                results["Gemini CLI"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.geminiService.recentUsage(minutes: rateWindow).tokens, hourly: self.geminiService.currentHourTokens(), active: self.geminiService.isActive(), cacheRate: u.cacheRate, sessions: self.geminiService.todaySessions())
            }
            if enabled.contains("Codex") {
                let u = self.codexService.todayUsage()
                results["Codex"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.codexService.recentUsage(minutes: rateWindow).tokens, hourly: self.codexService.currentHourTokens(), active: self.codexService.isActive(), cacheRate: u.cacheRate, sessions: self.codexService.todaySessions())
            }
            if enabled.contains("Hermes") {
                let u = self.hermesService.todayUsage()
                results["Hermes"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.hermesService.recentUsage(minutes: rateWindow).tokens, hourly: self.hermesService.currentHourTokens(), active: self.hermesService.isActive(), cacheRate: u.cacheRate, sessions: self.hermesService.todaySessions())
            }
            if enabled.contains("OpenCode") {
                let u = self.opencodeService.todayUsage()
                results["OpenCode"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.opencodeService.recentUsage(minutes: rateWindow).tokens, hourly: self.opencodeService.currentHourTokens(), active: self.opencodeService.isActive(), cacheRate: u.cacheRate, sessions: self.opencodeService.todaySessions())
            }
            if enabled.contains("Qwen Code") {
                let u = self.qwenService.todayUsage()
                results["Qwen Code"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.qwenService.recentUsage(minutes: rateWindow).tokens, hourly: self.qwenService.currentHourTokens(), active: self.qwenService.isActive(), cacheRate: u.cacheRate, sessions: self.qwenService.todaySessions())
            }
            if enabled.contains("Copilot") {
                let u = self.copilotService.todayUsage()
                results["Copilot"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.copilotService.recentUsage(minutes: rateWindow).tokens, hourly: self.copilotService.currentHourTokens(), active: self.copilotService.isActive(), cacheRate: u.cacheRate, sessions: self.copilotService.todaySessions())
            }
            if enabled.contains("Grok") {
                let u = self.grokService.todayUsage()
                results["Grok"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.grokService.recentUsage(minutes: rateWindow).tokens, hourly: self.grokService.currentHourTokens(), active: self.grokService.isActive(), cacheRate: u.cacheRate, sessions: self.grokService.todaySessions())
            }
            if enabled.contains("Aider") {
                let u = self.aiderService.todayUsage()
                results["Aider"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.aiderService.recentUsage(minutes: rateWindow).tokens, hourly: self.aiderService.currentHourTokens(), active: self.aiderService.isActive(), cacheRate: u.cacheRate, sessions: self.aiderService.todaySessions())
            }
            if enabled.contains("Antigravity") {
                let u = self.antigravityService.todayUsage()
                results["Antigravity"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.antigravityService.recentUsage(minutes: rateWindow).tokens, hourly: self.antigravityService.currentHourTokens(), active: self.antigravityService.isActive(), cacheRate: u.cacheRate, sessions: self.antigravityService.todaySessions())
            }
            if enabled.contains("Cline") {
                let u = self.clineService.todayUsage()
                results["Cline"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.clineService.recentUsage(minutes: rateWindow).tokens, hourly: self.clineService.currentHourTokens(), active: self.clineService.isActive(), cacheRate: u.cacheRate, sessions: self.clineService.todaySessions())
            }
            if enabled.contains("Continue") {
                let u = self.continueService.todayUsage()
                results["Continue"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.continueService.recentUsage(minutes: rateWindow).tokens, hourly: self.continueService.currentHourTokens(), active: self.continueService.isActive(), cacheRate: u.cacheRate, sessions: self.continueService.todaySessions())
            }
            if enabled.contains("Cursor Agent") {
                let u = self.cursorAgentService.todayUsage()
                results["Cursor Agent"] = ToolSnapshot(tokens: u.tokens, messages: u.messages, recent: self.cursorAgentService.recentUsage(minutes: rateWindow).tokens, hourly: self.cursorAgentService.currentHourTokens(), active: self.cursorAgentService.isActive(), cacheRate: u.cacheRate, sessions: self.cursorAgentService.todaySessions())
            }

            // 主线程：批量更新 @Published tools
            await MainActor.run {
                for (name, snap) in results {
                    self.applySnapshot(name: name, snap: snap)
                }
                // 首次真实数据已就绪，退出加载态
                self.isInitialLoading = false
                // 扫描全部完成（含主线程应用快照），释放重入守卫，允许下一次调度
                self.isScanning = false
            }
        }
    }

    /// 一次扫描提取的快照（值类型，可安全跨线程传递）
    private struct ToolSnapshot {
        let tokens: Int
        let messages: Int
        let recent: Int
        let hourly: Int
        let active: Bool
        let cacheRate: Double
        let sessions: [SessionInfo]
    }

    /// 在主线程将快照应用到 tools 数组
    private func applySnapshot(name: String, snap: ToolSnapshot) {
        guard let idx = tools.firstIndex(where: { $0.name == name }) else { return }
        tools[idx] = ToolUsage(
            name: tools[idx].name,
            abbreviation: tools[idx].abbreviation,
            emoji: tools[idx].emoji,
            todayTokens: snap.tokens,
            todayMessages: snap.messages,
            isActive: snap.active,
            cacheRate: snap.cacheRate,
            recentTokens: snap.recent,
            hourlyTokens: snap.hourly,
            sessions: snap.sessions
        )
    }

    // MARK: - 窗口持久化

    static func saveWindowPosition(_ point: NSPoint) {
        UserDefaults.standard.set(CGFloat(point.x), forKey: "\(SettingsKey.windowPosition.rawValue)X")
        UserDefaults.standard.set(CGFloat(point.y), forKey: "\(SettingsKey.windowPosition.rawValue)Y")
    }

    static func loadWindowPosition(screenSize: NSSize) -> NSPoint {
        // 用 object(forKey:)==nil 区分"从未保存"与"保存为 0"，
        // 否则用户把窗口拖到屏幕左下角(x≈0,y≈0)会被误判为未保存而弹回右上角。
        let xKey = "\(SettingsKey.windowPosition.rawValue)X"
        let yKey = "\(SettingsKey.windowPosition.rawValue)Y"
        let xSaved = UserDefaults.standard.object(forKey: xKey) != nil
        let ySaved = UserDefaults.standard.object(forKey: yKey) != nil
        if xSaved || ySaved {
            let x = UserDefaults.standard.double(forKey: xKey)
            let y = UserDefaults.standard.double(forKey: yKey)
            return NSPoint(x: x, y: y)
        }
        // 默认右上角
        return NSPoint(x: screenSize.width - 220, y: screenSize.height - 260)
    }

    // MARK: - 清理

    /// 移除所有 NotificationCenter 观察者（fetchInitialWeather 注册了 .weatherUpdated）
    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
