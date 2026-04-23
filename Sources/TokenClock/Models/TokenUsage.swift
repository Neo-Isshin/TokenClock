import Foundation

/// 单个工具的 token 使用数据
struct ToolUsage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let abbreviation: String
    let emoji: String
    var todayTokens: Int
    var todayMessages: Int
    var isActive: Bool

    /// 近10分钟内新增的 tokens（用于速率计算）
    var recentTokens: Int

    /// 格式化的 token 数（如 "847.2K"）
    var formattedTokens: String {
        if todayTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(todayTokens) / 1_000_000)
        } else if todayTokens >= 1_000 {
            return String(format: "%.1fK", Double(todayTokens) / 1_000)
        } else {
            return "\(todayTokens)"
        }
    }

    /// 格式化的消息数
    var formattedMessages: String {
        "\(todayMessages)"
    }
}

/// 天气数据
struct WeatherInfo {
    var emoji: String = "☀️"
    var temperature: Int = 28
    var cityName: String = ""
}
