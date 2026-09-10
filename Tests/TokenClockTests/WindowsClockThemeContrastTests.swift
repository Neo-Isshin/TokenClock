#if os(Windows)
import XCTest
@testable import TokenClock

final class WindowsClockThemeContrastTests: XCTestCase {
    func testBuiltInThemeTextDefaultsRemainReadable() {
        for theme in WindowsClockTheme.allCases where theme != .custom {
            let value = theme.winTheme
            XCTAssertGreaterThanOrEqual(
                contrast(value.text_primary, over: value.dial_fill), 4.5,
                "\(theme.rawValue) primary dial text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(value.text_secondary, over: value.dial_fill), 4.5,
                "\(theme.rawValue) secondary dial text"
            )
            if value.show_numbers != 0 {
                XCTAssertGreaterThanOrEqual(
                    contrast(value.number_color, over: value.dial_fill), 4.5,
                    "\(theme.rawValue) dial numbers"
                )
            }
            XCTAssertGreaterThanOrEqual(
                contrast(value.dd_text, over: value.dd_bg), 4.5,
                "\(theme.rawValue) panel text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(value.dd_subtext, over: value.dd_bg), 4.5,
                "\(theme.rawValue) panel secondary text"
            )
        }
    }

    private func contrast(_ foreground: UInt32, over background: UInt32) -> Double {
        let bg = components(background)
        let fg = components(foreground)
        let composited = (
            fg.r * fg.a + bg.r * (1 - fg.a),
            fg.g * fg.a + bg.g * (1 - fg.a),
            fg.b * fg.a + bg.b * (1 - fg.a)
        )
        let backgroundColor = (bg.r, bg.g, bg.b)
        let lighter = max(luminance(composited), luminance(backgroundColor))
        let darker = min(luminance(composited), luminance(backgroundColor))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func components(_ color: UInt32) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            Double((color >> 16) & 0xff) / 255,
            Double((color >> 8) & 0xff) / 255,
            Double(color & 0xff) / 255,
            Double((color >> 24) & 0xff) / 255
        )
    }

    private func luminance(_ color: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channel(color.0) * 0.2126 + channel(color.1) * 0.7152 + channel(color.2) * 0.0722
    }
}
#endif
