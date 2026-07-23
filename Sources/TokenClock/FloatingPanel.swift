import AppKit
import ObjectiveC

/// 自定义浮动面板：无标题栏、始终置顶、可拖拽
final class FloatingPanel: NSPanel {
    /// 面板宽 / 高由用户选择的表盘大小（ClockSize）派生，读取 UserDefaults，随设置实时变化。
    static var panelWidth: CGFloat { currentClockSize.panelWidth }
    static var collapsedHeight: CGFloat { currentClockSize.diameter }
    static let resizeGripHeight: CGFloat = 18
    static var clockHeight: CGFloat { currentClockSize.diameter }
    static let dropdownVerticalMargin: CGFloat = 10
    static let forecastHeight: CGFloat = 76
    static let headerHeight: CGFloat = 25
    static let toolRowHeight: CGFloat = 37

    /// 当前表盘大小（缺省 / 越界回退 medium）。
    private static var currentClockSize: ClockSize {
        if let raw = UserDefaults.standard.string(for: .clockSize),
           let size = ClockSize(rawValue: raw) {
            return size
        }
        return .medium
    }

    init(viewModel: ViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        Self.applyGlassActiveOverrideIfNeeded()
        setupWindow(viewModel: viewModel)
    }

    private func setupWindow(viewModel: ViewModel) {
        // 窗口级别：默认 normal（不置顶），不进入全屏 Space
        self.level = .normal

        // 无标题栏，背景透明
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true

        // 不拦截其他应用的激活事件；折射靠 _hasActiveAppearance 覆写，无需 panel 成 key。
        self.becomesKeyOnlyIfNeeded = true
        // 普通窗口默认：collectionBehavior 置空（不 join 任何 Space）→ 不进入全屏 Space，
        // 原生全屏播放器可覆盖。alwaysOnTop 开启时由 AppDelegate 覆写为
        // [.canJoinAllSpaces, .fullScreenAuxiliary]（跨桌面 + 全屏置顶）。
        self.collectionBehavior = []

        // 默认位置
        if let screen = NSScreen.main {
            let pos = ViewModel.loadWindowPosition(screenSize: screen.visibleFrame.size)
            let frameOrigin = NSPoint(x: pos.x, y: pos.y)
            self.setFrameOrigin(frameOrigin)
        }
    }

    // 点击背景可拖拽，不激活。折射不依赖窗口成 key（_hasActiveAppearance 已覆写）。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 右键菜单：直接在 panel 层拦截，用屏幕坐标定位
    override func rightMouseDown(with event: NSEvent) {
        self.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 表盘窗口保持当前档位尺寸；展开内容由独立详情面板承载。
    /// 尺寸变化时保持视觉中心（midX）与顶部（maxY）不变，表盘不会"跳位"。
    func updateSize(expanded: Bool, activeToolCount: Int = 0, showsWeather: Bool = false) {
        let midX = frame.midX
        let topY = frame.maxY
        let width = Self.panelWidth
        let height = Self.collapsedHeight
        setFrame(
            NSRect(x: midX - width / 2, y: topY - height, width: width, height: height),
            display: true
        )
    }

    /// 保存窗口位置
    func savePosition() {
        ViewModel.saveWindowPosition(self.frame.origin)
    }
}

// MARK: - 私有 SPI：让窗口永远报告 "active" 以驱动 NSGlassEffectView 折射
// 社区已知 workaround（r/SwiftUI 1l86rue）：覆写 NSWindow 的 _hasActiveAppearance 系列，
// 使玻璃渲染不依赖窗口成 key —— 这样 borderless nonactivatingPanel 也能持续折射，
// 切到别的 app（失焦）也不消失。5 个 selector 在 macOS 27 (26A5368g) 实测存在。
private let glassActiveOverrideSelectors: [String] = [
    "_hasActiveAppearance",
    "_hasActiveAppearanceIgnoringKeyFocus",
    "_hasActiveControls",
    "_hasKeyAppearance",
    "_hasMainAppearance"
]

extension FloatingPanel {
    nonisolated(unsafe) private static var didApplyActiveOverride = false

