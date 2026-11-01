#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

final class ConcentricQuotaColorTests: XCTestCase {
    func testThreeRingLayersRemainDistinctWithBlackWhiteAndCustomInk() throws {
        for ink in [NSColor.black, .white, .systemRed, .systemBlue] {
            for palette in [GlassQuotaRingPalette.cool, .warm] {
                let middle = try XCTUnwrap(palette.concentricColor(layer: 1, contrastColor: ink).usingColorSpace(.deviceRGB))
                let inner = try XCTUnwrap(palette.concentricColor(layer: 2, contrastColor: ink).usingColorSpace(.deviceRGB))
                let distance = sqrt(pow(middle.redComponent - inner.redComponent, 2)
                    + pow(middle.greenComponent - inner.greenComponent, 2) + pow(middle.blueComponent - inner.blueComponent, 2))
                XCTAssertGreaterThan(distance, 0.18, "The two static layers need a visible hue/lightness separation")
                for color in [middle, inner] {
                    XCTAssertEqual(color.alphaComponent, 1)
                    for value in [color.redComponent, color.greenComponent, color.blueComponent] {
                        XCTAssertTrue(value.isFinite && (0...1).contains(value))
                    }
                }
            }
        }
    }
}
#endif
