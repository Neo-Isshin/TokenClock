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

    /// 天气数据（后续接入 API）
    @Published var weather = WeatherInfo()
    @Published var weatherCity = "Hong Kong"

    private var clockTimer: Timer?
    private var dataTimer: Timer?
    private var recentResetTimer: Timer?

    init() {
        self.tools = MockUsageService.generateInitialData()
        startTimers()
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

    var activeToolsList: [ToolUsage] {
        UsageAggregator.activeTools(tools, limit: 2)
    }

    var rateEmoji: String {
        UsageAggregator.rateEmoji(tools)
    }

    // MARK: - 时间属性

    var hours: Int {
        Calendar.current.component(.hour, from: currentTime)
    }

    var minutes: Int {
        Calendar.current.component(.minute, from: currentTime)
    }

    var seconds: Int {
        Calendar.current.component(.second, from: currentTime)
    }

    var dateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: currentTime)
    }

    var weatherString: String {
        "\(weather.emoji) \(weather.temperature)°"
    }

    // MARK: - Timers

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

        RunLoop.main.add(clockTimer!, forMode: .common)
        RunLoop.main.add(dataTimer!, forMode: .common)
        RunLoop.main.add(recentResetTimer!, forMode: .common)
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        dataTimer?.invalidate()
        recentResetTimer?.invalidate()
    }

    private func updateMockData() {
        MockUsageService.simulateIncrement(tools: &tools)
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