    /// 默认无条件启用（让 borderless 非激活面板持续折射）；TC_GLASS_DISABLE 关闭整套液态玻璃。
    static func applyGlassActiveOverrideIfNeeded() {
        guard !didApplyActiveOverride,
              !UserDefaults.standard.bool(forKey: "TC_GLASS_DISABLE") else { return }
        didApplyActiveOverride = true
        let alwaysTrue: @convention(c) (AnyObject, Selector) -> Bool = { _, _ in true }
        let newIMP = unsafeBitCast(alwaysTrue, to: IMP.self)
        for name in glassActiveOverrideSelectors {
            let sel = NSSelectorFromString(name)
            // 复用 NSWindow 上同名方法的 type encoding（实测 B16@0:8）。
            let types: String
            if let superMethod = class_getInstanceMethod(NSWindow.self, sel),
               let enc = method_getTypeEncoding(superMethod) {
                types = String(cString: enc)
            } else {
                types = "B@:"
            }
            _ = class_replaceMethod(FloatingPanel.self, sel, newIMP, types)
        }
    }
}

final class DropdownPanel: NSPanel {
    private var resizeStartHeight: CGFloat = 0
    private var resizeTopY: CGFloat = 0
    private var minPanelHeight: CGFloat = 0
    private var maxPanelHeight: CGFloat = 0
    private var preferredPanelHeight: CGFloat?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: FloatingPanel.panelWidth, height: FloatingPanel.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = []
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configureLevel(alwaysOnTop: Bool) {
        if alwaysOnTop {
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            level = .normal
            collectionBehavior = []   // 普通窗口：不进全屏 Space，全屏播放器可覆盖
        }
    }

    func requiredHeight(activeToolCount: Int, showsWeather: Bool) -> CGFloat {
        let contentHeight = (showsWeather ? FloatingPanel.forecastHeight : 0)
            + FloatingPanel.headerHeight
            + CGFloat(activeToolCount) * FloatingPanel.toolRowHeight
            + FloatingPanel.resizeGripHeight
            + FloatingPanel.dropdownVerticalMargin
        return max(120, contentHeight)
    }

    func show(below clockFrame: NSRect, activeToolCount: Int, showsWeather: Bool) {
        updateLimits(below: clockFrame, activeToolCount: activeToolCount, showsWeather: showsWeather)
        let targetHeight = min(max(preferredPanelHeight ?? minPanelHeight, minPanelHeight), maxPanelHeight)
        setFrame(frame(below: clockFrame, height: targetHeight), display: true)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }

    func reposition(below clockFrame: NSRect) {
        updateLimits(below: clockFrame)
        setFrame(frame(below: clockFrame, height: min(frame.height, maxPanelHeight)), display: true)
    }

    func beginResize() {
        resizeStartHeight = frame.height
        resizeTopY = frame.maxY
    }

    func updateResize(deltaY: CGFloat) {
        let requestedHeight = resizeStartHeight + deltaY
        let newHeight = min(max(requestedHeight, minPanelHeight), maxPanelHeight)
        preferredPanelHeight = newHeight
        setFrame(
            NSRect(x: frame.minX, y: resizeTopY - newHeight, width: FloatingPanel.panelWidth, height: newHeight),
            display: true
        )
    }

    func endResize() {}

    private func updateLimits(
        below clockFrame: NSRect,
        activeToolCount: Int? = nil,
        showsWeather: Bool? = nil
    ) {
        if let activeToolCount, let showsWeather {
            minPanelHeight = requiredHeight(activeToolCount: activeToolCount, showsWeather: showsWeather)
        }
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame
        let availableHeight = max(80, clockFrame.minY - (screenFrame?.minY ?? 0))
        minPanelHeight = min(minPanelHeight, availableHeight)
        maxPanelHeight = availableHeight
    }

    private func frame(below clockFrame: NSRect, height: CGFloat) -> NSRect {
        NSRect(
            x: clockFrame.midX - FloatingPanel.panelWidth / 2,
            y: clockFrame.minY - height,
            width: FloatingPanel.panelWidth,
            height: height
        )
    }
}
