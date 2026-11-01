import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import TokenClock

final class GlassQuotaRingTests: XCTestCase {
    private func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.deviceRGB)!
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    func testOuterAndInnerRingsAdaptToBlackWhiteAndCustomText() throws {
        let inks: [NSColor] = [.black, .white, NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1),
                              NSColor(srgbRed: 0.3, green: 0.2, blue: 0.7, alpha: 1)]
        for palette in [GlassQuotaRingPalette.cool, .warm] {
            for ink in inks {
                let expected = 0.10 + 0.72 * luminance(ink)
                let colors = palette.colors(contrastColor: ink)
                XCTAssertEqual(colors.count, 7)
                XCTAssertEqual(colors.first, colors.last)
                XCTAssertEqual(luminance(colors[0]), expected, accuracy: 0.01)
                XCTAssertEqual(luminance(NSColor(palette.innerColor(contrastColor: ink))), expected, accuracy: 0.01)
                let levels = colors.map(luminance)
                XCTAssertGreaterThan((levels.max() ?? 0) - (levels.min() ?? 0), 0.12,
                    "A rotating palette must retain visible light/dark bands, not just hue differences")
                XCTAssertTrue(levels.allSatisfy { abs($0 - expected) < 0.11 })
            }
            XCTAssertNotEqual(palette.colors(contrastColor: inks[2]), palette.colors(contrastColor: inks[1]))
        }
    }

    func testAdaptiveRingsKeepColdWarmIdentityAndContrastAtBothTextExtremes() throws {
        for ink in [NSColor.black, .white] {
            for color in GlassQuotaRingPalette.cool.colors(contrastColor: ink) {
                let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(rgb.blueComponent, rgb.redComponent)
            }
            for color in GlassQuotaRingPalette.warm.colors(contrastColor: ink) {
                let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(rgb.redComponent, rgb.blueComponent)
            }
            for palette in [GlassQuotaRingPalette.cool, .warm] {
                for color in palette.colors(contrastColor: ink) {
                    let level = luminance(color)
                    let contrast = ink == .black ? 1.05 / (level + 0.05) : (level + 0.05) / 0.05
                    XCTAssertGreaterThan(contrast, 4.5)
                }
            }
        }
    }

    @MainActor func testNativeRingUpdatesWhenOnlyTextColourChanges() throws {
        let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 29, height: 29))
        view.configure(remaining: 8, lineWidth: 2.5, palette: .warm, slot: 1, contrastColor: .black, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let chroma = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first)
        let gradient = try XCTUnwrap(chroma.sublayers?.first as? CAGradientLayer)
        let oldColors = try XCTUnwrap(gradient.colors as? [CGColor])
        view.configure(remaining: 8, lineWidth: 2.5, palette: .warm, slot: 1, contrastColor: .white, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let newColors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertNotEqual(oldColors, newColors)
        XCTAssertEqual(newColors, GlassQuotaRingPalette.warm.colors(contrastColor: .white).map(\.cgColor))
        XCTAssertEqual((chroma.mask?.animation(forKey: "tokenclock.quota.path") as? CAKeyframeAnimation)?.duration, 10)
    }

    func testClockUsesTextColourForPercentAndBothRingLayers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TokenClock/Views/ClockContentView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("quotaPercentColor"))
        XCTAssertTrue(source.contains("palette.innerColor(contrastColor: ink)") && source.contains("let ink = NSColor(viewModel.effectiveDialPrimary)"))
        XCTAssertTrue(source.contains("contrastColor: viewModel.effectiveDialPrimary"))
        let number = try XCTUnwrap(source.range(of: "Text(centerLabel.text)"))
        let suffix = String(source[number.lowerBound...].prefix(650))
        XCTAssertTrue(suffix.contains(".foregroundColor(viewModel.effectiveDialPrimary)"))
        XCTAssertTrue(suffix.contains("weight: .bold"))
        XCTAssertTrue(suffix.contains("Text(\"%\")"))
        XCTAssertTrue(suffix.contains("weight: .regular"))
    }

    func testCoolAndWarmFamiliesRemainDistinctInBothAppearances() throws {
        for dark in [false, true] {
            let cool = GlassQuotaRingPalette.cool.colors(dark: dark)
            let warm = GlassQuotaRingPalette.warm.colors(dark: dark)
            XCTAssertEqual(cool.count, 7)
            XCTAssertEqual(cool.first, cool.last)
            XCTAssertEqual(warm.first, warm.last)
            for color in cool {
                let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(rgb.blueComponent, rgb.redComponent)
            }
            for color in warm {
                let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(rgb.redComponent, rgb.greenComponent)
                XCTAssertGreaterThan(rgb.redComponent, rgb.blueComponent)
            }
        }
    }

    func testSpotlightThickensLocallyWithoutMovingTheCircularCentreline() {
        let ring = GlassQuotaRingGeometry(diameter: 29, lineWidth: 2.5, remaining: 72)
        let position = 2 * Double.pi * ring.fraction * 0.5
        XCTAssertEqual(ring.width(at: position, phase: 0.5), ring.lineWidth + ring.gain, accuracy: 0.001)
        XCTAssertEqual(ring.width(at: 0, phase: 0.5), ring.lineWidth, accuracy: 0.001)
        XCTAssertEqual(ring.width(at: position, phase: 0), ring.lineWidth, accuracy: 0.001)
        XCTAssertEqual(ring.width(at: position, phase: 1), ring.lineWidth, accuracy: 0.001)
        for step in 0...24 {
            let point = ring.lightPosition(phase: Double(step) / 24)
            XCTAssertEqual(hypot(point.x - ring.center.x, point.y - ring.center.y), ring.radius, accuracy: 0.001)
        }
    }

    func testAllQuotaBoundariesFitSingleAndDoubleRingSizesAndKeepCentreClear() {
        for (size, width) in [(CGFloat(29), CGFloat(2.5)), (35, 3), (43.75, 3.75)] {
            for remaining in [0, 0.01, 1, 53, 99.99, 100] {
                let ring = GlassQuotaRingGeometry(diameter: size, lineWidth: width, remaining: remaining)
                for step in 0...24 {
                    let path = ring.band(phase: Double(step) / 24)
                    if remaining == 0 { XCTAssertTrue(path.isEmpty); continue }
                    let box = path.boundingBoxOfPath
                    XCTAssertGreaterThanOrEqual(box.minX, -0.001)
                    XCTAssertGreaterThanOrEqual(box.minY, -0.001)
                    XCTAssertLessThanOrEqual(box.maxX, size + 0.001)
                    XCTAssertLessThanOrEqual(box.maxY, size + 0.001)
                    XCTAssertFalse(path.contains(ring.center))
                }
            }
        }
    }

    func testFullQuotaHasNoGapAndEmptyQuotaHasNoColouredArc() {
        let full = GlassQuotaRingGeometry(diameter: 35, lineWidth: 3, remaining: 100)
        for step in 0..<16 {
            let angle = Double(step) * 2 * .pi / 16
            let point = CGPoint(x: full.center.x + CGFloat(cos(angle)) * full.radius,
                                y: full.center.y + CGFloat(sin(angle)) * full.radius)
            XCTAssertTrue(full.band(phase: 0.5).contains(point))
        }
        for remaining in [-1, 0, Double.nan, .infinity] {
            XCTAssertTrue(GlassQuotaRingGeometry(diameter: 35, lineWidth: 3, remaining: remaining).band(phase: 0).isEmpty)
        }
    }

    @MainActor func testNativeAnimationsAreScopedStableAndPausedWithoutAVisibleWindow() throws {
        let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 29, height: 29))
        view.configure(remaining: 72, lineWidth: 2.5, palette: .cool, slot: 0, contrastColor: .black, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let motion = try XCTUnwrap(view.layer?.sublayers?.first)
        let chroma = try XCTUnwrap(motion.sublayers?.first)
        let mask = try XCTUnwrap(chroma.mask)
        let animation = try XCTUnwrap(mask.animation(forKey: "tokenclock.quota.path") as? CAKeyframeAnimation)
        XCTAssertEqual(animation.values?.count, 25)
        XCTAssertEqual(animation.duration, 10)
        XCTAssertEqual(motion.speed, 0)
        XCTAssertNil(view.hitTest(.zero))
        let begin = animation.beginTime
        view.configure(remaining: 72, lineWidth: 2.5, palette: .cool, slot: 0, contrastColor: .black, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(mask.animation(forKey: "tokenclock.quota.path")?.beginTime, begin)
        let color = try XCTUnwrap(chroma.sublayers?.first)
        XCTAssertEqual(color.animationKeys(), ["tokenclock.quota.transform.rotation.z"])
        // Colour rotation belongs to the colour field, never to the quota mask.
        XCTAssertNil(chroma.animationKeys())
        XCTAssertEqual(mask.animationKeys(), ["tokenclock.quota.path"])
    }

    @MainActor func testReducedMotionAndZeroQuotaHaveNoNativeAnimations() {
        for (remaining, reduced) in [(72.0, true), (0, false)] {
            let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 35, height: 35))
            view.configure(remaining: remaining, lineWidth: 3, palette: .warm, slot: 1, contrastColor: .white, reduceMotion: reduced)
            view.layoutSubtreeIfNeeded()
            func check(_ layer: CALayer) {
                XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
                if let mask = layer.mask { check(mask) }
                for child in layer.sublayers ?? [] { check(child) }
            }
            if let layer = view.layer { check(layer) }
        }
    }

    @MainActor func testPreviewHighlightAndTravellingFilmSurviveBlackWhiteAndCustomInk() throws {
        for ink in [NSColor.black, .white, NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)] {
            let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 29, height: 29))
            view.configure(remaining: 87, lineWidth: 2.5, palette: .cool, slot: 0,
                           contrastColor: ink, reduceMotion: false)
            view.layoutSubtreeIfNeeded()
            let motion = try XCTUnwrap(view.layer?.sublayers?.first)
            let film = try XCTUnwrap(motion.sublayers?[1] as? CAGradientLayer)
            let light = try XCTUnwrap(motion.sublayers?.last?.sublayers?.first as? CAGradientLayer)
            let highlightColors = try XCTUnwrap(light.colors as? [CGColor])
            let filmColors = try XCTUnwrap(film.colors as? [CGColor])
            XCTAssertEqual(highlightColors[0].alpha, 0.86, accuracy: 0.001)
            XCTAssertEqual(highlightColors[1].alpha, 0.46, accuracy: 0.001)
            XCTAssertEqual(filmColors[1].alpha, 0.35, accuracy: 0.001)
            for key in ["startPoint", "endPoint"] {
                let animation = try XCTUnwrap(film.animation(forKey: "tokenclock.quota.\(key)") as? CAKeyframeAnimation)
                let points = try XCTUnwrap(animation.values as? [NSValue])
                XCTAssertEqual(points.count, 3)
                XCTAssertNotEqual(points[0].pointValue, points[1].pointValue)
                XCTAssertEqual(points[0].pointValue, points[2].pointValue)
            }
        }
    }

    @MainActor func testSpotlightChangesRealSizePixelsNotOnlyAnimationMetadata() throws {
        let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 29, height: 29))
        view.configure(remaining: 87, lineWidth: 2.5, palette: .cool, slot: 0,
                       contrastColor: .black, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let motion = try XCTUnwrap(view.layer?.sublayers?.first)
        let chroma = try XCTUnwrap(motion.sublayers?.first)
        let film = try XCTUnwrap(motion.sublayers?[1] as? CAGradientLayer)
        let lightContainer = try XCTUnwrap(motion.sublayers?.last)
        let light = try XCTUnwrap(lightContainer.sublayers?.first)
        let mask = try XCTUnwrap(chroma.mask as? CAShapeLayer)
        let paths = try XCTUnwrap((mask.animation(forKey: "tokenclock.quota.path") as? CAKeyframeAnimation)?.values as? [CGPath])
        let positions = try XCTUnwrap((light.animation(forKey: "tokenclock.quota.position") as? CAKeyframeAnimation)?.values as? [NSValue])
        let opacities = try XCTUnwrap((light.animation(forKey: "tokenclock.quota.opacity") as? CAKeyframeAnimation)?.values as? [NSNumber])
        // Render the actual native material at two deterministic animation phases.
        // Freeze the colour wheel, isolating the visible spotlight/width change.
        let masks = try [chroma.mask, film.mask, lightContainer.mask].map { try XCTUnwrap($0 as? CAShapeLayer) }
        for layer in masks + [film, light] { layer.removeAllAnimations() }
        chroma.sublayers?.first?.removeAllAnimations()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.setFillColor(NSColor(srgbRed: 0.94, green: 0.98, blue: 1, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        for (column, index) in [0, 12].enumerated() {
            for mask in masks { mask.path = paths[index] }
            light.position = positions[index].pointValue
            light.opacity = opacities[index].floatValue
            context.saveGState()
            context.translateBy(x: CGFloat(column) * 64 + 3, y: 3)
            context.scaleBy(x: 2, y: 2)
            try XCTUnwrap(view.layer).render(in: context)
            context.restoreGState()
        }
        var changed = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let first = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let second = try XCTUnwrap(bitmap.colorAt(x: x + 64, y: y)?.usingColorSpace(.deviceRGB))
                let difference = max(abs(first.redComponent - second.redComponent),
                    abs(first.greenComponent - second.greenComponent), abs(first.blueComponent - second.blueComponent))
                if difference > 0.15 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 15, "The spotlight must visibly alter pixels at 29 pt with black Text Color")
        if let output = ProcessInfo.processInfo.environment["TOKENCLOCK_SPOTLIGHT_RENDER"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

    @MainActor func testNativeColourFieldsRenderForBothSlots() throws {
        // Actual double-slot size, rendered at Retina scale rather than relying
        // only on animation objects or an enlarged demonstration ring.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        for (index, palette) in [GlassQuotaRingPalette.cool, .warm].enumerated() {
            let view = GlassQuotaRingNSView(frame: NSRect(x: 0, y: 0, width: 29, height: 29))
            view.configure(remaining: 100, lineWidth: 2.5, palette: palette,
                           slot: index, contrastColor: .black, reduceMotion: true)
            view.layoutSubtreeIfNeeded()
            context.saveGState()
            context.translateBy(x: CGFloat(index) * 64 + 3, y: 3)
            context.scaleBy(x: 2, y: 2)
            try XCTUnwrap(view.layer).render(in: context)
            context.restoreGState()
        }
        var coloured = [0, 0]
        var visibleLevels: [[Double]] = [[], []]
        for y in 0..<64 {
            for x in 0..<128 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                let span = max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent)
                if span > 0.1 { coloured[x / 64] += 1 }
                if color.alphaComponent > 0.85 { visibleLevels[x / 64].append(luminance(color)) }
            }
        }
        XCTAssertGreaterThan(coloured[0], 100)
        XCTAssertGreaterThan(coloured[1], 100)
        for levels in visibleLevels {
            XCTAssertGreaterThan((levels.max() ?? 0) - (levels.min() ?? 0), 0.08,
                "The real-size outer arc must visibly distinguish its moving bright/dark bands")
        }
        if let output = ProcessInfo.processInfo.environment["TOKENCLOCK_RING_RENDER"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
}
