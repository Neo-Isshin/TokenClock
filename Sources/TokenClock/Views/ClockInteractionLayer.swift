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
    var onQuotaClick: (() -> Void)?
    var onQuotaRightClick: (() -> Void)?
    var onTooltipHover: (String?) -> Void = { _ in }

    init(
        tooltipRegions: [ClockTooltipRegion] = [],
        onClick: @escaping () -> Void,
        onDragStart: @escaping () -> Void = {},
        onTooltipHover: @escaping (String?) -> Void = { _ in },
        onQuotaClick: (() -> Void)? = nil,
        onQuotaRightClick: (() -> Void)? = nil
    ) {
        self.tooltipRegions = tooltipRegions
        self.onClick = onClick
        self.onDragStart = onDragStart
        self.onQuotaClick = onQuotaClick
        self.onQuotaRightClick = onQuotaRightClick
        self.onTooltipHover = onTooltipHover
    }

    func makeNSView(context: Context) -> ClockInteractionNSView {
        ClockInteractionNSView(
            onClick: onClick,
            onDragStart: onDragStart,
            onTooltipHover: onTooltipHover,
            onQuotaClick: onQuotaClick,
            onQuotaRightClick: onQuotaRightClick,
            tooltipRegions: tooltipRegions
        )
    }

    func updateNSView(_ nsView: ClockInteractionNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onDragStart = onDragStart
        nsView.onQuotaClick = onQuotaClick
        nsView.onQuotaRightClick = onQuotaRightClick
        nsView.onTooltipHover = onTooltipHover
        nsView.updateTooltipRegions(tooltipRegions)
    }
}
final class ClockInteractionNSView: NSView {
    var onClick: () -> Void
    var onDragStart: () -> Void
    var onQuotaClick: (() -> Void)?
    var onQuotaRightClick: (() -> Void)?
    var onTooltipHover: (String?) -> Void
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var mouseDownTime: TimeInterval?
    private var mouseDownQuotaRect: NSRect?
    private var isDragging = false
    private let dragThreshold: CGFloat = 5
    private let clickDurationLimit: TimeInterval = 0.35
    private var tooltipRegions: [ClockTooltipRegion]
    private var tooltipTrackingArea: NSTrackingArea?
    private var hoveredTooltipText: String?

    init(
        onClick: @escaping () -> Void,
        onDragStart: @escaping () -> Void = {},
        onTooltipHover: @escaping (String?) -> Void = { _ in },
        onQuotaClick: (() -> Void)? = nil,
        onQuotaRightClick: (() -> Void)? = nil,
        tooltipRegions: [ClockTooltipRegion] = []
    ) {
        self.onClick = onClick
        self.onDragStart = onDragStart
        self.onQuotaClick = onQuotaClick
        self.onQuotaRightClick = onQuotaRightClick
        self.onTooltipHover = onTooltipHover
        self.tooltipRegions = tooltipRegions
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil { setHoveredTooltip(nil) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tooltipTrackingArea { removeTrackingArea(tooltipTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tooltipTrackingArea = area
    }

    func updateTooltipRegions(_ regions: [ClockTooltipRegion]) {
        guard regions != tooltipRegions else { return }
        tooltipRegions = regions
        if let hoveredTooltipText,
           !regions.contains(where: { $0.text == hoveredTooltipText }) {
            self.hoveredTooltipText = nil
            DispatchQueue.main.async { [weak self] in self?.onTooltipHover(nil) }
        }
    }

    func tooltipText(at point: NSPoint) -> String? {
        tooltipRegions.first { $0.rect.contains(point) }?.text
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredTooltip(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredTooltip(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredTooltip(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Interactive quota regions are local to this view even when the
        // circular dial is offset inside a wider transparent window.
        if (onQuotaClick != nil || onQuotaRightClick != nil), !isHiddenOrHasHiddenAncestor,
           super.hitTest(point) != nil,
           tooltipRegions.contains(where: { $0.rect.contains(convert(point, from: superview)) }) { return self }
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let radius = min(bounds.width, bounds.height) / 2
        return dx * dx + dy * dy <= radius * radius ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        setHoveredTooltip(nil)
        dragStartMouse = screenPoint(for: event, in: window)
        dragStartOrigin = window.frame.origin
        mouseDownQuotaRect = tooltipRegions.first { $0.rect.contains(convert(event.locationInWindow, from: nil)) }?.rect
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
            if let rect = mouseDownQuotaRect, rect.contains(convert(event.locationInWindow, from: nil)),
               let onQuotaClick { onQuotaClick() }
            else { onClick() }
        }
        resetDragState()
    }

    override func rightMouseDown(with event: NSEvent) {
        if tooltipText(at: convert(event.locationInWindow, from: nil)) != nil, let onQuotaRightClick {
            setHoveredTooltip(nil)
            onQuotaRightClick()
        } else { window?.rightMouseDown(with: event) }
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
        mouseDownQuotaRect = nil
        isDragging = false
    }

    private func updateHoveredTooltip(at point: NSPoint) {
        setHoveredTooltip(tooltipText(at: point))
    }

    private func setHoveredTooltip(_ text: String?) {
        guard text != hoveredTooltipText else { return }
        hoveredTooltipText = text
        onTooltipHover(text)
    }
}
