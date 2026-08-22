#if os(Windows)
import XCTest
@testable import TokenClock

final class WindowsVisualBehaviorTests: XCTestCase {
    func testQuickTextPresetChangesOnlyDetailPanelPalette() {
        var theme = WindowsClockTheme.midnight.winTheme
        let originalNumbers = theme.number_color
        let originalPrimary = theme.text_primary
        let originalSecondary = theme.text_secondary

        WindowsApp.applyDetailTextPreset(3, to: &theme)

        XCTAssertEqual(theme.number_color, originalNumbers)
        XCTAssertEqual(theme.text_primary, originalPrimary)
        XCTAssertEqual(theme.text_secondary, originalSecondary)
        XCTAssertEqual(theme.dd_text, 0xFFFFD60A)
        XCTAssertEqual(theme.dd_subtext, 0xB8FFD60A)
    }
}
#endif
