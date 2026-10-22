import XCTest
@testable import TokenClock

final class MovedUsagePathsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenclock-moved-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var timestamp: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10)) }
    private func write(_ path: String, rows: [[String: Any]]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")+"\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    private func claudeRow(id: String = "message-1") -> [String: Any] {
        ["type":"assistant", "timestamp": timestamp, "message":["id":id,"model":"claude-sonnet-4-5","usage":["input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":10,"cache_read_input_tokens":40]]]
    }
    func testCodexSessionDirectoriesSymlinkedToSSDRemainReadableAndDeduplicated() throws {
        let id="00000000-1111-2222-3333-444444444444"
        try write("ssd/sessions/2026/10/20/rollout-2026-10-20T00-00-00-\(id).jsonl", rows:[
            ["type":"session_meta","timestamp":timestamp,"payload":["id":id,"timestamp":timestamp]],
            ["type":"turn_context","timestamp":timestamp,"payload":["model":"gpt-6.1-sol"]],
            ["type":"event_msg","timestamp":timestamp,"payload":["type":"token_count","info":[
                "last_token_usage":["input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120],
                "total_token_usage":["input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120]]]]])
        let home=root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for name in ["sessions","archived_sessions"] {
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: root.appendingPathComponent("ssd/sessions"))
        }
        let service=CodexUsageService(codexHome: home.path);service.fullScan();service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens,80)
        XCTAssertEqual(service.todayUsage().messages,1)
        XCTAssertEqual(service.todayCacheReadTokens(),40)
    }
    func testClaudeLinkedProjectsAndLocalCoworkReceiptsWithoutDoubleCounting() throws {
        try write("ssd/projects/project/session-1.jsonl",rows:[claudeRow()])
        let home=root.appendingPathComponent("claude"), desktop=root.appendingPathComponent("desktop")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("projects"), withDestinationURL: root.appendingPathComponent("ssd/projects"))
        try write("desktop/local-agent-mode-sessions/org/user/local_one/.claude/projects/project/session-1.jsonl",rows:[claudeRow()])
        try write("desktop/local-agent-mode-sessions/org/user/local_two/.claude/projects/project/session-2.jsonl",rows:[claudeRow(id:"message-2")])
        XCTAssertEqual(ClaudeDesktopData.projectRoots(in: [desktop.path]).count, 2)
        let service=ClaudeCodeUsageService(claudeHome:home.path,desktopHomes:[desktop.path])
        service.fullScan();service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens,260)
        XCTAssertEqual(service.todayUsage().messages,2)
        XCTAssertEqual(service.todaySessions().count,2)
        XCTAssertTrue(service.todaySessions().contains { $0.source == "Cowork (local)" })
    }
    func testChangingConfiguredPathAppliesWithoutRecreatingReaders() throws {
        let defaults=UserDefaults.standard
        var arguments=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        let previous=arguments
        defer { defaults.setVolatileDomain(previous,forName:UserDefaults.argumentDomain) }
        try write("first/projects/project/a.jsonl",rows:[claudeRow()])
        try write("second/projects/project/b.jsonl",rows:[claudeRow(),claudeRow(id:"second")])
        arguments[SettingsKey.claudeCodePath.rawValue]=root.appendingPathComponent("first").path
        defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
        let service=ClaudeCodeUsageService(desktopHomes:[]);service.fullScan()
        XCTAssertEqual(service.todayUsage().messages,1)
        arguments[SettingsKey.claudeCodePath.rawValue]=root.appendingPathComponent("second").path
        defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
        service.incrementalScan()
        XCTAssertEqual(service.todayUsage().messages,2)
        XCTAssertEqual(service.todayUsage().tokens,260)
    }
    func testExplicitDesktopDirectoryReadsReceiptsButNotChatOrMetadata() throws {
        try write("desktop/local-agent-mode-sessions/org/user/local_one/.claude/projects/project/local-session.jsonl", rows:[claudeRow()])
        try write("desktop/claude-code-sessions/org/user/local_metadata.json", rows:[["title":"metadata only","tokens":900000]])
        try write("desktop/chat/session.jsonl", rows:[["type":"assistant","text":"No token receipt"]])
        let service=ClaudeCodeUsageService(claudeHome:root.appendingPathComponent("desktop").path)
        service.fullScan();service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens,130)
        XCTAssertEqual(service.todayUsage().messages,1)
        XCTAssertEqual(service.todaySessions().count,1)
    }
    func testCodexPathChangesApplyWithoutRecreatingReader() throws {
        let defaults=UserDefaults.standard
        var arguments=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        let previous=arguments
        defer { defaults.setVolatileDomain(previous,forName:UserDefaults.argumentDomain) }
        let stamp=timestamp
        for (home,input) in [("first",100),("second",200)] {
            try write("\(home)/sessions/rollout-2026-10-20T00-00-00-00000000-1111-2222-3333-444444444444.jsonl",rows:[
                ["type":"turn_context","timestamp":stamp,"payload":["model":"gpt-6.1-sol"]],
                ["type":"event_msg","timestamp":stamp,"payload":["type":"token_count","info":[
                    "last_token_usage":["input_tokens":input,"cached_input_tokens":0,"output_tokens":20,"total_tokens":input+20],
                    "total_token_usage":["input_tokens":input,"cached_input_tokens":0,"output_tokens":20,"total_tokens":input+20]]]]])
        }
        arguments[SettingsKey.codexPath.rawValue]=root.appendingPathComponent("first").path
        defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
        let service=CodexUsageService();service.fullScan()
        XCTAssertEqual(service.todayUsage().tokens,120)
        arguments[SettingsKey.codexPath.rawValue]=root.appendingPathComponent("second").path
        defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
        service.incrementalScan()
        XCTAssertEqual(service.todayUsage().tokens,220)
        XCTAssertEqual(service.todayUsage().messages,1)
    }
    func testRealMovedCodexLogsWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_MOVED_CODEX_TESTS"] == "1" else { throw XCTSkip("Opt in to read local Codex usage") }
        let service=CodexUsageService();service.fullScan()
        XCTAssertGreaterThan(service.todayUsage().messages,0)
        XCTAssertGreaterThan(service.todayUsage().tokens,0)
        print("Codex migrated logs: messages=\(service.todayUsage().messages), tokens=\(service.todayUsage().tokens)")
    }
}
