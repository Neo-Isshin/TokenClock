import XCTest
@testable import TokenClock

/// GeminiUsageService 公式测试 —— 验证 Gemini 的 `input`(promptTokenCount) 已含 `cached`
/// (cachedContentTokenCount)，故 `total = input - cached + output + thought`。
///
/// 与 ClaudeCodeUsageServiceTests 同模式：用 PathConfig.setGeminiPath 重定向到临时 fixture，
/// 期望日期 key 用 DateHelper 就地算出，断言与时区无关。
final class GeminiUsageServiceTests: XCTestCase {

    private var tmpRoot: String!

    override func setUp() {
        super.setUp()
        tmpRoot = NSTemporaryDirectory() + "tc-gemini-test-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        PathConfig.setGeminiPath(tmpRoot)
    }

    override func tearDown() {
        PathConfig.setGeminiPath("")
        try? FileManager.default.removeItem(atPath: tmpRoot)
        super.tearDown()
    }

    /// 在 tmp/tmp/<proj>/chats/<session>.jsonl 写入若干行
    private func writeSession(project: String, session: String, lines: [String]) {
        let chatsDir = tmpRoot + "tmp/\(project)/chats/"
        try? FileManager.default.createDirectory(atPath: chatsDir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(toFile: chatsDir + session, atomically: true, encoding: .utf8)
    }

    /// 构造一条 gemini 事件行（匹配 Gemini CLI 真实 JSONL 结构）
    private func geminiLine(input: Int, output: Int, cached: Int, thought: Int? = nil,
                            timestamp: String = "2026-07-10T12:00:00.000Z") -> String {
        var tokens = "\"input\":\(input),\"output\":\(output),\"cached\":\(cached)"
        if let t = thought { tokens += ",\"thought\":\(t)" }
        return "{\"type\":\"gemini\",\"tokens\":{\(tokens)},\"timestamp\":\"\(timestamp)\"}"
    }

    func testTokenFormula_excludesCached_includesThought() {
        let ts = "2026-07-10T12:00:00.000Z"
        // fresh input=1000-800，另加 output=100、thought=50，总计 350。
        writeSession(project: "p1", session: "session-s1.jsonl", lines: [
            geminiLine(input: 1000, output: 100, cached: 800, thought: 50, timestamp: ts),
        ])
        let svc = GeminiUsageService()
        svc.fullScan()
        let key = DateHelper.localDateKey(from: ts)
        XCTAssertEqual(svc.dailyData[key]?.tokens, 350,
                       "Gemini total = input-cached+output+thought")
        XCTAssertEqual(svc.dailyCache[key], 800, "cached 仅保留为缓存命中统计")
    }

    func testTokenFormula_missingThought_defaultsZero() {
        let ts = "2026-07-10T12:00:00.000Z"
        // 无 thought 字段 → thought=0；total = 1000-800+100 = 300。
        writeSession(project: "p1", session: "session-s1.jsonl", lines: [
            geminiLine(input: 1000, output: 100, cached: 800, timestamp: ts),
        ])
        let svc = GeminiUsageService()
        svc.fullScan()
        let key = DateHelper.localDateKey(from: ts)
        XCTAssertEqual(svc.dailyData[key]?.tokens, 300, "缺 thought 时按 0 计，并扣除 cached")
    }

    func testEmptyDir_noCrash() {
        let svc = GeminiUsageService()
        svc.fullScan()
        XCTAssertTrue(svc.dailyData.isEmpty)
    }
}
