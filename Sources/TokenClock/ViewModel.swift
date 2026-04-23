import SwiftUI
import Combine

@MainActor
final class ViewModel: ObservableObject {
    @Published var tools: [ToolUsage]
    @Published var currentTime = Date()
    @Published var isExpanded = false
    @Published var windowOpacity: Double = 1.0
    @Published var alwaysOnTop = true
    @Published var launchAtLogin = false

    /// 天气数据
    @Published var weather = WeatherInfo()
    @Published var useFahrenheit = false

    /// 时区设置
    @Published var selectedTimezone: String = "auto"

    /// 可用时区列表
    static let timezoneOptions: [(label: String, identifier: String)] = [
        ("自动", "auto"),
        ("香港 HKT", "Asia/Hong_Kong"),
        ("上海 CST", "Asia/Shanghai"),
        ("东京 JST", "Asia/Tokyo"),
        ("新加坡 SGT", "Asia/Singapore"),
        ("纽约 EST", "America/New_York"),
        ("伦敦 GMT", "Europe/London"),
        ("洛杉矶 PST", "America/Los_Angeles"),
    ]

    private var clockTimer: Timer?
    private var dataTimer: Timer?
    private var recentResetTimer: Timer?
    private var weatherTimer: Timer?

    // 真实数据服务
    private let openclawService = OpenClawUsageService()
    private let claudeCodeService = ClaudeCodeUsageService()
    private let geminiService = GeminiUsageService()

    init() {
        // 先生成初始结构，再被真实数据覆盖
        self.tools = MockUsageService.generateInitialData()
        startTimers()
        fetchInitialWeather()
        // 首次全量扫描
        performFullScan()
    }

    func shutdown() {
        stopTimers()
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
        return "\(total) 条"
    }

    var totalMessagesCount: Int {
        UsageAggregator.totalMessages(tools)
    }

    var activeToolsList: [ToolUsage] {
        UsageAggregator.activeTools(tools, limit: 2)
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
        formatter.locale = Locale(identifier: "zh_CN")
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
        WeatherService.shared.fetchLocalWeather()
    }

    /// 从真实数据服务刷新所有工具的 token 数据
    private func refreshRealData() {
        // OpenClaw（聚合所有 agent）
        let oc = openclawService.todayUsage()
        let ocRecent = openclawService.recentUsage()
        let ocActive = openclawService.isActive()
        updateTool(name: "OpenClaw", tokens: oc.tokens, messages: oc.messages,
                   recentTokens: ocRecent.tokens, active: ocActive)

        // Claude Code
        let cc = claudeCodeService.todayUsage()
        let ccRecent = claudeCodeService.recentUsage()
        let ccActive = claudeCodeService.isActive()
        updateTool(name: "Claude Code", tokens: cc.tokens, messages: cc.messages,
                   recentTokens: ccRecent.tokens, active: ccActive)

        // Gemini CLI
        let gc = geminiService.todayUsage()
        let gcRecent = geminiService.recentUsage()
        let gcActive = geminiService.isActive()
        updateTool(name: "Gemini CLI", tokens: gc.tokens, messages: gc.messages,
                   recentTokens: gcRecent.tokens, active: gcActive)

        // Hermes 和 Codex 暂时保留上次值（无数据源）
    }

    private func updateTool(name: String, tokens: Int, messages: Int,
                           recentTokens: Int, active: Bool) {
        guard let idx = tools.firstIndex(where: { $0.name == name }) else { return }
        tools[idx].todayTokens = tokens
        tools[idx].todayMessages = messages
        tools[idx].recentTokens = recentTokens
        tools[idx].isActive = active
    }

    private func updateMockData() {
        // 增量扫描 + 刷新（在主线程执行，增量 IO 很轻量）
        openclawService.incrementalScan()
        claudeCodeService.incrementalScan()
        geminiService.incrementalScan()
        refreshRealData()
    }

    private func performFullScan() {
        openclawService.fullScan()
        claudeCodeService.fullScan()
        geminiService.fullScan()
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
