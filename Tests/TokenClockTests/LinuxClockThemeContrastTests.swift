#if os(Linux)
import XCTest
@testable import TokenClock

final class LinuxClockThemeContrastTests: XCTestCase {
    func testBuiltInThemeTextDefaultsRemainReadable() {
        for theme in LinuxClockTheme.builtInCases {
            XCTAssertGreaterThanOrEqual(
                contrast(theme.textPrimaryColor, over: theme.dialColor), 4.5,
                "\(theme.rawValue) primary dial text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(theme.textSecondaryColor, over: theme.dialColor), 4.5,
                "\(theme.rawValue) secondary dial text"
            )
            if theme.numberColor.alpha > 0 {
                XCTAssertGreaterThanOrEqual(
                    contrast(theme.numberColor, over: theme.dialColor), 4.5,
                    "\(theme.rawValue) dial numbers"
                )
            }
            XCTAssertGreaterThanOrEqual(
                contrast(theme.dropdownTextColor, over: theme.dropdownBackgroundColor), 4.5,
                "\(theme.rawValue) panel text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(theme.dropdownSubtextColor, over: theme.dropdownBackgroundColor), 4.5,
                "\(theme.rawValue) panel secondary text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(theme.dropdownHeaderColor, over: theme.dropdownBackgroundColor), 4.5,
                "\(theme.rawValue) panel header"
            )
        }
    }

    private func contrast(_ foreground: LinuxColor, over background: LinuxColor) -> Double {
        let composited = (
            foreground.red * foreground.alpha + background.red * (1 - foreground.alpha),
            foreground.green * foreground.alpha + background.green * (1 - foreground.alpha),
            foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha)
        )
        let bg = (background.red, background.green, background.blue)
        let lighter = max(luminance(composited), luminance(bg))
        let darker = min(luminance(composited), luminance(bg))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channel(color.0) * 0.2126 + channel(color.1) * 0.7152 + channel(color.2) * 0.0722
    }
}
#endif
