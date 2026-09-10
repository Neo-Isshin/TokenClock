import AppKit
import SwiftUI

/// AppKit owns the complete primary mouse sequence so click and window dragging remain compatible
/// across SwiftUI/runtime changes. Transparent corners stay click-through by using a circular
/// hit test instead of a full rectangular content shape.
/// （自 main 分支移植：SwiftUI 的 tap 手势会吞掉窗口拖拽的鼠标序列，点击/拖动改由 AppKit 分发；
/// 拖动超过 3pt 判定为拖拽并移动窗口，否则视为点击切换详情面板。）
struct ClockTooltipRegion: Equatable {
    let rect: NSRect
    let text: String
}

struct ClockInteractionLayer: NSViewRepresentable {
    var tooltipRegions: [ClockTooltipRegion] = []
    let onClick: () -> Void
    var onDragStart: () -> Void = {}

    init(
        tooltipRegions: [ClockTooltipRegion] = [],
        onClick: @escaping () -> Void,
        onDragStart: @escaping () -> Void = {}
    ) {
        self.tooltipRegions = tooltipRegions
        self.onClick = onClick
        self.onDragStart = onDragStart
    }

    func makeNSView(context: Context) -> ClockInteractionNSView {
        ClockInteractionNSView(
            onClick: onClick,
            onDragStart: onDragStart,
            tooltipRegions: tooltipRegions
        )
    }

    func updateNSView(_ nsView: ClockInteractionNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onDragStart = onDragStart
        nsView.updateTooltipRegions(tooltipRegions)
    }
}
final class ClockInteractionNSView: NSView, NSViewToolTipOwner {
    var onClick: () -> Void
    var onDragStart: () -> Void
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var mouseDownTime: TimeInterval?
    private var isDragging = false
    private let dragThreshold: CGFloat = 5
    private let clickDurationLimit: TimeInterval = 0.35
    private var tooltipRegions: [ClockTooltipRegion]
    private var tooltipTags: [NSView.ToolTipTag] = []
    private var tooltipTextByTag: [NSView.ToolTipTag: String] = [:]
    private var tooltipBoundsSize = NSSize.zero

    init(
        onClick: @escaping () -> Void,
        onDragStart: @escaping () -> Void = {},
        tooltipRegions: [ClockTooltipRegion] = []
    ) {
        self.onClick = onClick
        self.onDragStart = onDragStart
        self.tooltipRegions = tooltipRegions
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        if tooltipBoundsSize != bounds.size {
            rebuildToolTips()
        }
    }

    func updateTooltipRegions(_ regions: [ClockTooltipRegion]) {
        guard regions != tooltipRegions || tooltipBoundsSize != bounds.size else { return }
        tooltipRegions = regions
        rebuildToolTips()
    }

    func tooltipText(at point: NSPoint) -> String? {
        tooltipRegions.first { $0.rect.contains(point) }?.text
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipTextByTag[tag] ?? ""
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
        mouseDownTime = event.timestamp
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartMouse != nil, dragStartOrigin != nil else { return }

        // A very fast gesture may contain no intermediate dragged event. Inspect the final
        // pointer position before deciding whether this was a click.
        updateDrag(with: event)
        let pressDuration = event.timestamp - (mouseDownTime ?? event.timestamp)
        if !isDragging && pressDuration <= clickDurationLimit {
            onClick()
        }
        resetDragState()
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
        if !isDragging, max(abs(deltaX), abs(deltaY)) > dragThreshold {
            isDragging = true
            onDragStart()
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(
                x: startOrigin.x + deltaX,
                y: startOrigin.y + deltaY
            ))
        }
    }

    private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
        if event.windowNumber != 0 { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func resetDragState() {
        dragStartMouse = nil
        dragStartOrigin = nil
        mouseDownTime = nil
        isDragging = false
    }

    private func rebuildToolTips() {
        for tag in tooltipTags { removeToolTip(tag) }
        tooltipTags.removeAll(keepingCapacity: true)
        tooltipTextByTag.removeAll(keepingCapacity: true)
        tooltipBoundsSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        for region in tooltipRegions where region.rect.intersects(bounds) {
            let tag = addToolTip(region.rect.intersection(bounds), owner: self, userData: nil)
            tooltipTags.append(tag)
            tooltipTextByTag[tag] = region.text
        }
    }
}
