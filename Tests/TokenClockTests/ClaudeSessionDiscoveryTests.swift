import Foundation
import XCTest
@testable import TokenClock

final class ClaudeSessionDiscoveryTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tc-claude-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }
    private func log(_ id: String, model: String, at date: Date = Date(), nested: Bool = false) throws -> URL {
        let path = home.appendingPathComponent("projects/project/\(nested ? "subagents/" : "")\(id).jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = [
            "type": "assistant", "sessionId": id, "timestamp": ISO8601DateFormatter().string(from: date),
            "message": ["model": model, "usage": ["input_tokens": 100, "output_tokens": 10,
                                                  "cache_read_input_tokens": 200, "cache_creation_input_tokens": 20]]
        ]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0A)
        try data.write(to: path)
        return path
    }
    private func metadata(_ file: String, _ record: [String: Any]) throws {
        let path = home.appendingPathComponent("sessions/\(file).json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: path)
    }
    func testMissingOrEmptyMetadataStillDiscoversExternalModels() throws {
        _ = try log("minimax-session", model: "MiniMax-M3")
        _ = try log("glm-session", model: "glm-5.2")
        let service = ClaudeCodeUsageService(claudeHome: home.path)
        service.fullScan()
        for _ in 0..<2 {
            let sessions = service.todaySessions()
            XCTAssertEqual(Set(sessions.map(\.rawId)), ["minimax-session", "glm-session"])
            XCTAssertEqual(Set(sessions.compactMap(\.model)), ["MiniMax-M3", "glm-5.2"])
            XCTAssertEqual(sessions.reduce(0) { $0 + $1.todayTokens }, service.todayUsage().tokens)
            XCTAssertEqual(sessions.reduce(0) { $0 + $1.todayMessages }, 2)
            XCTAssertEqual(sessions.reduce(0) { $0 + $1.cacheReadTokens }, 400)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
    }
    func testMetadataEnrichesButDoesNotCreateOrDuplicateUsage() throws {
        _ = try log("session-a", model: "glm-5.2")
        try metadata("a", ["sessionId": "session-a", "title": "Task A", "cwd": "/project/a"])
        try metadata("b", ["sessionId": "session-a", "title": "Duplicate"])
        try metadata("stale", ["sessionId": "missing-log"])
        try Data("not-json".utf8).write(to: home.appendingPathComponent("sessions/corrupt.json"))
        let service = ClaudeCodeUsageService(claudeHome: home.path)
        service.fullScan()
        let sessions = service.todaySessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.displayName, "Task A")
        XCTAssertEqual(sessions.first?.detail, "/project/a")
        XCTAssertEqual(sessions.first?.model, "glm-5.2")
        XCTAssertTrue(sessions.first?.isActive == true)
    }
    func testOldSessionsStayVisibleAndDeletedLogsAreEvicted() throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let closed = Calendar.current.startOfDay(for: Date()).addingTimeInterval(1)
        let todayLog = try log("closed", model: "MiniMax-M3", at: closed)
        _ = try log("yesterday", model: "glm-5.2", at: yesterday)
        let service = ClaudeCodeUsageService(claudeHome: home.path)
        service.fullScan()
        XCTAssertEqual(service.todaySessions().map(\.rawId), ["closed"])
        if Date().timeIntervalSince(closed) > AppConfig.Scan.activeThresholdSeconds {
            XCTAssertFalse(service.todaySessions()[0].isActive)
        }
        service.incrementalScan()
        XCTAssertEqual(service.todaySessions()[0].todayMessages, 1)
        try FileManager.default.removeItem(at: todayLog)
        service.incrementalScan()
        XCTAssertTrue(service.todaySessions().isEmpty)
    }
    func testNestedDetailsKeepTheirExistingAccountingBoundary() throws {
        _ = try log("top", model: "glm-5.2")
        _ = try log("nested", model: "MiniMax-M3", nested: true)
        let service = ClaudeCodeUsageService(claudeHome: home.path)
        service.fullScan()
        XCTAssertEqual(Set(service.todaySessions().map(\.rawId)), ["top", "nested"])
        XCTAssertEqual(service.todayUsage().tokens, 130)
        XCTAssertEqual(service.todayUsage().messages, 1)
    }
}
