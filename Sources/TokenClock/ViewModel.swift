import SwiftUI
import Combine

@MainActor
final class ViewModel: ObservableObject {
    @Published var tools: [ToolUsage] {
        didSet { updateSortedTools() }
    }

    /// 预计算排序后的工具列表，避免每次展开时重新排序
    @Published private(set) var sortedTools: [ToolUsage] = []

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

    @Published var windowOpacity: Double = 1.0
    @Published var alwaysOnTop = true
    @Published var launchAtLogin = false

    /// 表盘主题
    @Published var selectedTheme: ClockFaceTheme = .classic

    /// 天气数据
    @Published var weather = WeatherInfo()
    @Published var useFahrenheit = false
    @Published var selectedCity: String = "auto"
    /// IP 定位解析到的城市名（用于菜单动态标签）
    @Published var resolvedCityName: String = ""

    /// 可选城市列表（auto = 自动定位）
    static let cityOptions = ["auto", "Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York"]
    static let cityLabels: [String: String] = [
        "auto": "自动(城市名)", "Hong Kong": "Hong Kong",
        "Shanghai": "Shanghai", "Beijing": "Beijing",
        "Tokyo": "Tokyo", "Singapore": "Singapore",
        "New York": "New York",
    ]

    /// 时区设置
    @Published var selectedTimezone: String = "auto"

    /// 热力统计周期（分钟）
    @Published var rateWindowMinutes: Int = 10

    /// 已保存的自定义主题列表
    @Published var savedCustomThemes: [SavedCustomTheme] = []
    /// 当前激活的自定义主题 ID（nil 表示使用默认未命名配置）
    @Published var activeCustomThemeId: UUID? = nil

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

    // 真实数据服务
    private let openclawService = OpenClawUsageService()
    private let claudeCodeService = ClaudeCodeUsageService()
    private let geminiService = GeminiUsageService()
    private let codexService = CodexUsageService()
    private let hermesService = HermesUsageService()

    init() {
        // 先生成初始结构，再被真实数据覆盖
        self.tools = MockUsageService.generateInitialData()
        updateSortedTools()
        loadTheme()
        loadRateWindow()
        loadSavedCustomThemes()
        // 首次启动时自动探测各工具日志路径
        runInitialPathDetection()
        startTimers()
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

    // MARK: - 主题持久化

    func saveTheme() {
        UserDefaults.standard.set(selectedTheme.rawValue, forKey: "TC_selectedTheme")
    }

    private func loadTheme() {
        if let saved = UserDefaults.standard.string(forKey: "TC_selectedTheme"),
           let theme = ClockFaceTheme(rawValue: saved) {
            selectedTheme = theme
        }
    }

    private func loadRateWindow() {
        let saved = UserDefaults.standard.integer(forKey: "TC_rateWindow")
        rateWindowMinutes = saved > 0 ? saved : 10
    }

    // MARK: - 自定义主题管理

    private func loadSavedCustomThemes() {
        savedCustomThemes = SavedCustomTheme.loadAll()
        if let savedIdString = UserDefaults.standard.string(forKey: "TC_activeCustomThemeId"),
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
            UserDefaults.standard.removeObject(forKey: "TC_activeCustomThemeId")
        }
    }

    func applyCustomTheme(id: UUID) {
        guard let theme = savedCustomThemes.first(where: { $0.id == id }) else { return }
        activeCustomThemeId = id
        UserDefaults.standard.set(id.uuidString, forKey: "TC_activeCustomThemeId")
        // 将配置同步到 CustomThemeConfig 的默认存储，供 ClockFaceTheme.custom 读取
        theme.config.save()
    }

    // MARK: - 聚合属性

    var totalTokensFormatted: String {
        let total = UsageAggregator.totalTokens(tools)
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }

    var totalMessagesFormatted: String {
        let total = UsageAggregator.totalMessages(tools)
        return L10n.shared.tr("clock.messagesCount", total)
    }

    var totalMessagesCount: Int {
        UsageAggregator.totalMessages(tools)
    }

    var activeToolsList: [ToolUsage] {
        UsageAggregator.topToolsByTokens(tools, limit: 2)
    }

