#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor final class UserContentTests: XCTestCase {
    func testNotificationPreferencesPersistWithoutDeletingContent() {
        let name = "NotificationPreferenceTests." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppNotificationPreferences(defaults: defaults)
        var news = TokenClockNotification(kind: .news, title: "", message: "")
        XCTAssertTrue(preferences.allows(news))
        preferences.set(.news, enabled: false)
        XCTAssertFalse(preferences.allows(news))
        XCTAssertTrue(preferences.allows(.notebook))
        let restored = AppNotificationPreferences(defaults: defaults)
        XCTAssertFalse(restored.allows(news))
        restored.setEnabled(false)
        XCTAssertFalse(restored.allows(.notebook))
        news.subscriptionAccountID = "account"
        XCTAssertEqual(NotificationCategory.category(for: news), .billing)
    }
    func testNotificationFiltersKeepNewsNotesAndUpdatesSeparate() {
        let news = TokenClockNotification(kind: .news, title: "", message: "")
        let note = TokenClockNotification(kind: .notebookReminder, title: "", message: "")
        let update = TokenClockNotification(kind: .releaseUpdate, title: "", message: "")
        XCTAssertTrue(NotificationPanelFilter.news.includes(news))
        XCTAssertFalse(NotificationPanelFilter.news.includes(note))
        XCTAssertTrue(NotificationPanelFilter.notebook.includes(note))
        XCTAssertTrue(NotificationPanelFilter.updates.includes(update))
        XCTAssertTrue(NotificationPanelFilter.all.includes(update))
    }
    func testReadingNewsNoticesClearsTheBadgeEvenWhenDigestIsHiddenAndSurvivesRefresh() throws {
        let name="NoticeReadTests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let center=UserContentCenter(defaults:defaults,notebookURL:dir.appendingPathComponent("notes.json"))
        center.news.isPresentationVisible={false}
        let entries=[AilyreFeedEntry(id:"notice-a",title:"A",summary:"",url:URL(string:"https://www.ailyre.com/news/")!,publishedAt:nil),
                     AilyreFeedEntry(id:"notice-b",title:"B",summary:"",url:URL(string:"https://www.ailyre.com/news/")!,publishedAt:nil)]
        center.news.ingest(entries,now:Date())
        center.news.markAllRead() // A hidden digest must still not consume news itself.
        XCTAssertEqual(center.news.unreadCount,2)
        center.markRead(center.notices().filter { $0.newsItemID == "notice-a" })
        XCTAssertEqual(center.news.unreadCount,1)
        center.markRead(center.notices())
        XCTAssertEqual(center.news.unreadCount,0)
        XCTAssertTrue(center.notices().allSatisfy(\.isRead))
        center.news.ingest(entries,now:Date())
        XCTAssertEqual(center.news.unreadCount,0)
        let restored=AilyreNewsService(defaults:defaults)
        XCTAssertEqual(restored.unreadCount,0)
        center.news.ingest(entries+[.init(id:"new",title:"New",summary:"",url:entries[0].url,publishedAt:nil)],now:Date())
        XCTAssertEqual(center.news.unreadCount,1)
        center.stop()
    }

}
#endif
