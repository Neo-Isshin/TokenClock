import AppKit

/// The small monochrome TokenClock mark used by the macOS menu-bar item.
///
/// It is drawn from paths instead of loading the concept JPG so the status item
/// stays a true template image: macOS can recolor it for light/dark menu bars
/// and the silhouette remains crisp at 16–18 points.
enum StatusBarIcon {
    static func makeImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setStroke()
        let center = NSPoint(x: size * 0.50, y: size * 0.52)
        let radius = size * 0.39

        // A strong upper semicircle reads as a speedometer/usage gauge even at
        // 16–18 points and matches the selected "dashboard" concept.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 180,
            endAngle: 0,
            clockwise: true
        )
        arc.lineWidth = size * 0.10
        arc.lineCapStyle = .round
        arc.stroke()

        // Four separated usage bars keep the data meaning legible without
        // turning into a solid block after the system rasterizes the template.
        let barBase = size * 0.12
        let barWidth = size * 0.105
        let bars: [(x: CGFloat, height: CGFloat)] = [
            (0.27, 0.16), (0.44, 0.29), (0.62, 0.22), (0.80, 0.10)
        ]
        for bar in bars {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: size * bar.x, y: barBase))
            path.line(to: NSPoint(x: size * bar.x, y: barBase + size * bar.height))
            path.lineWidth = barWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Active needle points into the upper-right usage range.
        let needleAngle = Double.pi * 46 / 180
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: NSPoint(
            x: center.x + radius * 0.76 * CGFloat(cos(needleAngle)),
            y: center.y + radius * 0.76 * CGFloat(sin(needleAngle))
        ))
        needle.lineWidth = size * 0.097
        needle.lineCapStyle = .round
        needle.stroke()

        NSColor.white.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - size * 0.072,
                y: center.y - size * 0.072,
                width: size * 0.144,
                height: size * 0.144
            )
        ).fill()

        image.isTemplate = true
        return image
    }
}

struct StatusBarVisibilityState: Equatable {
    private(set) var isHidden = false

    @discardableResult
    mutating func toggle() -> Bool {
        isHidden.toggle()
        return isHidden
    }

    mutating func setHidden(_ hidden: Bool) {
        isHidden = hidden
    }
}
