import XCTest
@testable import TokenClock

/// QwenCodeUsageService 公式测试 —— 验证 `usageMetadata` 分支：
/// `promptTokenCount` 已含 `cachedContentTokenCount`，故
/// `total = prompt + candidates + thoughts`（**不含 cached**，否则双计）。
/// （gemini-CLI 分支的公式与 GeminiUsageService 相同，由 GeminiUsageServiceTests 覆盖。）
final class QwenCodeUsageServiceTests: XCTestCase {

    private var tmpRoot: String!

    override func setUp() {
        super.setUp()
        tmpRoot = NSTemporaryDirectory() + "tc-qwen-test-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        PathConfig.setQwenPath(tmpRoot)
    }

    override func tearDown() {
        PathConfig.setQwenPath("")
        try? FileManager.default.removeItem(atPath: tmpRoot)
        super.tearDown()
    }

    /// 在 tmp/projects/<proj>/chats/<session>.jsonl 写入若干行
    @discardableResult
    private func writeSession(project: String, session: String, lines: [String]) {
        let chatsDir = tmpRoot + "projects/\(project)/chats/"
        try? FileManager.default.createDirectory(atPath: chatsDir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(toFile: chatsDir + session, atomically: true, encoding: .utf8)
    }

    /// usageMetadata 格式事件行（Gemini API 原生结构）
    private func usageLine(prompt: Int, candidates: Int, thoughts: Int, cached: Int,
                           timestamp: String = "2026-07-10T12:00:00.000Z") -> String {
        let usage = "\"promptTokenCount\":\(prompt),\"candidatesTokenCount\":\(candidates)," +
                    "\"thoughtsTokenCount\":\(thoughts),\"cachedContentTokenCount\":\(cached)"
        return "{\"usageMetadata\":{\(usage)},\"timestamp\":\"\(timestamp)\"}"
    }

    func testUsageMetadata_excludesCached() {
        let ts = "2026-07-10T12:00:00.000Z"
        // prompt=1000（已含 cached=800）+ candidates=100 + thoughts=50 = 1150（非 1950）
        writeSession(project: "p1", session: "session-s1.jsonl", lines: [
            usageLine(prompt: 1000, candidates: 100, thoughts: 50, cached: 800, timestamp: ts),
        ])
        let svc = QwenCodeUsageService()
        svc.fullScan()
        let key = DateHelper.localDateKey(from: ts)
        XCTAssertEqual(svc.dailyData[key]?.tokens, 1150,
                       "usageMetadata total = prompt+candidates+thoughts；cached 已含在 prompt 内")
        XCTAssertEqual(svc.dailyCache[key], 800)
    }

    func testEmptyDir_noCrash() {
        let svc = QwenCodeUsageService()
        svc.fullScan()
        XCTAssertTrue(svc.dailyData.isEmpty)
    }
}
