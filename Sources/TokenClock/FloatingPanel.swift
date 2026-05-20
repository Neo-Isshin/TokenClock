import AppKit

/// 自定义浮动面板：无标题栏、始终置顶、可拖拽
final class FloatingPanel: NSPanel {
    static let panelWidth: CGFloat = 320
    static let collapsedHeight: CGFloat = 260
    static let resizeGripHeight: CGFloat = 18
    static let clockHeight: CGFloat = 240
    static let dropdownVerticalMargin: CGFloat = 10
    static let forecastHeight: CGFloat = 76
    static let headerHeight: CGFloat = 25
    static let toolRowHeight: CGFloat = 37

    private var isExpanded = false
    private var minimumExpandedHeight = FloatingPanel.collapsedHeight
    private var preferredExpandedHeight: CGFloat?
    private var resizeDragStartHeight: CGFloat = 0
    private var resizeDragTopY: CGFloat = 0
    private var wasMovableByBackgroundBeforeResize = true

    init(viewModel: ViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupWindow(viewModel: viewModel)
    }

    private func setupWindow(viewModel: ViewModel) {
        // 窗口级别：默认 normal（不置顶），不进入全屏 Space
        self.level = .normal

        // 无标题栏，背景透明
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true

        // 不拦截其他应用的激活事件
        self.becomesKeyOnlyIfNeeded = true
        // 默认只在普通桌面 Space 显示，全屏 Space 中隐藏
        self.collectionBehavior = [.canJoinAllSpaces]

        // 默认位置
        if let screen = NSScreen.main {
            let pos = ViewModel.loadWindowPosition(screenSize: screen.visibleFrame.size)
            let frameOrigin = NSPoint(x: pos.x, y: pos.y)
            self.setFrameOrigin(frameOrigin)
        }
    }

    // 点击背景可拖拽，不激活
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // 右键菜单：直接在 panel 层拦截，用屏幕坐标定位
    override func rightMouseDown(with event: NSEvent) {
        self.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func beginInteractiveResize() {
        guard isExpanded else { return }
        resizeDragStartHeight = frame.height
        resizeDragTopY = frame.maxY
        wasMovableByBackgroundBeforeResize = isMovableByWindowBackground
        isMovableByWindowBackground = false
    }

    func updateInteractiveResize(deltaY: CGFloat) {
        guard isExpanded else { return }
        let requestedHeight = resizeDragStartHeight + deltaY
        let maxHeight: CGFloat
        if let screen = screen ?? NSScreen.main {
            maxHeight = resizeDragTopY - screen.visibleFrame.minY
        } else {
            maxHeight = requestedHeight
        }
        let newHeight = min(max(requestedHeight, minimumExpandedHeight), maxHeight)
        preferredExpandedHeight = newHeight
        let newOriginY = resizeDragTopY - newHeight
        setFrame(
            NSRect(
                x: frame.origin.x,
                y: newOriginY,
                width: Self.panelWidth,
                height: newHeight
            ),
            display: true
        )
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: resizeDragTopY))
    }

    func endInteractiveResize() {
        isMovableByWindowBackground = wasMovableByBackgroundBeforeResize
    }

    /// 更新窗口大小（收起/展开）
    /// 展开时按可见工具数量动态适配；超过屏幕可用高度后由详情列表滚动。
    func updateSize(expanded: Bool, activeToolCount: Int = 0, showsWeather: Bool = false) {
        isExpanded = expanded
        let contentHeight = Self.clockHeight
            + Self.dropdownVerticalMargin
            + (showsWeather ? Self.forecastHeight : 0)
            + Self.headerHeight
            + CGFloat(activeToolCount) * Self.toolRowHeight
        minimumExpandedHeight = max(Self.collapsedHeight, contentHeight)
        let currentFrame = self.frame
        updateResizeLimits(expanded: expanded)

        // 保存位置（基于底部，topY 不变）
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let topY = currentFrame.maxY
            let targetHeight: CGFloat = expanded
                ? max(minimumExpandedHeight, topY - screenFrame.minY)
                : Self.collapsedHeight
            var newFrame = NSRect(
                x: currentFrame.origin.x,
                y: topY - targetHeight,
                width: Self.panelWidth,
                height: targetHeight
            )
            // 确保不超出屏幕底部
            if newFrame.minY < screenFrame.minY {
                newFrame.origin.y = screenFrame.minY
                newFrame.size.height = topY - screenFrame.minY
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            })
        } else {
            let targetHeight: CGFloat = expanded ? minimumExpandedHeight : Self.collapsedHeight
            self.setFrame(NSRect(origin: self.frame.origin, size: NSSize(width: Self.panelWidth, height: targetHeight)), display: true)
        }
    }

    private func updateResizeLimits(expanded: Bool) {
        if expanded {
            minSize = NSSize(width: Self.panelWidth, height: minimumExpandedHeight)
        } else {
            minSize = NSSize(width: Self.panelWidth, height: Self.collapsedHeight)
            preferredExpandedHeight = nil
        }
    }

    /// 保存窗口位置
    func savePosition() {
        ViewModel.saveWindowPosition(self.frame.origin)
    }
}
