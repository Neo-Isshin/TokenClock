#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class ClockThemeContrastTests: XCTestCase {
    func testBuiltInFaceTextUsesReadableDefaultContrast() {
        for theme in ClockFaceTheme.allCases where theme != .custom {
            XCTAssertGreaterThanOrEqual(
                contrast(theme.textPrimaryColor, over: theme.dialColor), 4.5,
                "\(theme.rawValue) primary dial text"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(theme.textSecondaryColor, over: theme.dialColor), 4.5,
                "\(theme.rawValue) secondary dial text"
            )
        }
    }

    func testBuiltInPanelTextUsesReadableDefaultContrast() {
        for theme in ClockFaceTheme.allCases where theme != .custom {
            for (name, foreground) in [
                ("primary", theme.dropdownTextColor),
                ("secondary", theme.dropdownSubtextColor),
                ("header", theme.dropdownHeaderColor),
            ] {
                XCTAssertGreaterThanOrEqual(
                    contrast(foreground, over: theme.dropdownBgColor), 4.5,
                    "\(theme.rawValue) \(name) panel text"
                )
            }
        }
    }

    private func contrast(_ foreground: Color, over background: Color) -> Double {
        let bg = components(background)
        let fg = components(foreground)
        let composited = (
            fg.r * fg.a + bg.r * (1 - fg.a),
            fg.g * fg.a + bg.g * (1 - fg.a),
            fg.b * fg.a + bg.b * (1 - fg.a)
        )
        let lighter = max(luminance(composited), luminance((bg.r, bg.g, bg.b)))
        let darker = min(luminance(composited), luminance((bg.r, bg.g, bg.b)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (
            Double(resolved.redComponent), Double(resolved.greenComponent),
            Double(resolved.blueComponent), Double(resolved.alphaComponent)
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
