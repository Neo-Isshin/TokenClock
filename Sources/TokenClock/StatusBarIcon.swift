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
    private(set) var isTemporarilyOnTop = false

    @discardableResult
    mutating func toggle() -> Bool {
        setHidden(!isHidden)
        return isHidden
    }

    mutating func setHidden(_ hidden: Bool) {
        isHidden = hidden
        if hidden { isTemporarilyOnTop = false }
    }

    mutating func showTemporarilyOnTop() {
        isHidden = false
        isTemporarilyOnTop = true
    }

    func shouldShowOnDoubleClick(windowVisible: Bool, coveredFraction: Double?) -> Bool {
        if isHidden || !windowVisible { return true }
        if isTemporarilyOnTop { return false }
        return DialOcclusion.shouldShow(hidden: false, coveredFraction: coveredFraction)
    }

    /// Temporary presentation is in-memory only; the preference remains owned
    /// by ViewModel. Hiding restores the caller's current persistent setting.
    @MainActor func apply(to window: NSWindow, alwaysOnTop: Bool) {
        let onTop = alwaysOnTop || isTemporarilyOnTop
        window.level = onTop ? .statusBar : .normal
        window.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }
}

/// Keep application windows hidden while the menu-bar summary is used on its
/// own. Weak references avoid retaining windows that have since been closed.
@MainActor
final class StatusSummaryHiddenWindows {
    private let windows = NSHashTable<NSWindow>.weakObjects()

    func hide(_ candidates: [NSWindow], excluding statusWindow: NSWindow?) {
        for window in candidates where window !== statusWindow && window.isVisible {
            windows.add(window)
            window.orderOut(nil)
        }
    }

    func restore() {
        let previous = windows.allObjects
        windows.removeAllObjects()
        for window in previous { window.orderFront(nil) }
    }
}

/// Delay only the single action until the system's double-click interval has
/// elapsed, so a double click never flashes the summary before toggling the dial.
@MainActor
final class StatusBarClickCoordinator {
    private var pending: Task<Void, Never>?
    private let interval: TimeInterval
    private var firstClick: (time: TimeInterval, point: NSPoint, window: Int)?

    init(interval: TimeInterval = NSEvent.doubleClickInterval) { self.interval = interval }

    /// AppKit action callbacks may expose the mouse-down event, and menu-bar
    /// tracking can restart the system click count. Pair actual clicks on this
    /// button by monotonic time and position as well as honoring native counts.
    func click(event: NSEvent?, single: @escaping @MainActor () -> Void, double: () -> Void) {
        if event == nil || event?.type == .applicationDefined {
            // This coordinator belongs to one button. A relayed activation has
            // no reliable event position; the current cursor may already move.
            recognize(time: ProcessInfo.processInfo.systemUptime, point: .zero,
                window: -1, reportedCount: 1, single: single, double: double)
            return
        }
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else {
            click(count: 1, single: single, double: double)
            return
        }
        recognize(time: event.timestamp > 0 && event.timestamp.isFinite ? event.timestamp : ProcessInfo.processInfo.systemUptime,
            point: event.locationInWindow, window: event.windowNumber, reportedCount: event.clickCount, single: single, double: double)
    }

    private func recognize(time: TimeInterval, point: NSPoint, window: Int, reportedCount: Int,
                           single: @escaping @MainActor () -> Void, double: () -> Void) {
        let previous = firstClick
        let paired = previous.map {
            let dx = point.x - $0.point.x, dy = point.y - $0.point.y
            return $0.window == window && time >= $0.time
                && time - $0.time <= interval && dx * dx + dy * dy <= 16
        } ?? false
        let reportedDouble = reportedCount > 0 && reportedCount.isMultiple(of: 2)
        let isDouble = reportedDouble || paired
        click(count: isDouble ? 2 : 1, single: single, double: double)
        if !isDouble { firstClick = (time, point, window) }
    }

    func click(count: Int, single: @escaping @MainActor () -> Void, double: () -> Void) {
        cancel()
        if count > 0 && count.isMultiple(of: 2) {
            double()
        } else {
            let delay = UInt64(max(0, interval) * 1_000_000_000)
            pending = Task {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled else { return }
                single()
            }
        }
    }

    func cancel() { pending?.cancel(); pending = nil; firstClick = nil }
}
