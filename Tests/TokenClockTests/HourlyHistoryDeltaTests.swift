import Foundation
import XCTest
#if os(macOS)
import SQLite3
#else
import CSQLite
#endif
@testable import TokenClock

final class HourlyHistoryDeltaTests: XCTestCase {
    func testIdenticalSnapshotsDoNotCommitAndChangedOrRemovedHoursStayProviderScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.sqlite")
        let store = HourlyHistoryStore(path: path), day = DateHelper.todayKey()
        var observer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path, &observer, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(observer) }
        func version() throws -> Int32 {
            var query: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(observer, "PRAGMA data_version", -1, &query, nil), SQLITE_OK)
            defer { sqlite3_finalize(query) }
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            return sqlite3_column_int(query, 0)
        }
        func hour(_ value: Int, cost: Double = 0.5) -> HourlyUsage {
            var hour = HourlyUsage(tokens: value, messages: 1)
            hour.recordMetadata(tokens: value, cache: 30, model: "gpt-6-astra", cost: CostEstimate(value: cost))
            return hour
        }
        let initial = [day + "-01": hour(10), day + "-02": hour(20)]
        store.replace(tool: "Codex", hours: initial, force: true)
        let saved = try version()
        for _ in 0..<3 { store.replace(tool: "Codex", hours: initial, force: true) }
        XCTAssertEqual(try version(), saved, "Unchanged snapshots must not write a new database version")
        store.replace(tool: "Claude Code", hours: [day + "-01": hour(100)], force: true)
        store.replace(tool: "Codex", hours: [day + "-02": hour(20, cost: 0.75)], force: true)
        let result = store.query(day: day)
        XCTAssertEqual(result.flatMap(\.tools).filter { $0.name == "Codex" }.map(\.tokens), [20])
        XCTAssertEqual(result.flatMap(\.tools).filter { $0.name == "Claude Code" }.map(\.tokens), [100])
        XCTAssertEqual(result.last?.tools.first?.cost.value ?? 0, 0.75, accuracy: 0.000001)
        let changedVersion = try version()
        store.replace(tool: "Codex", hours: [:], force: true)
        XCTAssertEqual(try version(), changedVersion, "An unavailable/empty source must not erase saved history")
        let reopened = HourlyHistoryStore(path: path)
        XCTAssertEqual(reopened.query(day: day).reduce(0) { $0 + $1.totalTokens }, 120)
    }

    func testConcurrentProviderSnapshotsAreCommittedAtomicallyWithoutCrossProviderDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HourlyHistoryStore(path: root.appendingPathComponent("history.sqlite")), day = DateHelper.todayKey()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            var hour = HourlyUsage(tokens: index + 1, messages: 1)
            hour.recordMetadata(tokens: index + 1, cache: 0, model: "gpt-6-astra")
            store.replace(tool: "Provider \(index)", hours: [day + "-03": hour], force: true)
            store.replace(tool: "Provider \(index)", hours: [day + "-03": hour], force: true)
        }
        let hours = store.query(day: day)
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(hours[0].tools.count, 24)
        XCTAssertEqual(hours[0].totalTokens, (1...24).reduce(0, +))
    }
}
