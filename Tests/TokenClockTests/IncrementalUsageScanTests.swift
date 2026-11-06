import Foundation
import XCTest
@testable import TokenClock

private protocol FixtureUsageService: AnyObject {
    var dailyData: [String: DayUsage] { get }
    var hourlyData: [String: HourlyUsage] { get }
    var dailyCache: [String: Int] { get }
    func fullScan()
    func incrementalScan()
    func todayUsage() -> (tokens: Int, messages: Int, cacheRate: Double)
    func todaySessions() -> [SessionInfo]
}
extension ClaudeCodeUsageService: FixtureUsageService {}
extension OpenClawUsageService: FixtureUsageService {}

final class IncrementalUsageScanTests: XCTestCase {
    private func temporary(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }
    private func event(claude: Bool, tokens: Int, model: String = "gpt-6-astra", date: Date = Date()) throws -> Data {
        let usage: [String: Int] = claude
            ? ["input_tokens": tokens, "output_tokens": 2, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 3]
            : ["input": tokens, "output": 2, "cacheRead": 30, "cacheWrite": 3]
        return try JSONSerialization.data(withJSONObject: ["type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: date),
            "message": ["role": "assistant", "model": model, "usage": usage]], options: [.sortedKeys])
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func compare(_ live: FixtureUsageService, _ fresh: FixtureUsageService, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(live.dailyData.mapValues(\.tokens), fresh.dailyData.mapValues(\.tokens), file: file, line: line)
        XCTAssertEqual(live.dailyData.mapValues(\.messages), fresh.dailyData.mapValues(\.messages), file: file, line: line)
        XCTAssertEqual(live.dailyCache, fresh.dailyCache, file: file, line: line)
        XCTAssertEqual(live.hourlyData.mapValues(\.tokens), fresh.hourlyData.mapValues(\.tokens), file: file, line: line)
        XCTAssertEqual(live.hourlyData.mapValues(\.messages), fresh.hourlyData.mapValues(\.messages), file: file, line: line)
    }

    func testIncrementalResultsMatchColdScanAcrossAppendPartialTailRotationAndDeletion() throws {
        for claude in [true, false] {
            try temporary { root in
                let path = root.appendingPathComponent(claude ? "projects/p/shared.jsonl" : "agents/alpha/sessions/shared.jsonl")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let make: () -> any FixtureUsageService = {
                    if claude { return ClaudeCodeUsageService(claudeHome: root.path, desktopHomes: []) }
                    return OpenClawUsageService(openclawHome: root.path)
                }
                let live = make()
                func check() {
                    live.incrementalScan()
                    let fresh = make(); fresh.fullScan(); compare(live, fresh)
                    XCTAssertEqual(live.todaySessions().reduce(0) { $0 + $1.todayTokens }, fresh.todaySessions().reduce(0) { $0 + $1.todayTokens })
                    for (key, hour) in live.hourlyData {
                        let left = hour.historyTool(name: "fixture"), right = fresh.hourlyData[key]!.historyTool(name: "fixture")
                        XCTAssertEqual(left.cacheReadTokens, right.cacheReadTokens)
                        XCTAssertEqual(left.cost.value, right.cost.value, accuracy: 0.000000001)
                        XCTAssertEqual(left.sessions.map(\.id).sorted(), right.sessions.map(\.id).sorted())
                    }
                }
                let first = try event(claude: claude, tokens: 10)
                try first.write(to: path); live.fullScan()
                XCTAssertEqual(live.todayUsage().tokens, 15) // valid EOF without newline
                let next = try event(claude: claude, tokens: 20, model: "glm-5.3")
                try append(Data([10]) + next.prefix(next.count / 2), to: path); check()
                XCTAssertEqual(live.todayUsage().messages, 1)
                try append(Data(next.suffix(next.count - next.count / 2)) + Data([10]), to: path); check()
                XCTAssertEqual(live.todayUsage().tokens, 40)
                check() // a second scan cannot replay the completed tail
                let old = Date().addingTimeInterval(-86_400)
                try append(try event(claude: claude, tokens: 7, date: old) + Data([10]), to: path); check()
                let previousTime = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]!
                try (try event(claude: claude, tokens: 33) + Data([10])).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: previousTime], ofItemAtPath: path.path)
                check(); XCTAssertEqual(live.todayUsage().tokens, 38)
                let handle = try FileHandle(forWritingTo: path)
                try handle.truncate(atOffset: 0); try handle.close(); check()
                XCTAssertEqual(live.todayUsage().tokens, 0)
                try append(first + Data([10]), to: path); check()
                try FileManager.default.removeItem(at: path); check()
                XCTAssertTrue(live.dailyData.isEmpty)
            }
        }
    }

    func testLateCronMarkerRetractsEarlierUsageAndReplacementCanRemoveIt() throws {
        try temporary { root in
            let path = root.appendingPathComponent("agents/main/sessions/one.jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let event = try event(claude: false, tokens: 10) + Data([10])
            try event.write(to: path)
            let live = OpenClawUsageService(openclawHome: root.path); live.fullScan()
            XCTAssertEqual(live.todayUsage().tokens, 15)
            try append(Data(#"{"message":{"role":"user","content":"[cron:fixture scheduled task]"}}"#.utf8) + Data([10]), to: path)
            live.incrementalScan(); XCTAssertEqual(live.todayUsage().tokens, 0)
            try append(event, to: path); live.incrementalScan(); XCTAssertTrue(live.todaySessions().isEmpty)
            try event.write(to: path, options: .atomic); live.incrementalScan()
            XCTAssertEqual(live.todayUsage().tokens, 15)
        }
    }

    func testOpenClawAgentsWithSameFilenameKeepIndependentCursors() throws {
        try temporary { root in
            let a = root.appendingPathComponent("agents/alpha/sessions/shared.jsonl")
            let b = root.appendingPathComponent("agents/beta/sessions/shared.jsonl")
            for path in [a, b] { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true) }
            try (try event(claude: false, tokens: 10) + Data([10])).write(to: a)
            try (try event(claude: false, tokens: 100) + Data([10])).write(to: b)
            let live = OpenClawUsageService(openclawHome: root.path); live.fullScan()
            try append(try event(claude: false, tokens: 5) + Data([10]), to: a)
            live.incrementalScan()
            XCTAssertEqual(live.todaySessions().map(\.todayTokens).sorted(), [25, 105])
            XCTAssertEqual(live.todayUsage().tokens, 130)
        }
    }

    func testCursorReadsOnlyAppendsAndDetectsRewriteAtPriorEOF() throws {
        try temporary { root in
            let path = root.appendingPathComponent("log.jsonl")
            let first = try event(claude: true, tokens: 10) + Data([10])
            try first.write(to: path)
            var cursor = IncrementalUsageLog(), lines = 0
            XCTAssertTrue(try XCTUnwrap(cursor.read(path: path.path, matchingAny: []) { _ in lines += 1 }).reset)
            let second = try event(claude: true, tokens: 11) + Data([10])
            try append(second, to: path)
            let appendRead = try XCTUnwrap(cursor.read(path: path.path, matchingAny: []) { _ in lines += 1 })
            XCTAssertFalse(appendRead.reset); XCTAssertEqual(appendRead.fromOffset, UInt64(first.count)); XCTAssertEqual(lines, 2)
            let handle = try FileHandle(forWritingTo: path)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: second + first + second); try handle.close()
            XCTAssertTrue(try XCTUnwrap(cursor.read(path: path.path, matchingAny: []) { _ in }).reset)
            let saved = cursor.offset
            XCTAssertNil(cursor.read(path: root.appendingPathComponent("missing").path, matchingAny: []) { _ in })
            XCTAssertEqual(cursor.offset, saved)
        }
    }

    func testDirectoryIndexSeesNewNestedFilesRenamesAndRemoval() throws {
        try temporary { root in
            let index = UsageLogDirectoryIndex(); index.prepare(roots: [root.path])
            XCTAssertTrue(index.jsonlFiles(recursivelyIn: root).isEmpty)
            let nested = root.appendingPathComponent("nested/deeper/file.jsonl")
            try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: nested)
            XCTAssertEqual(index.jsonlFiles(recursivelyIn: root).map { $0.pathComponents.suffix(3).joined(separator: "/") }, ["nested/deeper/file.jsonl"])
            let renamed = nested.deletingLastPathComponent().appendingPathComponent("renamed.jsonl")
            try FileManager.default.moveItem(at: nested, to: renamed)
            XCTAssertEqual(index.jsonlFiles(recursivelyIn: root).map { $0.pathComponents.suffix(3).joined(separator: "/") }, ["nested/deeper/renamed.jsonl"])
            try FileManager.default.removeItem(at: renamed)
            XCTAssertTrue(index.jsonlFiles(recursivelyIn: root).isEmpty)
        }
    }

    func testLargeStreamKeepsFilteredRecordsAndAppendOffsetsIntact() throws {
        try temporary { root in
            let path = root.appendingPathComponent("large.jsonl")
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
            let handle = try FileHandle(forWritingTo: path)
            let line = Data(("{\"role\":\"tool\",\"text\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
            var block = Data()
            for _ in 0..<1024 { block.append(line) }
            for _ in 0..<17 { try handle.write(contentsOf: block) }
            try handle.write(contentsOf: try event(claude: true, tokens: 10) + Data([10])); try handle.close()
            var cursor = IncrementalUsageLog(), count = 0
            let needles = [Data("\"assistant\"".utf8)]
            XCTAssertNotNil(cursor.read(path: path.path, matchingAny: needles) { _ in count += 1 })
            XCTAssertEqual(count, 1)
            let oldOffset = cursor.offset
            try append(try event(claude: true, tokens: 20) + Data([10]), to: path)
            let result = try XCTUnwrap(cursor.read(path: path.path, matchingAny: needles) { _ in count += 1 })
            XCTAssertEqual(result.fromOffset, oldOffset); XCTAssertFalse(result.reset); XCTAssertEqual(count, 2)
        }
    }

    func testConcurrentSourceReplacementDoesNotAdvanceTheCommittedCursor() throws {
        try temporary { root in
            let path = root.appendingPathComponent("log.jsonl")
            let first = try event(claude: true, tokens: 10) + Data([10])
            try first.write(to: path)
            var cursor = IncrementalUsageLog()
            XCTAssertNotNil(cursor.read(path: path.path, matchingAny: []) { _ in })
            let oldOffset = cursor.offset
            try append(first, to: path)
            let replacement = try event(claude: true, tokens: 50) + Data([10])
            let failed = cursor.read(path: path.path, matchingAny: []) { _ in
                try? replacement.write(to: path, options: .atomic)
            }
            XCTAssertNil(failed); XCTAssertEqual(cursor.offset, oldOffset)
            XCTAssertTrue(try XCTUnwrap(cursor.read(path: path.path, matchingAny: []) { _ in }).reset)
        }
    }

    func testMembershipEventsInvalidateAnIndexEvenIfDirectoryTimeIsRestored() throws {
        try temporary { root in
            let first = root.appendingPathComponent("alpha.jsonl"), second = root.appendingPathComponent("bravo.jsonl")
            try Data("{}\n".utf8).write(to: first)
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
            let index = UsageLogDirectoryIndex(); index.prepare(roots: [root.path])
            XCTAssertEqual(index.children(in: root.path).map(\.lastPathComponent), ["alpha.jsonl"])
            try FileManager.default.moveItem(at: first, to: second)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
            let deadline = Date().addingTimeInterval(3)
            while index.children(in: root.path).map(\.lastPathComponent) != ["bravo.jsonl"], Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertEqual(index.children(in: root.path).map(\.lastPathComponent), ["bravo.jsonl"])
        }
    }

    func testCompleteEOFRequiresASeparatorBeforeAnotherRecord() throws {
        try temporary { root in
            let path = root.appendingPathComponent("projects/p/session.jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = try event(claude: true, tokens: 10)
            try line.write(to: path)
            let service = ClaudeCodeUsageService(claudeHome: root.path, desktopHomes: [])
            service.fullScan(); XCTAssertEqual(service.todayUsage().tokens, 15)
            try append(line + Data([10]), to: path)
            service.incrementalScan(); XCTAssertEqual(service.todayUsage().tokens, 0)
            let fresh = ClaudeCodeUsageService(claudeHome: root.path, desktopHomes: [])
            fresh.fullScan(); compare(service, fresh)
        }
    }
}
