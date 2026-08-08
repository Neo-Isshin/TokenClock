import SwiftUI
import AppKit
import QuartzCore

/// A compositor-driven gradient used behind the Liquid Glass dial.
///
/// The previous SwiftUI `repeatForever` rotation invalidated the entire view graph every frame,
/// keeping the app process at roughly 8% CPU while idle. A Core Animation transform is committed
/// once and then evaluated by the window compositor, so the glass keeps its slow movement without
/// continuously rebuilding the clock face, text, or Canvas hands.
struct AuroraGradientLayerView: NSViewRepresentable {
    let colors: [NSColor]
    let startPoint: CGPoint
    let endPoint: CGPoint
    let startAngle: Double
    let endAngle: Double
    let duration: TimeInterval
    let animates: Bool

    func makeNSView(context: Context) -> AuroraGradientNSView {
        let view = AuroraGradientNSView()
        view.configure(
            colors: colors,
            startPoint: startPoint,
            endPoint: endPoint,
            startAngle: startAngle,
            endAngle: endAngle,
            duration: duration,
            animates: animates
        )
        return view
    }

    func updateNSView(_ view: AuroraGradientNSView, context: Context) {
        view.configure(
            colors: colors,
            startPoint: startPoint,
            endPoint: endPoint,
            startAngle: startAngle,
            endAngle: endAngle,
            duration: duration,
            animates: animates
        )
    }
}

final class AuroraGradientNSView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var animationSignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Overscan prevents transparent corners while the square gradient rotates inside a circle.
        gradientLayer.frame = bounds.insetBy(dx: -bounds.width * 0.24, dy: -bounds.height * 0.24)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    func configure(
        colors: [NSColor],
        startPoint: CGPoint,
        endPoint: CGPoint,
        startAngle: Double,
        endAngle: Double,
        duration: TimeInterval,
        animates: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.locations = colors.indices.map { NSNumber(value: Double($0) / Double(max(colors.count - 1, 1))) }
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
        gradientLayer.transform = CATransform3DMakeRotation(startAngle * .pi / 180, 0, 0, 1)
        CATransaction.commit()

        let signature = "\(startAngle)|\(endAngle)|\(duration)|\(animates)"
        guard signature != animationSignature || gradientLayer.animation(forKey: "tokenclock.aurora.rotation") == nil else {
            return
        }
        animationSignature = signature
        gradientLayer.removeAnimation(forKey: "tokenclock.aurora.rotation")
        guard animates else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = startAngle * .pi / 180
        rotation.toValue = endAngle * .pi / 180
        rotation.duration = duration
        rotation.autoreverses = true
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rotation.isRemovedOnCompletion = false
        gradientLayer.add(rotation, forKey: "tokenclock.aurora.rotation")
    }
}
