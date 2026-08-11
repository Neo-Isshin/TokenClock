import XCTest
@testable import TokenClock

/// ClaudeCodeUsageService 集成测试 —— 验证 token 字段公式（来自 docs/TOOL_SCHEMA_ANALYSIS）：
///   tokens = input_tokens + output_tokens + cache_creation_input_tokens
///   （cache_read_input_tokens 仅作为缓存命中诊断，不进入主用量）
///
/// 通过 PathConfig.setClaudeCodePath(tmp) 把服务重定向到临时 fixture 目录，
/// 不读真实 ~/.claude、无需侵入式重构。期望的日期/小时 key 用 DateHelper（服务的依赖，
/// 已由 DateHelperTests 覆盖）就地算出，断言与运行机器时区无关。其余 13 个 UsageService
/// 照此模式展开。
final class ClaudeCodeUsageServiceTests: XCTestCase {

    private var tmpRoot: String!

    override func setUp() {
        super.setUp()
        tmpRoot = NSTemporaryDirectory() + "tc-claude-test-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        PathConfig.setClaudeCodePath(tmpRoot)
    }

    override func tearDown() {
        PathConfig.setClaudeCodePath("")                  // 还原默认（~/.claude）
        try? FileManager.default.removeItem(atPath: tmpRoot)
        super.tearDown()
    }

    /// 在 tmp/projects/<proj>/<session>.jsonl 写入若干 JSONL 行
    private func writeSession(project: String, session: String, lines: [String]) {
        let projDir = tmpRoot + "projects/\(project)/"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(toFile: projDir + session, atomically: true, encoding: .utf8)
    }

    /// 构造一条 assistant 消息行（匹配 Claude Code 真实 JSONL 结构）
    private func assistantLine(input: Int, output: Int, cacheRead: Int, cacheCreation: Int = 0,
                               timestamp: String = "2026-07-10T12:00:00.000Z") -> String {
        let usage = "{\"input_tokens\":\(input),\"output_tokens\":\(output)," +
                    "\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheCreation)}"
        return "{\"type\":\"assistant\",\"message\":{\"usage\":\(usage)},\"timestamp\":\"\(timestamp)\"}"
    }

    func testTokenFormula_excludesCacheRead_includesCacheCreation() {
        // 12:00Z 与 12:30Z 在所有现实时区都落同一本地日 → 可安全合计
        let ts1 = "2026-07-10T12:00:00.000Z"
        let ts2 = "2026-07-10T12:30:00.000Z"
        writeSession(project: "p1", session: "s1.jsonl", lines: [
            assistantLine(input: 100, output: 50, cacheRead: 200, cacheCreation: 30, timestamp: ts1),  // 180
            assistantLine(input: 10, output: 5, cacheRead: 0, timestamp: ts2),                         // 15
        ])

        let svc = ClaudeCodeUsageService()
        svc.fullScan()

        let key = DateHelper.localDateKey(from: ts1)
        let day = svc.dailyData[key]
        XCTAssertEqual(day?.tokens, 195, "tokens 应 = input+output+cache_creation（不含 cache_read）")
        XCTAssertEqual(day?.messages, 2)
        XCTAssertEqual(svc.dailyCache[key], 200, "缓存诊断仅统计 cache_read")
    }

    func testHourlyBuckets_splitByHour() {
        let ts1 = "2026-07-10T12:30:00.000Z"
        let ts2 = "2026-07-10T13:30:00.000Z"   // 不同 UTC 小时 → 不同本地小时 key
        writeSession(project: "p1", session: "s1.jsonl", lines: [
            assistantLine(input: 100, output: 0, cacheRead: 0, timestamp: ts1),
            assistantLine(input: 40, output: 0, cacheRead: 0, timestamp: ts2),
        ])
        let svc = ClaudeCodeUsageService()
        svc.fullScan()
        XCTAssertEqual(svc.hourlyData[DateHelper.localHourKey(from: ts1)]?.tokens, 100)
        XCTAssertEqual(svc.hourlyData[DateHelper.localHourKey(from: ts2)]?.tokens, 40)
    }

    func testSkipsNonAssistantAndZeroTokenLines() {
        let ts = "2026-07-10T12:00:00.000Z"
        let userLine = "{\"type\":\"user\",\"message\":{\"usage\":{\"input_tokens\":999," +
                       "\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}," +
                       "\"timestamp\":\"\(ts)\"}"
        let zeroLine = assistantLine(input: 0, output: 0, cacheRead: 0, timestamp: ts)   // tokens==0 → 跳过
        let realLine = assistantLine(input: 50, output: 0, cacheRead: 0, timestamp: ts)

        writeSession(project: "p1", session: "s1.jsonl", lines: [userLine, zeroLine, realLine])
        let svc = ClaudeCodeUsageService()
        svc.fullScan()

        // 只 realLine 计入：user 被 type 过滤，zero 被 tokens>0 过滤
        let key = DateHelper.localDateKey(from: ts)
        XCTAssertEqual(svc.dailyData[key]?.tokens, 50)
        XCTAssertEqual(svc.dailyData[key]?.messages, 1)
    }

    func testMultiDateAggregation() {
        let ts1 = "2026-07-09T22:00:00.000Z"
        let ts2 = "2026-07-10T22:00:00.000Z"   // 不同 UTC 日 → 不同本地日 key
        writeSession(project: "p1", session: "s1.jsonl", lines: [
            assistantLine(input: 100, output: 0, cacheRead: 0, timestamp: ts1),
            assistantLine(input: 200, output: 0, cacheRead: 0, timestamp: ts2),
        ])
        let svc = ClaudeCodeUsageService()
        svc.fullScan()
        XCTAssertEqual(svc.dailyData[DateHelper.localDateKey(from: ts1)]?.tokens, 100)
        XCTAssertEqual(svc.dailyData[DateHelper.localDateKey(from: ts2)]?.tokens, 200)
    }

    func testEmptyProjectsDir_noCrash() {
        let svc = ClaudeCodeUsageService()
        svc.fullScan()
        XCTAssertTrue(svc.dailyData.isEmpty)
    }
}
