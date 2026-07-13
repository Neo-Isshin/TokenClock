import Foundation

/// 紧凑 token 计数格式化（表盘 / 工具行 / session 行共用，避免三处各自实现而漂移）。
/// 档位：B(≥1e9，2 位小数) / M(≥1e6，1 位) / K(≥1e3，1 位) / 原值。
/// B 用 2 位小数：1.23B 分辨率≈10M，十亿级足够；M/K 保持 1 位与历史显示一致。
enum TokenFormat {
    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

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

    /// 格式化的 token 数（如 "847.2K" / "1.23B"）
    var formattedTokens: String { TokenFormat.compact(todayTokens) }

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
    /// 来源标签（如 Antigravity 的 CLI/IDE/App），显示在 "session" 标签右侧；nil 则不显示
    var source: String? = nil

    /// 该 session 使用的模型名（经 `ModelNormalizer` 归一化后的官方名，如 "claude-sonnet-4-5"）；
    /// nil = 日志里解析不到 → 在「按模型」视图里归入「未知」桶。
    var model: String? = nil

    /// 格式化的 token 数
    var formattedTokens: String { TokenFormat.compact(todayTokens) }
}

/// Session ID 统一格式化：取前 6 位 + "…" + 末 4 位
/// 用于解决 UUIDv7 / session-UUID 前缀碰撞导致的视觉混淆
enum SessionIdDisplay {
    static func format(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 10 { return trimmed }
        let head = trimmed.prefix(6)
        let tail = trimmed.suffix(4)
        return "\(head)…\(tail)"
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