    var rateEmoji: String {
        UsageAggregator.rateEmoji(tools)
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
        case .zhHans: formatter.locale = Locale(identifier: "zh_CN")
        case .zhHant: formatter.locale = Locale(identifier: "zh_TW")
        case .en:     formatter.locale = Locale(identifier: "en_US")
        }
        formatter.dateFormat = "M月d日 EEEE"
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
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = Date()
            }
        }

        // 模拟数据：每30秒更新
        dataTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMockData()
            }
        }

        // 重置 recentTokens：每10分钟
        recentResetTimer = Timer.scheduledTimer(withTimeInterval: 600.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard var tools = self?.tools else { return }
                UsageAggregator.resetRecentTokens(tools: &tools)
                self?.tools = tools
            }
        }

        // 天气刷新：每5分钟
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWeather()
            }
        }

        RunLoop.main.add(clockTimer!, forMode: .common)
        RunLoop.main.add(dataTimer!, forMode: .common)
        RunLoop.main.add(recentResetTimer!, forMode: .common)
        RunLoop.main.add(weatherTimer!, forMode: .common)
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        dataTimer?.invalidate()
        recentResetTimer?.invalidate()
        weatherTimer?.invalidate()
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

    /// 从真实数据服务刷新所有工具的 token 数据
    private func refreshRealData() {
        let oc = openclawService.todayUsage()
        let ocRecent = openclawService.recentUsage(minutes: rateWindowMinutes)
        updateTool(name: "OpenClaw", tokens: oc.tokens, messages: oc.messages,
                   recentTokens: ocRecent.tokens, hourlyTokens: openclawService.currentHourTokens(),
                   active: openclawService.isActive(), cacheRate: oc.cacheRate,
                   sessions: openclawService.todaySessions())

        let cc = claudeCodeService.todayUsage()
        let ccRecent = claudeCodeService.recentUsage(minutes: rateWindowMinutes)
        updateTool(name: "Claude Code", tokens: cc.tokens, messages: cc.messages,
                   recentTokens: ccRecent.tokens, hourlyTokens: claudeCodeService.currentHourTokens(),
                   active: claudeCodeService.isActive(), cacheRate: cc.cacheRate,
                   sessions: claudeCodeService.todaySessions())

        let gc = geminiService.todayUsage()
        let gcRecent = geminiService.recentUsage(minutes: rateWindowMinutes)
        updateTool(name: "Gemini CLI", tokens: gc.tokens, messages: gc.messages,
                   recentTokens: gcRecent.tokens, hourlyTokens: geminiService.currentHourTokens(),
                   active: geminiService.isActive(), cacheRate: gc.cacheRate,
                   sessions: geminiService.todaySessions())

        let cx = codexService.todayUsage()
        let cxRecent = codexService.recentUsage(minutes: rateWindowMinutes)
        updateTool(name: "Codex", tokens: cx.tokens, messages: cx.messages,
                   recentTokens: cxRecent.tokens, hourlyTokens: codexService.currentHourTokens(),
                   active: codexService.isActive(), cacheRate: cx.cacheRate,
                   sessions: codexService.todaySessions())

        let hm = hermesService.todayUsage()
        let hmRecent = hermesService.recentUsage(minutes: rateWindowMinutes)
        updateTool(name: "Hermes", tokens: hm.tokens, messages: hm.messages,
                   recentTokens: hmRecent.tokens, hourlyTokens: hermesService.currentHourTokens(),
                   active: hermesService.isActive(), cacheRate: hm.cacheRate,
                   sessions: hermesService.todaySessions())
    }

    private func updateTool(name: String, tokens: Int, messages: Int,
                           recentTokens: Int, hourlyTokens: Int, active: Bool,
                           cacheRate: Double = 0, sessions: [SessionInfo] = []) {
        guard let idx = tools.firstIndex(where: { $0.name == name }) else { return }
        tools[idx] = ToolUsage(
            name: tools[idx].name,
            abbreviation: tools[idx].abbreviation,
            emoji: tools[idx].emoji,
            todayTokens: tokens,
            todayMessages: messages,
            isActive: active,
            cacheRate: cacheRate,
            recentTokens: recentTokens,
            hourlyTokens: hourlyTokens,
            sessions: sessions
        )
    }

    private func updateMockData() {
        openclawService.incrementalScan()
        claudeCodeService.incrementalScan()
        geminiService.incrementalScan()
        codexService.incrementalScan()
        hermesService.incrementalScan()
        refreshRealData()
    }

    private func performFullScan() {
        openclawService.fullScan()
        claudeCodeService.fullScan()
        geminiService.fullScan()
        codexService.fullScan()
        hermesService.fullScan()
        refreshRealData()
    }

    // MARK: - 窗口持久化

    private static let positionKey = "TokenClockWindowPosition"

    static func saveWindowPosition(_ point: NSPoint) {
        UserDefaults.standard.set(CGFloat(point.x), forKey: "\(positionKey)X")
        UserDefaults.standard.set(CGFloat(point.y), forKey: "\(positionKey)Y")
    }

    static func loadWindowPosition(screenSize: NSSize) -> NSPoint {
        let x = UserDefaults.standard.double(forKey: "\(positionKey)X")
        let y = UserDefaults.standard.double(forKey: "\(positionKey)Y")
        if x != 0 || y != 0 {
            return NSPoint(x: x, y: y)
        }
        // 默认右上角
        return NSPoint(x: screenSize.width - 220, y: screenSize.height - 260)
    }
}
