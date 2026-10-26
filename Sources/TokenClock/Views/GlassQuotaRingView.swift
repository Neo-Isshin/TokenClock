import AppKit
import SwiftUI
import QuartzCore

/// The two dial slots keep distinct iridescent families throughout a rotation.
/// These are the palettes approved in quota-ring-motion-preview.html.
enum GlassQuotaRingPalette: Equatable {
    case cool, warm

    func colors(dark: Bool) -> [NSColor] {
        let values: [UInt32]
        switch (self, dark) {
        case (.cool, false): values = [0x46b9cd, 0x70b4e2, 0x8b9de4, 0xae96d9, 0x859bd9, 0x68c4bd]
        case (.cool, true): values = [0x74dfed, 0x99d0ff, 0xb1bfff, 0xd1b9f5, 0xb3c1f5, 0x98e3da]
        case (.warm, false): values = [0xd78eaf, 0xe4a08c, 0xdfb56f, 0xd7a15e, 0xd39391, 0xbd8cba]
        case (.warm, true): values = [0xf0b2cf, 0xffc6b0, 0xf7d595, 0xf3c98c, 0xf0b9b3, 0xe3b6e0]
        }
        return (values + [values[0]]).map(Self.color)
    }

    func colors(contrastColor: NSColor) -> [NSColor] {
        // Keep the ink-based contrast, but not an isoluminant colour wheel:
        // at 29 pt hue changes alone make a rotating ring look stationary.
        let bands = [0.0, 0.8, -0.6, 1.0, -0.8, 0.5, 0.0]
        let amplitude = 0.075 + 0.025 * Self.inkLightness(contrastColor)
        return colors(dark: false).enumerated().map { index, color in
            adapted(color, to: contrastColor, luminanceOffset: bands[index] * amplitude)
        }
    }

    func innerColor(contrastColor: NSColor) -> Color {
        Color(nsColor: adapted(Self.color(self == .cool ? 0x7298c4 : 0xc69080), to: contrastColor))
    }

