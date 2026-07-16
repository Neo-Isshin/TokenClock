import Foundation

/// 共享的日期聚合数据
struct DayUsage: Sendable {
    var tokens: Int
    var messages: Int
}

/// 单个工具日结快照内、单个 session 的明细（当日增量口径，与 tool 级同源）。
/// 序列化进 daily_snapshots.sessions_json；/api/history?detail=sessions 时透出。
struct SessionSnapshot: Sendable {
    let id: String
    let displayName: String
    let tokens: Int
    let messages: Int
    let isActive: Bool
}

/// 单个工具的日结快照：每天 00:01 抓 viewModel.tools 写入 history.sqlite
struct ToolSnapshot: Sendable {
    let name: String
    let tokens: Int
    let messages: Int
    let cacheRate: Double
    let isActive: Bool
    /// 当日各 session 明细（默认空 → 旧构造调用不破坏）
    let sessions: [SessionSnapshot]

    /// 显式 init：sessions 带默认值。既有 `ToolSnapshot(name:tokens:messages:cacheRate:isActive:)`
    /// 调用仍合法（省略 sessions）。显式化可避免带闭包参数时 memberwise init 的类型推断误报。
    init(name: String, tokens: Int, messages: Int,
         cacheRate: Double, isActive: Bool,
         sessions: [SessionSnapshot] = []) {
        self.name = name
        self.tokens = tokens
        self.messages = messages
        self.cacheRate = cacheRate
        self.isActive = isActive
        self.sessions = sessions
    }
}

/// 共享的文件缓存元数据
struct FileMeta: Hashable, Sendable {
    let path: String
    let modDate: Date
}

/// 共享的最近条目（用于 recentTokens 计算）
struct RecentEntry: Sendable {
    let timestamp: Date
    let tokens: Int
}

/// 按小时聚合的 token 数据
struct HourlyUsage: Sendable {
    var tokens: Int
    var messages: Int
}

/// 日期工具
enum DateHelper: Sendable {
    static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }

    /// 解析 ISO8601 UTC 时间戳，返回绝对 Date
    static func parseISO8601(_ s: String) -> Date? {
        let chars = Array(s)
        guard chars.count >= 19 else { return nil }
        let y = Int(String(chars[0...3])) ?? 0
        let m = Int(String(chars[5...6])) ?? 1
        let d = Int(String(chars[8...9])) ?? 1
        let hr = Int(String(chars[11...12])) ?? 0
        let mn = Int(String(chars[14...15])) ?? 0
        let sc = Int(String(chars[17...18])) ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(abbreviation: "UTC")!
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = hr; components.minute = mn; components.second = sc
        return cal.date(from: components)
    }

    /// 从 ISO8601 UTC 时间戳提取本地日期 key
    static func localDateKey(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// 从 ISO8601 UTC 时间戳提取本地小时 key（如 "2026-04-23-22"）
    static func localHourKey(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// 从 Date 提取本地日期 key
    static func dateKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// 从 Date 提取本地小时 key
    static func hourKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// 当前本地小时 key
    static func currentHourKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
