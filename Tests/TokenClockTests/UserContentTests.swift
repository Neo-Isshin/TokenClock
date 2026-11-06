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
}
#endif
