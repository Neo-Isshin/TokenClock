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
    let model: String?
    let cost: CostEstimate
    let cacheReadTokens: Int?

    init(id: String, displayName: String, tokens: Int, messages: Int,
         isActive: Bool, model: String? = nil,
         cost: CostEstimate = .unavailable, cacheReadTokens: Int? = nil) {
        self.id = id; self.displayName = displayName; self.tokens = tokens
        self.messages = messages; self.isActive = isActive; self.model = model
        self.cost = cost; self.cacheReadTokens = cacheReadTokens
    }
}

/// 单个工具的日结快照：每天 00:01 抓 viewModel.tools 写入 history.sqlite
struct ToolSnapshot: Sendable {
    let name: String
    let tokens: Int
    let messages: Int
    let cacheRate: Double
    let isActive: Bool
    let cost: CostEstimate
    let cacheReadTokens: Int?
    /// 当日各 session 明细（默认空 → 旧构造调用不破坏）
    let sessions: [SessionSnapshot]

    /// 显式 init：sessions 带默认值。既有 `ToolSnapshot(name:tokens:messages:cacheRate:isActive:)`
    /// 调用仍合法（省略 sessions）。显式化可避免带闭包参数时 memberwise init 的类型推断误报。
    init(name: String, tokens: Int, messages: Int,
         cacheRate: Double, isActive: Bool,
         cost: CostEstimate = .unavailable,
         cacheReadTokens: Int? = nil,
         sessions: [SessionSnapshot] = []) {
        self.name = name
        self.tokens = tokens
        self.messages = messages
        self.cacheRate = cacheRate
        self.isActive = isActive
        self.cost = cost
        self.cacheReadTokens = cacheReadTokens
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
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func todayKey() -> String {
        dateKey(from: Date())
    }

    /// 解析 ISO8601 UTC 时间戳，返回绝对 Date
    static func parseISO8601(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 19,
              bytes[4] == 0x2D, bytes[7] == 0x2D,
              (bytes[10] == 0x54 || bytes[10] == 0x20),
              bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }

        func number(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else {
            return nil
        }
        guard let base = utcCalendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )) else { return nil }

        var index = 19
        var fractionalSeconds = 0.0
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            var scale = 0.1
            let fractionStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                fractionalSeconds += Double(bytes[index] - 0x30) * scale
                scale *= 0.1
                index += 1
            }
            guard index > fractionStart else { return nil }
        }

        var offsetSeconds = 0
        if index < bytes.count {
            if bytes[index] == 0x5A || bytes[index] == 0x7A { // Z / z
                index += 1
            } else if bytes[index] == 0x2B || bytes[index] == 0x2D { // + / -
                let sign = bytes[index] == 0x2B ? 1 : -1
                index += 1
                guard index + 1 < bytes.count,
                      let offsetHour = number(index, 2) else { return nil }
                index += 2
                if index < bytes.count, bytes[index] == 0x3A { index += 1 }
                guard index + 1 < bytes.count,
                      let offsetMinute = number(index, 2),
                      offsetHour <= 23, offsetMinute <= 59 else { return nil }
                index += 2
                offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        return base.addingTimeInterval(fractionalSeconds - Double(offsetSeconds))
    }

    /// 从 ISO8601 UTC 时间戳提取本地日期 key
    static func localDateKey(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return "" }
        return dateKey(from: date)
    }

    /// 从 ISO8601 UTC 时间戳提取本地小时 key（如 "2026-04-23-22"）
    static func localHourKey(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return "" }
        return hourKey(from: date)
    }

    /// 从 Date 提取本地日期 key
    static func dateKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return key(components.year, components.month, components.day)
    }

    /// 从 Date 提取本地小时 key
    static func hourKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        return key(components.year, components.month, components.day, components.hour)
    }

    /// 当前本地小时 key
    static func currentHourKey() -> String {
        hourKey(from: Date())
    }

    private static func key(_ year: Int?, _ month: Int?, _ day: Int?, _ hour: Int? = nil) -> String {
        guard let year, let month, let day else { return "" }
        let date = "\(year)-\(padded(month))-\(padded(day))"
        guard let hour else { return date }
        return date + "-\(padded(hour))"
    }

    private static func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
