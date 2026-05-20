import Foundation

/// 单个工具的 token 使用数据
struct ToolUsage: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let abbreviation: String
    let emoji: String
    var todayTokens: Int
    var todayMessages: Int
    var isActive: Bool
    var cacheRate: Double = 0

    /// 近10分钟内新增的 tokens（用于活跃度判断）
    var recentTokens: Int

    /// 当前小时 token 消耗（用于热力计算）
    var hourlyTokens: Int

    /// 今日活跃的 session/agent 列表（用于展开展示）
    var sessions: [SessionInfo] = []

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

/// 单个 session 或 agent 的今日数据
struct SessionInfo: Identifiable, Hashable {
    var id: String { rawId }
    /// 原始 session ID 或 agent 名
    let rawId: String
    /// 展示名称（session 前7位 或 agent 名）
    let displayName: String
    /// 额外详情（如项目路径、agent 描述）
    let detail: String?
    /// 今日 token 消耗
    let todayTokens: Int
    /// 今日消息数
    let todayMessages: Int
    /// 是否活跃（最近10分钟内有活动）
    let isActive: Bool

    /// 格式化的 token 数
    var formattedTokens: String {
        if todayTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(todayTokens) / 1_000_000)
        } else if todayTokens >= 1_000 {
            return String(format: "%.1fK", Double(todayTokens) / 1_000)
        } else {
            return "\(todayTokens)"
        }
    }
}

/// 天气数据
struct WeatherInfo {
    var emoji: String = "☀️"
    var temperature: Int = 28
    var cityName: String = ""
    /// 逐 3 小时预报（用于展开面板展示趋势）
    var forecast: [HourlyForecast] = []
}
