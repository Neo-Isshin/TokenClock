#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor final class QuickToolPreferencesTests: XCTestCase {
    func testDragAndArrowOrderSurviveRelaunchWithoutEnablingHiddenTools() {
        let name="QuickOrderTests."+UUID().uuidString,store=UserDefaults(suiteName:name)!
        defer {store.removePersistentDomain(forName:name)}
        let prefs=QuickToolPreferences(defaults:store)
        prefs.toggle(.local)
        prefs.move(.notebook,to:.model)
        XCTAssertEqual(prefs.order.first,.notebook)
        prefs.move(.quota,by:-1)
        let saved=prefs.order
        prefs.move(.share,to:.model)
        XCTAssertEqual(prefs.order,saved)
        XCTAssertFalse(prefs.order.contains(.local))
        XCTAssertEqual(QuickToolPreferences(defaults:store).order,saved)
    }
    func testOldDefaultMigrationRunsOnceAndDoesNotUndoLaterVisibilityChoices() {
        let name="QuickMigrationTests."+UUID().uuidString,store=UserDefaults(suiteName:name)!
        defer {store.removePersistentDomain(forName:name)}
        store.set(["model","network","local","quota"],forKey:"toolbox.quickOrder")
        let prefs=QuickToolPreferences(defaults:store)
        XCTAssertEqual(prefs.order,QuickToolPreferences.defaults)
        prefs.toggle(.history);prefs.toggle(.notebook)
        XCTAssertEqual(prefs.order,[.model,.network,.local,.quota])
        XCTAssertEqual(QuickToolPreferences(defaults:store).order,[.model,.network,.local,.quota])
        prefs.order=[]
        XCTAssertTrue(QuickToolPreferences(defaults:store).order.isEmpty)
    }
}
#endif