    /// Adapt to the actual dial ink, not the OS appearance: a glass face may be
    /// over either a light or dark wallpaper regardless of the system theme.
    private func adapted(_ base: NSColor, to ink: NSColor, luminanceOffset: Double = 0) -> NSColor {
        let baseRGB = Self.linearComponents(base)
        let inkRGB = Self.linearComponents(ink)
        // A small custom-ink tint preserves each slot's cool/warm identity.
        let tinted = zip(baseRGB, inkRGB).map { $0 * 0.88 + $1 * 0.12 }
        let source = Self.luminance(tinted)
        let target = 0.10 + 0.72 * Self.luminance(inkRGB) + luminanceOffset
        let adjusted: [Double]
        if source > target {
            adjusted = tinted.map { $0 * target / source }
        } else {
            let lift = (target - source) / (1 - source)
            adjusted = tinted.map { $0 + (1 - $0) * lift }
        }
        let rgb = adjusted.map { value in
            value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    static func inkLightness(_ color: NSColor) -> Double {
        sqrt(luminance(linearComponents(color)))
    }

    private static func linearComponents(_ color: NSColor) -> [Double] {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .black
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component in
            let value = min(1, max(0, Double(component)))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }

    private static func luminance(_ rgb: [Double]) -> Double {
        rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// A fixed circular centreline, with a small local width increase under the light.
/// Geometry is sampled only when quota/size changes, never by a display timer.
struct GlassQuotaRingGeometry {
    let diameter: CGFloat
    let lineWidth: CGFloat
    let remaining: Double

    var fraction: Double { remaining.isFinite ? min(1, max(0, remaining / 100)) : 0 }
    var gain: CGFloat { lineWidth * 1.4 / 4.5 }
    var radius: CGFloat { max(0, (diameter - lineWidth - gain) / 2) }
    var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    func envelope(_ phase: Double) -> Double {
        pow(max(0, sin(.pi * phase)), 0.65)
    }

    func lightPosition(phase: Double) -> CGPoint {
        point(angle: 2 * .pi * fraction * phase - .pi / 2, radius: radius)
    }

    func width(at position: Double, phase: Double, animated: Bool = true) -> CGFloat {
        let distance = (position - 2 * .pi * fraction * phase) / 0.32
        let extra = animated ? Double(gain) * envelope(phase) * exp(-distance * distance / 2) : 0
        return lineWidth + CGFloat(extra)
    }

    func band(phase: Double, animated: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard fraction > 0, diameter > 0, radius > 0 else { return path }
        let extent = 2 * .pi * fraction
        let steps = 64
        let outer = (0...steps).map { i -> CGPoint in
            let position = extent * Double(i) / Double(steps)
            return point(angle: position - .pi / 2,
                         radius: radius + width(at: position, phase: phase, animated: animated) / 2)
        }
        let inner = (0...steps).map { i -> CGPoint in
            let position = extent * Double(i) / Double(steps)
            return point(angle: position - .pi / 2,
                         radius: radius - width(at: position, phase: phase, animated: animated) / 2)
        }
        path.move(to: outer[0])
        for point in outer.dropFirst() { path.addLine(to: point) }
        if fraction < 1 {
            let angle = extent - .pi / 2
            path.addArc(center: point(angle: angle, radius: radius),
                        radius: width(at: extent, phase: phase, animated: animated) / 2,
                        startAngle: angle, endAngle: angle + .pi, clockwise: false)
        }
        for point in inner.reversed() { path.addLine(to: point) }
        if fraction < 1 {
            path.addArc(center: point(angle: -.pi / 2, radius: radius),
                        radius: width(at: 0, phase: phase, animated: animated) / 2,
                        startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    private func point(angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius)
    }
}

struct GlassQuotaRingView: NSViewRepresentable {
    let remaining: Double
    let lineWidth: CGFloat
    let palette: GlassQuotaRingPalette
    let slot: Int
    let contrastColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> GlassQuotaRingNSView {
        let view = GlassQuotaRingNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GlassQuotaRingNSView, context: Context) { configure(view) }

    private func configure(_ view: GlassQuotaRingNSView) {
        view.configure(remaining: remaining, lineWidth: lineWidth, palette: palette,
                       slot: slot, contrastColor: NSColor(contrastColor), reduceMotion: reduceMotion)
    }
}

/// Core Animation owns the motion: no per-frame SwiftUI invalidation or usage reads.
/// Only the outer arc animates; hidden/minimised windows pause its layer clock.
final class GlassQuotaRingNSView: NSView {
    private let motion = CALayer()
    private let chroma = CALayer()
    private let colorField = CAGradientLayer()
    private let bandMask = CAShapeLayer()
    private let reflection = CAGradientLayer()
    private let reflectionMask = CAShapeLayer()
    private let light = CAGradientLayer()
    private let lightMask = CAShapeLayer()
    private let lightContainer = CALayer()
    private var configuration: Configuration?
    private var renderedSize: CGSize = .zero
    private var needsRebuild = true
    private var paused = false

    private struct Configuration: Equatable {
        let remaining: Double
        let lineWidth: CGFloat
        let palette: GlassQuotaRingPalette
        let slot: Int
        let contrastColor: NSColor
        let reduceMotion: Bool
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(motion)
        motion.addSublayer(chroma)
        chroma.addSublayer(colorField)
        chroma.mask = bandMask
        motion.addSublayer(reflection)
        reflection.mask = reflectionMask
        motion.addSublayer(lightContainer)
        lightContainer.mask = lightMask
        lightContainer.addSublayer(light)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateVisibility() }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    @objc private func visibilityChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateVisibility()
    }

    func configure(remaining: Double, lineWidth: CGFloat, palette: GlassQuotaRingPalette,
                   slot: Int, contrastColor: NSColor, reduceMotion: Bool) {
        let next = Configuration(remaining: remaining.isFinite ? min(100, max(0, remaining)) : 0,
                                 lineWidth: lineWidth, palette: palette, slot: slot,
                                 contrastColor: contrastColor.usingColorSpace(.deviceRGB) ?? .black,
                                 reduceMotion: reduceMotion)
        guard next != configuration else { return }
        configuration = next
        needsRebuild = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let config = configuration, bounds.width > 0, bounds.height > 0 else { return }
        guard needsRebuild || renderedSize != bounds.size else { return }
        needsRebuild = false
        renderedSize = bounds.size
        rebuild(config)
    }

    private func rebuild(_ config: Configuration) {
        let diameter = min(bounds.width, bounds.height)
        let geometry = GlassQuotaRingGeometry(diameter: diameter, lineWidth: config.lineWidth,
                                              remaining: config.remaining)
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let animated = !config.reduceMotion && geometry.fraction > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Reset clocks only on actual geometry/palette changes, not each clock tick.
        motion.speed = 1; motion.timeOffset = 0; motion.beginTime = 0; paused = false
        motion.frame = rect
        chroma.frame = rect
        chroma.opacity = 0.94
        // Rotate the colour field, not its quota mask or centreline.
        colorField.frame = rect.insetBy(dx: -diameter * 0.35, dy: -diameter * 0.35)
        colorField.type = .conic
        colorField.startPoint = CGPoint(x: 0.5, y: 0.5)
        colorField.endPoint = CGPoint(x: 0.5, y: 0)
        colorField.colors = config.palette.colors(contrastColor: config.contrastColor).map(\.cgColor)
        colorField.locations = [0, 0.15, 0.31, 0.48, 0.61, 0.79, 1]
        reflection.frame = rect
        // Text Color adapts the material underneath, not the independent light.
        // Keep the approved preview's thin-film and spotlight intensities even
        // with black ink; reducing both made the native dial look flat.
        reflection.colors = [0, 0.35, 0, 0.35, 0].map { NSColor.white.withAlphaComponent($0).cgColor }
        reflection.locations = [0.12, 0.29, 0.45, 0.65, 0.82]
        reflection.startPoint = CGPoint(x: -0.8, y: -0.3)
        reflection.endPoint = CGPoint(x: 1.2, y: 1.7)
        lightContainer.frame = rect
        let lightSize = diameter * 18 / 52
        light.bounds = CGRect(x: 0, y: 0, width: lightSize, height: lightSize)
        light.position = geometry.lightPosition(phase: 0)
        light.type = .radial
        light.startPoint = CGPoint(x: 0.5, y: 0.5); light.endPoint = CGPoint(x: 1, y: 1)
        light.colors = [0.86, 0.46, 0].map { NSColor.white.withAlphaComponent($0).cgColor }
        light.locations = [0, 0.42, 1]
        light.opacity = 0
        for mask in [bandMask, reflectionMask, lightMask] {
            mask.frame = rect
            mask.fillColor = NSColor.white.cgColor
            mask.path = geometry.band(phase: 0, animated: false)
            mask.removeAllAnimations()
        }
        colorField.removeAllAnimations()
        reflection.removeAllAnimations()
        light.removeAllAnimations()
        if animated {
            let duration: TimeInterval = 10
            let begin = motion.convertTime(CACurrentMediaTime(), from: nil) - Double(config.slot) * duration * 0.43
            let phases = (0...24).map { Double($0) / 24 }
            let paths = phases.map { geometry.band(phase: $0) }
            for mask in [bandMask, reflectionMask, lightMask] {
                animate(mask, keyPath: "path", values: paths, duration: duration, begin: begin)
            }
            animate(colorField, keyPath: "transform.rotation.z", values: [0, 2 * Double.pi],
                    duration: duration, begin: begin)
            // Match the preview's travelling thin-film sheen, rather than
            // leaving a fixed diagonal reflection over a rotating colour field.
            animate(reflection, keyPath: "startPoint", values: [
                NSValue(point: CGPoint(x: -0.8, y: -0.3)),
                NSValue(point: CGPoint(x: 0.3, y: 0.8)),
                NSValue(point: CGPoint(x: -0.8, y: -0.3))
            ], duration: duration, begin: begin - duration * 0.18, timing: .easeInEaseOut)
            animate(reflection, keyPath: "endPoint", values: [
                NSValue(point: CGPoint(x: 1.2, y: 1.7)),
                NSValue(point: CGPoint(x: 2.3, y: 2.8)),
                NSValue(point: CGPoint(x: 1.2, y: 1.7))
            ], duration: duration, begin: begin - duration * 0.18, timing: .easeInEaseOut)
            animate(light, keyPath: "position", values: phases.map { NSValue(point: geometry.lightPosition(phase: $0)) },
                    duration: duration, begin: begin)
            animate(light, keyPath: "opacity", values: phases.map { 0.82 * geometry.envelope($0) },
                    duration: duration, begin: begin)
        }
        CATransaction.commit()
        updateVisibility()
    }

    private func animate(_ target: CALayer, keyPath: String, values: [Any], duration: TimeInterval,
                         begin: CFTimeInterval, timing: CAMediaTimingFunctionName = .linear) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.beginTime = begin
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        target.add(animation, forKey: "tokenclock.quota.\(keyPath)")
    }

    private func updateVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard visible == paused else { return }
        if visible {
            let time = motion.timeOffset
            motion.speed = 1; motion.timeOffset = 0; motion.beginTime = 0
            motion.beginTime = motion.convertTime(CACurrentMediaTime(), from: nil) - time
        } else {
            let time = motion.convertTime(CACurrentMediaTime(), from: nil)
            motion.speed = 0; motion.timeOffset = time
        }
        paused = !visible
    }
}
