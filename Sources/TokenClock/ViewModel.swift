import SwiftUI
import Combine

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

    @Published var windowOpacity: Double = 1.0
    @Published var alwaysOnTop: Bool = {
        UserDefaults.standard.bool(for: .alwaysOnTop, default: true)
    }()
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(for: .launchAtLogin, default: false) {
        didSet { UserDefaults.standard.setBool(launchAtLogin, for: .launchAtLogin) }
    }

    /// 表盘主题
    @Published var selectedTheme: ClockFaceTheme = .glass   // 默认表盘：玻璃（normal）

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
        let total = UsageAggregator.totalTokens(visibleTools)
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
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


    private func updateMockData() {
        runBackgroundScan(incremental: true)
    }

    private func performFullScan() {
        runBackgroundScan(incremental: false)
    }

    /// 在后台线程执行扫描 + 数据提取，主线程只负责更新 UI
    private func runBackgroundScan(incremental: Bool) {
        let enabled = enabledTools
        let rateWindow = rateWindowMinutes

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

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
        let x = UserDefaults.standard.double(forKey: "\(SettingsKey.windowPosition.rawValue)X")
        let y = UserDefaults.standard.double(forKey: "\(SettingsKey.windowPosition.rawValue)Y")
        if x != 0 || y != 0 {
            return NSPoint(x: x, y: y)
        }
        // 默认右上角
        return NSPoint(x: screenSize.width - 220, y: screenSize.height - 260)
    }
}
