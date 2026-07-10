import XCTest
@testable import TokenClock

/// DateHelper 测试 —— 每个 token 事件的日期/小时归属都流经这些函数，
/// 解析错字段或格式串错位会让「今日 token」整条统计偏移。
///
/// 设计：不依赖时区（全局改 NSTimeZone.default 在不同 Foundation 版本上不可靠）。
/// parseISO8601 返回绝对 Date（时区无关）单独测；localDateKey/hourKey 用一个**独立的**
/// ISO8601DateFormatter 解析 + TimeZone.current 格式化算期望值，与被测代码交叉验证。
final class DateHelperTests: XCTestCase {

    // 独立解析器（不复用 DateHelper.parseISO8601，避免同源盲区）
    private func independentDate(_ iso: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // 带毫秒
        if let d = f1.date(from: iso) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]                           // 不带毫秒
        return f2.date(from: iso)
    }
    private func refKey(_ iso: String, format: String) -> String {
        guard let d = independentDate(iso) else { return "" }
        let f = DateFormatter(); f.dateFormat = format; f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    // MARK: - parseISO8601（时区无关）

    func testParseISO8601_full() {
        let d = DateHelper.parseISO8601("2026-07-10T12:34:56Z")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 7); XCTAssertEqual(c.day, 10)
        XCTAssertEqual(c.hour, 12); XCTAssertEqual(c.minute, 34); XCTAssertEqual(c.second, 56)
    }

    func testParseISO8601_ignoresMillisecondSuffix() {
        // Claude Code 时间戳带 .fff 毫秒后缀；parseISO8601 只读前 19 个字符
        XCTAssertEqual(DateHelper.parseISO8601("2026-07-10T12:34:56.789Z"),
                       DateHelper.parseISO8601("2026-07-10T12:34:56Z"))
    }

    func testParseISO8601_rejectsShortString() {
        XCTAssertNil(DateHelper.parseISO8601("2026-07"))   // 太短（<19）
        XCTAssertNil(DateHelper.parseISO8601(""))
    }

    // MARK: - localDateKey / localHourKey（交叉验证独立格式化器，时区无关）

    func testLocalDateKeyHourKey_matchReference() {
        let iso = "2026-07-10T12:34:56.000Z"
        XCTAssertEqual(DateHelper.localDateKey(from: iso), refKey(iso, format: "yyyy-MM-dd"))
        XCTAssertEqual(DateHelper.localHourKey(from: iso), refKey(iso, format: "yyyy-MM-dd-HH"))
    }

    func testLocalDateKey_invalidTimestamp() {
        // 解析失败 → 返回空串（parseLine 里靠 count==10 过滤掉）
        XCTAssertEqual(DateHelper.localDateKey(from: "garbage"), "")
    }

    // MARK: - dateKey / hourKey from Date

    func testDateKeyFromConcreteDate_matchReference() {
        let iso = "2026-07-10T09:05:00Z"
        let d = independentDate(iso)!
        XCTAssertEqual(DateHelper.dateKey(from: d), refKey(iso, format: "yyyy-MM-dd"))
        XCTAssertEqual(DateHelper.hourKey(from: d), refKey(iso, format: "yyyy-MM-dd-HH"))
    }
}
