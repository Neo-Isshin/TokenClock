import Foundation

/// 共享的日期聚合数据
struct DayUsage: Sendable {
    var tokens: Int
    var messages: Int
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

/// 日期工具
enum DateHelper: Sendable {
    static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }

    /// 快速解析 ISO8601 时间戳（避免 NSDateFormatter 开销）
    static func parseISO8601(_ s: String) -> Date? {
        let chars = Array(s)
        guard chars.count >= 19 else { return nil }
        // "2026-04-23T13:32:00.594Z"
        let y = Int(String(chars[0...3])) ?? 0
        let m = Int(String(chars[5...6])) ?? 1
        let d = Int(String(chars[8...9])) ?? 1
        let hr = Int(String(chars[11...12])) ?? 0
        let mn = Int(String(chars[14...15])) ?? 0
        let sc = Int(String(chars[17...18])) ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = hr; components.minute = mn; components.second = sc
        return cal.date(from: components)
    }

    /// 从 ISO 字符串提取日期 key
    static func dateKey(from isoString: String) -> String {
        let chars = Array(isoString)
        guard chars.count >= 10 else { return "" }
        return String(chars[0...9])
    }
}
