import AppKit

/// 自定义浮动面板：无标题栏、始终置顶、可拖拽
final class FloatingPanel: NSPanel {
    init(viewModel: ViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
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

    /// 更新窗口大小（收起/展开）
    /// 展开高度固定 600px（足够容纳表盘 + 天气条 + 5 个工具展开态），收起 260px
    func updateSize(expanded: Bool) {
        let targetHeight: CGFloat = expanded ? 600 : 260
        let currentFrame = self.frame

        // 保存位置（基于底部，topY 不变）
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let topY = currentFrame.maxY
            var newFrame = NSRect(
                x: currentFrame.origin.x,
                y: topY - targetHeight,
                width: 300,
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
            self.setFrame(NSRect(origin: self.frame.origin, size: NSSize(width: 300, height: targetHeight)), display: true)
        }
    }

    /// 保存窗口位置
    func savePosition() {
        ViewModel.saveWindowPosition(self.frame.origin)
    }
}
