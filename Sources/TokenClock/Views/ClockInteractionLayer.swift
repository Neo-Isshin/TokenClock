import AppKit
import SwiftUI

/// AppKit owns the primary mouse sequence so click and native window dragging remain compatible
/// across SwiftUI/runtime changes. Transparent corners stay click-through by using a circular
/// hit test instead of a full rectangular content shape.
struct ClockInteractionLayer: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClockInteractionNSView {
        ClockInteractionNSView(onClick: onClick)
    }

    func updateNSView(_ nsView: ClockInteractionNSView, context: Context) {
        nsView.onClick = onClick
    }
}

final class ClockInteractionNSView: NSView {
    var onClick: () -> Void
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let radius = min(bounds.width, bounds.height) / 2
        return dx * dx + dy * dy <= radius * radius ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouse = screenPoint(for: event, in: window)
        dragStartOrigin = window.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // A very fast gesture may contain no intermediate dragged event. Inspect the final
        // pointer position before deciding whether this was a click.
        updateDrag(with: event)
        if !isDragging {
            onClick()
        }
        dragStartMouse = nil
        dragStartOrigin = nil
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.rightMouseDown(with: event)
    }

    private func updateDrag(with event: NSEvent) {
        guard let window, let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else {
            return
        }
        let currentMouse = screenPoint(for: event, in: window)
        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y
        if !isDragging, max(abs(deltaX), abs(deltaY)) > 3 {
            isDragging = true
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(
                x: startOrigin.x + deltaX,
                y: startOrigin.y + deltaY
            ))
        }
    }

    private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
        window.convertPoint(toScreen: event.locationInWindow)
    }
}
