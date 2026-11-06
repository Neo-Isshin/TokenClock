#if os(macOS)
import CoreGraphics
import XCTest
@testable import TokenClock

final class DialOcclusionTests: XCTestCase {
    private let dial = CGRect(x: 0, y: 0, width: 200, height: 200)
    private func fraction(_ rectangles: [CGRect]) throws -> Double {
        try XCTUnwrap(DialOcclusion.coveredFraction(dial: dial, occluders: rectangles))
    }

    func testTransparentCornersAndRealWindowMargins() {
        XCTAssertEqual(DialOcclusion.transparentFraction(windowSize: CGSize(width: 200, height: 200), diameter: 200), 1 - .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(DialOcclusion.transparentFraction(windowSize: CGSize(width: 320, height: 240), diameter: 240), 1 - .pi * 240 / (4 * 320), accuracy: 1e-12)
        XCTAssertEqual(DialOcclusion.dialBounds(in: CGRect(x: 10, y: 20, width: 320, height: 240), diameter: 240),
                       CGRect(x: 50, y: 20, width: 240, height: 240))
    }

    func testEmptyFullHalfAndTransparentCornerCoverage() throws {
        XCTAssertEqual(try fraction([]), 0)
        XCTAssertEqual(try fraction([dial]), 1, accuracy: 1e-12)
        XCTAssertEqual(try fraction([CGRect(x: 0, y: 0, width: 100, height: 200)]), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try fraction([CGRect(x: 0, y: 0, width: 20, height: 20)]), 0, accuracy: 1e-12)
    }

    func testOverlappingWindowsAreCountedOnlyOnce() throws {
        let left = CGRect(x: 0, y: 0, width: 100, height: 200)
        let top = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(try fraction([left, left]), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try fraction([left, top]), 0.75, accuracy: 1e-12)
    }

    func testCircleArcIntegrationForInteriorSquareAndClippedBand() throws {
        XCTAssertEqual(try fraction([CGRect(x: 50, y: 50, width: 100, height: 100)]), 1 / .pi, accuracy: 1e-12)
        let expected = 2 * (0.5 * sqrt(0.75) + asin(0.5)) / .pi
        XCTAssertEqual(try fraction([CGRect(x: 0, y: 50, width: 130, height: 100),
                                    CGRect(x: 70, y: 50, width: 130, height: 100)]), expected, accuracy: 1e-12)
    }

    func testEightyFivePercentDecisionUsesCircleArea() throws {
        // Covering 80% of the circle's enclosing square covers about 85.76% of its area.
        let covered = try fraction([CGRect(x: 0, y: 0, width: 160, height: 200)])
        XCTAssertEqual(covered, 0.5 + (asin(0.6) + 0.6 * 0.8) / .pi, accuracy: 1e-12)
        XCTAssertTrue(DialOcclusion.shouldShow(hidden: false, coveredFraction: covered))
        XCTAssertFalse(DialOcclusion.shouldShow(hidden: false, coveredFraction: 0.8499))
        XCTAssertTrue(DialOcclusion.shouldShow(hidden: false, coveredFraction: 0.85))
        XCTAssertTrue(DialOcclusion.shouldShow(hidden: true, coveredFraction: 0))
        XCTAssertTrue(DialOcclusion.shouldShow(hidden: false, coveredFraction: nil))
    }

    func testCoordinatesAboveAndLeftOfPrimaryScreenAndScaleInvariance() throws {
        XCTAssertEqual(DialOcclusion.cgRect(from: CGRect(x: -200, y: 1_200, width: 320, height: 240), primaryTop: 1_080),
                       CGRect(x: -200, y: -360, width: 320, height: 240))
        let translated = CGRect(x: -400, y: -300, width: 400, height: 400)
        let actual = try XCTUnwrap(DialOcclusion.coveredFraction(dial: translated,
            occluders: [CGRect(x: -400, y: -300, width: 200, height: 400)]))
        XCTAssertEqual(actual, 0.5, accuracy: 1e-12)
    }

    func testOnlyWindowsAboveTheClockContributeAndAlphaZeroIsIgnored() throws {
        func window(_ id: Int, rect: CGRect, alpha: Double = 1) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height]]
        }
        let list = [window(1, rect: dial, alpha: 0), window(2, rect: CGRect(x: 0, y: 0, width: 100, height: 200)),
                    window(42, rect: dial), window(3, rect: dial)]
        XCTAssertEqual(try XCTUnwrap(DialOcclusion.coveredFraction(dial: dial, windowNumber: 42, windows: list)), 0.5, accuracy: 1e-12)
        XCTAssertNil(DialOcclusion.coveredFraction(dial: dial, windowNumber: 99, windows: list))
    }
}
#endif
