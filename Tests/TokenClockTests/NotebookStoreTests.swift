#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor final class NotebookStoreTests: XCTestCase {
    func testPlainEntriesReminderClaimsAndReadStatePersistOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json"), now = Date()
        let store = NotebookStore(url: url)
        let id = store.add(now: now)
        store.update(id, title: "Test", body: "One\n- Two")
        store.setReminder(id, now.addingTimeInterval(-60)); store.flush()
        XCTAssertTrue(store.claimDue(now: now))
        let notice = try XCTUnwrap(store.notices().first)
        XCTAssertEqual(notice.notebookEntryID, id)
        XCTAssertFalse(store.claimDue(now: now.addingTimeInterval(1)))
        let relaunched = NotebookStore(url: url)
        XCTAssertFalse(relaunched.claimDue(now: now.addingTimeInterval(30)))
        XCTAssertEqual(relaunched.notices().first?.id, notice.id)
        XCTAssertEqual(relaunched.entries.first?.body, "One\n- Two")
        relaunched.markRead(ids: [id])
        XCTAssertTrue(NotebookStore(url: url).notices().first?.isRead == true)
        relaunched.setCompleted(id, true)
        XCTAssertTrue(relaunched.notices().isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testEditingOrCancellingReminderDropsOldNoticeAndReschedules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookStore(url: directory.appendingPathComponent("notes.json")), now = Date()
        let id = store.add(); store.setReminder(id, now.addingTimeInterval(-10))
        XCTAssertTrue(store.claimDue(now: now))
        store.setReminder(id, now.addingTimeInterval(600))
        XCTAssertTrue(store.notices().isEmpty)
        XCTAssertFalse(store.claimDue(now: now))
        XCTAssertEqual(store.nextReminder, now.addingTimeInterval(600))
        store.setReminder(id, nil)
        XCTAssertNil(store.nextReminder)
        store.delete(id); store.flush()
        XCTAssertTrue(store.entries.isEmpty)
    }
    func testSummaryPrioritizesRemindersAndExcludesCompletedEntries() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=NotebookStore(url:directory.appendingPathComponent("notes.json"))
        let untimed=store.add(),later=store.add(),earlier=store.add(),completed=store.add()
        store.setReminder(later,Date(timeIntervalSince1970:2000))
        store.setReminder(earlier,Date(timeIntervalSince1970:1000))
        store.setReminder(completed,Date(timeIntervalSince1970:500));store.setCompleted(completed,true)
        XCTAssertEqual(store.pendingSummaryEntries.map(\.id),[earlier,later,untimed])
        store.setCompleted(earlier,true)
        XCTAssertEqual(store.pendingSummaryEntries.map(\.id),[later,untimed])
        store.flush()
    }
    func testCorruptOriginalIsBackedUpBeforeWritingNewEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("notes.json"), original = Data("unreadable-original".utf8)
        try original.write(to: url)
        let store = NotebookStore(url: url); XCTAssertFalse(store.errorMessage.isEmpty)
        store.add(); store.flush()
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("notebook-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    }
}
#endif
