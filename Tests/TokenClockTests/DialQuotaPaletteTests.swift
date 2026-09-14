import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class DialQuotaPaletteTests: XCTestCase {
    func testGlassQuotaColorsStayLegibleAndDistinguishableOnLightAndDarkFaces() throws {
        for ink in [Color.black, Color.white] {
            let neutral = try XCTUnwrap(NSColor(SubscriptionProvider.zhipu.glassDialQuotaColor(contrastColor: ink)).usingColorSpace(.deviceRGB))
            let codex = try XCTUnwrap(NSColor(SubscriptionProvider.codex.glassDialQuotaColor(contrastColor: ink)).usingColorSpace(.deviceRGB))
            let base = try XCTUnwrap(NSColor(ink).usingColorSpace(.deviceRGB))
            XCTAssertEqual(neutral.redComponent, base.redComponent, accuracy: 0.01)
            XCTAssertGreaterThan(codex.greenComponent - codex.redComponent, 0.15)
            if base.redComponent < 0.5 {
                XCTAssertLessThan(codex.greenComponent, 0.4)
            } else {
                XCTAssertGreaterThan(codex.redComponent, 0.5)
            }
        }
    }
}
