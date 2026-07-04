import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: FloatingPanel!
    private var dropdownPanel: DropdownPanel!
    private var viewModel: ViewModel!
    private var settingsWindow: NSWindow?
    private var themePickerPanel: NSPanel?
    private var themePickerEventMonitor: Any?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            setup()
        }
    }

    private func setup() {
        viewModel = ViewModel()
        panel = FloatingPanel(viewModel: viewModel)
        dropdownPanel = DropdownPanel()

        let mainView = MainView(viewModel: viewModel)
        let contentView = NSHostingView(rootView: mainView)
        contentView.frame = NSRect(
            x: 0,
            y: 0,
            width: FloatingPanel.panelWidth,
            height: FloatingPanel.collapsedHeight
        )
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        panel.delegate = self

        let detailView = DropdownPanelView(
            viewModel: viewModel,
            onResizeStart: { [weak self] in
                self?.dropdownPanel?.beginResize()
            },
            onResizeChanged: { [weak self] deltaY in
                self?.dropdownPanel?.updateResize(deltaY: deltaY)
            },
            onResizeEnded: { [weak self] in
                self?.dropdownPanel?.endResize()
            }
        )
        let detailContentView = NSHostingView(rootView: detailView)
        detailContentView.frame = NSRect(
            x: 0,
            y: 0,
            width: FloatingPanel.panelWidth,
            height: FloatingPanel.collapsedHeight
        )
        detailContentView.autoresizingMask = [.width, .height]
        dropdownPanel.contentView = detailContentView

        // 同步 alwaysOnTop 状态到面板
        if viewModel.alwaysOnTop {
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        dropdownPanel.configureLevel(alwaysOnTop: viewModel.alwaysOnTop)

        // 绑定展开/收起直接回调，绕过 NotificationCenter 延迟
        viewModel.onExpandChanged = { [weak self] expanded in
            guard let self else { return }
            self.panel.updateSize(
                expanded: expanded,
                activeToolCount: self.activeToolCount,
                showsWeather: !self.viewModel.weather.cityName.isEmpty
            )
            if expanded {
                self.showDropdownPanel()
            } else {
                self.dropdownPanel.hide()
            }
        }

        // 表盘大小变化：重设浮动面板尺寸（updateSize 保持视觉中心不变），
        // 并在展开态下重新定位下拉详情面板，使其继续贴合表盘底部、横向居中。
        viewModel.onClockSizeChanged = { [weak self] in
            guard let self else { return }
            self.panel.updateSize(
                expanded: self.viewModel.isExpanded,
                activeToolCount: self.activeToolCount,
                showsWeather: !self.viewModel.weather.cityName.isEmpty
            )
            if self.viewModel.isExpanded {
                self.dropdownPanel.reposition(below: self.panel.frame)
            }
        }

        // 监听天气更新（城市解析后刷新菜单标签）
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWeatherResolved(_:)),
            name: .weatherUpdated, object: nil
        )

        // 启动本地 API 服务器（按用户偏好决定是否启用 + 端口）
        let apiEnabled = UserDefaults.standard.bool(
            for: .apiServerEnabled, default: true
        )
        if apiEnabled {
            // 端口缺省 / 越界时回退到 AppConfig.LocalServer.defaultPort
            let port = AppDelegate.resolveAPIServerPort()
            UsageAPIServer.shared.configure(port: port)
            UsageAPIServer.shared.bind(viewModel: viewModel)
            UsageAPIServer.shared.start()
        }

        panel.makeKeyAndOrderFront(nil)
        setupRightClickMenu()
        // 兜底迁移：清理旧的 installer plist / SMAppService 残留
        LaunchAgentHelper.cleanupLegacy()
    }

    private var activeToolCount: Int {
        viewModel.visibleTools.filter { $0.todayTokens > 0 }.count
    }

    /// 从 UserDefaults 读取 API 服务器端口，越界或缺省时回退到 AppConfig 默认值
    private static func resolveAPIServerPort() -> UInt16 {
        let raw = UserDefaults.standard.integer(forKey: SettingsKey.apiServerPort.rawValue)
        if raw > 0, raw <= UInt16.max {
            return UInt16(raw)
        }
        return AppConfig.LocalServer.defaultPort
    }

    /// 构造本地 API 端点 URL（端口来自用户偏好，路径来自 AppConfig）
    static func apiEndpointURL() -> String {
        "http://localhost:\(resolveAPIServerPort())\(AppConfig.LocalServer.usageEndpoint)"
    }

    private func showDropdownPanel() {
        dropdownPanel.show(
            below: panel.frame,
            activeToolCount: activeToolCount,
            showsWeather: !viewModel.weather.cityName.isEmpty
        )
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            UsageAPIServer.shared.stop()
            panel?.savePosition()
            removeThemePickerMonitor()
        }
    }

    // MARK: - 右键菜单

    private func setupRightClickMenu() {
        let menu = NSMenu()
        let tr = L10n.shared.tr

        let themeItem = NSMenuItem(title: tr("menu.clockFace"),
                                  action: #selector(openThemePicker(_:)), keyEquivalent: "")
        menu.addItem(themeItem)

        if !viewModel.savedCustomThemes.isEmpty {
            let savedMenu = NSMenu()
            for saved in viewModel.savedCustomThemes {
                let item = NSMenuItem(title: saved.name,
                                      action: #selector(selectCustomTheme(_:)), keyEquivalent: "")
                item.representedObject = saved.id.uuidString
                if viewModel.selectedTheme == .custom && viewModel.activeCustomThemeId == saved.id {
                    item.state = .on
                }
                savedMenu.addItem(item)
            }
            let savedItem = NSMenuItem(title: tr("menu.myClockFaces"), action: nil, keyEquivalent: "")
            savedItem.submenu = savedMenu
            menu.addItem(savedItem)
        }

        // 表盘大小子菜单（小/中/大/特大）
        let sizeMenu = NSMenu()
        for size in ClockSize.allCases {
            let item = NSMenuItem(title: size.localizedName,
                                  action: #selector(selectClockSize(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            if viewModel.clockSize == size { item.state = .on }
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: tr("size.title"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let apiItem = NSMenuItem(title: L10n.shared.tr("menu.api", Int(AppDelegate.resolveAPIServerPort())),
                                 action: #selector(copyAPIEndpoint(_:)), keyEquivalent: "")
        menu.addItem(apiItem)
        menu.addItem(.separator())

        let opacityMenu = NSMenu()
        for value in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(value)%",
                                  action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = value
            if Int(viewModel.windowOpacity * 100) == value { item.state = .on }
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: tr("menu.opacity"), action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        opacityItem.tag = 100 // tag for lookup in setOpacity
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let alwaysOnTopItem = NSMenuItem(title: tr("menu.alwaysOnTop"),
                                         action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        alwaysOnTopItem.state = viewModel.alwaysOnTop ? .on : .off
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())

        let tempItem = NSMenuItem(title: tr("menu.temperature"), action: nil, keyEquivalent: "")
        let tempMenu = NSMenu()
        let celsiusItem = NSMenuItem(title: tr("menu.celsius"), action: #selector(setCelsius(_:)), keyEquivalent: "")
        celsiusItem.state = viewModel.useFahrenheit ? .off : .on
        let fahrenheitItem = NSMenuItem(title: tr("menu.fahrenheit"), action: #selector(setFahrenheit(_:)), keyEquivalent: "")
        fahrenheitItem.state = viewModel.useFahrenheit ? .on : .off
        tempMenu.addItem(celsiusItem)
        tempMenu.addItem(fahrenheitItem)
        tempItem.submenu = tempMenu
        menu.addItem(tempItem)
        menu.addItem(.separator())

        let cityMenu = NSMenu()
        let currentCity = viewModel.selectedCity
        for city in ViewModel.cityOptions {
            let label: String
            if city == "auto" {
                let resolved = viewModel.resolvedCityName
                label = resolved.isEmpty ? tr("menu.cityAutoLocating") : String(format: tr("menu.cityAuto"), resolved)
            } else {
                label = ViewModel.cityLabels[city] ?? city
            }
            let item = NSMenuItem(title: label,
                                  action: #selector(selectCity(_:)), keyEquivalent: "")
            item.representedObject = city
            if city == currentCity { item.state = .on }
            cityMenu.addItem(item)
        }
        let cityItem = NSMenuItem(title: tr("menu.city"), action: nil, keyEquivalent: "")
        cityItem.submenu = cityMenu
        menu.addItem(cityItem)
        menu.addItem(.separator())

        let tzMenu = NSMenu()
        let currentTZ = viewModel.selectedTimezone
        for tz in ViewModel.timezoneOptions {
            let item = NSMenuItem(title: tr(tz.label),
                                  action: #selector(selectTimezone(_:)), keyEquivalent: "")
            item.representedObject = tz.identifier
            if tz.identifier == currentTZ { item.state = .on }
            tzMenu.addItem(item)
        }
        let tzItem = NSMenuItem(title: tr("menu.timezone"), action: nil, keyEquivalent: "")
        tzItem.submenu = tzMenu
        menu.addItem(tzItem)
        menu.addItem(.separator())

        // Language submenu
        let langMenu = NSMenu()
        let langItem = NSMenuItem(title: tr("menu.language"), action: nil, keyEquivalent: "")
        for lang in AppLanguage.allCases {
            let item = NSMenuItem(title: lang.displayName,
                                  action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.rawValue
            if viewModel.language == lang { item.state = .on }
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: tr("menu.settings"),
                                      action: #selector(openSettings(_:)), keyEquivalent: ",")
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: tr("menu.launchAtLogin"),
                                    action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        if let variant = LaunchAgentHelper.detectVariant(),
           LaunchAgentHelper.isRegistered(variant: variant) {
            launchItem.state = .on
        }
        menu.addItem(launchItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: tr("menu.quit"),
                                  action: #selector(quitApp(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        panel.menu = menu
    }

    // MARK: - 菜单 Actions

    @objc private func selectClockSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = ClockSize(rawValue: raw) else { return }
        viewModel.setClockSize(size)
        setupRightClickMenu()  // 刷新子菜单勾选状态
    }

    @objc private func openThemePicker(_ sender: NSMenuItem) {
        showThemePicker()
    }

    @objc private func selectCustomTheme(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        viewModel.applyCustomTheme(id: id)
        viewModel.selectedTheme = .custom
        viewModel.saveTheme()
        setupRightClickMenu()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        let value = Double(sender.tag) / 100.0
        panel.alphaValue = value
        dropdownPanel.alphaValue = value
        viewModel.windowOpacity = value
        if let opacityMenu = panel.menu?.items.first(where: { $0.tag == 100 })?.submenu {
            for item in opacityMenu.items {
                item.state = (item.tag == sender.tag) ? .on : .off
            }
        }
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        // macOS 不会对"已显示"窗口的 level/collectionBehavior 变更重新评估全屏 Space 归属，
        // 必须先 orderOut → 改属性 → 再 orderFront，"取消置顶"才能真正退出全屏视频覆盖。
        panel.orderOut(nil)
        if sender.state == .on {
            sender.state = .off
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces]
            dropdownPanel.configureLevel(alwaysOnTop: false)
            viewModel.alwaysOnTop = false
        } else {
            sender.state = .on
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            dropdownPanel.configureLevel(alwaysOnTop: true)
            viewModel.alwaysOnTop = true
        }
        // 以新属性重显（用 orderFront 而非 orderFrontRegardless：后者会无视 collectionBehavior
        // 强制把窗口塞进当前全屏 Space，导致"取消置顶"瞬间又被拉回）。orderFront 尊重规则：
        // OFF 时 .normal + 仅 canJoinAllSpaces → 不进入全屏 Space（不覆盖全屏视频）；ON 时进入。
        panel.orderFront(nil)
        UserDefaults.standard.set(viewModel.alwaysOnTop, forKey: SettingsKey.alwaysOnTop.rawValue)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard let variant = LaunchAgentHelper.detectVariant() else {
            // 路径无法识别 —— 用一个 NSAlert 提示,不要静默失败
            let alert = NSAlert()
            alert.messageText = "无法识别当前 TokenClock 变体"
            alert.informativeText = "开机自启动仅在通过 `tokenclock` CLI 安装的 TokenClock 上可用(路径形如 ~/.tokenclock/glass/TokenClock)。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好的")
            alert.runModal()
            return
        }

        let binaryPath = ProcessInfo.processInfo.arguments.first ?? Bundle.main.executablePath ?? ""
        if sender.state == .on {
            LaunchAgentHelper.disable(variant: variant)
            sender.state = .off
            viewModel.launchAtLogin = false
        } else {
            do {
                try LaunchAgentHelper.enable(variant: variant, binaryPath: binaryPath)
                sender.state = .on
                viewModel.launchAtLogin = true
            } catch {
                let alert = NSAlert()
                alert.messageText = "启用开机自启动失败"
                alert.informativeText = "\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                alert.runModal()
            }
        }
    }

    @objc private func selectTimezone(_ sender: NSMenuItem) {
        guard let tz = sender.representedObject as? String else { return }
        viewModel.selectedTimezone = tz
        setupRightClickMenu()
    }

    @objc private func handleWeatherResolved(_ notification: Notification) {
        setupRightClickMenu()
    }

    @objc private func selectCity(_ sender: NSMenuItem) {
        guard let city = sender.representedObject as? String else { return }
        viewModel.selectedCity = city
        viewModel.refreshWeather()
        setupRightClickMenu()
    }

    @objc private func setCelsius(_ sender: NSMenuItem) {
        viewModel.useFahrenheit = false
        setupRightClickMenu()
    }

    @objc private func setFahrenheit(_ sender: NSMenuItem) {
        viewModel.useFahrenheit = true
        setupRightClickMenu()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = AppLanguage(rawValue: raw) else { return }
        L10n.shared.language = lang
        viewModel.language = lang
        setupRightClickMenu()
        settingsWindow?.title = L10n.shared.tr("settings.title")
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        showSettingsWindow()
    }

    @objc private func copyAPIEndpoint(_ sender: NSMenuItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AppDelegate.apiEndpointURL(), forType: .string)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(sender)
    }

    // MARK: - 设置窗口

    private func showSettingsWindow() {
        // 时钟面板是非激活的 floating 窗；打开设置时必须显式激活 app，否则前台仍是
        // 终端等其它 app，设置窗口里的 TextField 收不到键盘输入（敲字全跑到前台 app）。
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(viewModel: viewModel, onDone: { [weak self] in
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
        })
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.shared.tr("settings.title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    // MARK: - 表盘预览面板

    private func showThemePicker() {
        hideThemePicker()

        let themeView = ThemePickerView(viewModel: viewModel) { [weak self] in
            self?.hideThemePicker()
        }
        let hostingView = NSHostingView(rootView: themeView)

        let pickerPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pickerPanel.backgroundColor = .clear
        pickerPanel.isOpaque = false
        pickerPanel.hasShadow = true
        pickerPanel.level = .statusBar   // 最前：高于时钟（即使常驻置顶）与下拉面板
        pickerPanel.contentView = hostingView

        // 按内容自适应高度，避免截断第二行表盘预览
        let measureView = NSHostingView(rootView: themeView)
        measureView.frame = NSRect(x: 0, y: 0, width: 300, height: 4000)
        let fitHeight = measureView.fittingSize.height
        pickerPanel.setContentSize(NSSize(width: 300, height: max(250, fitHeight)))

        // 定位到时钟面板的左侧（避免被表盘遮挡），垂直居中对齐；
        // 左侧空间不足时自动改放到右侧，并整体夹在屏幕可见区内。
        if let panelFrame = panel?.frame {
            let pickerSize = pickerPanel.frame.size
            let margin: CGFloat = 12
            var origin = NSPoint(
                x: panelFrame.minX - pickerSize.width - margin,
                y: panelFrame.midY - pickerSize.height / 2
            )
            if let visible = (panel?.screen ?? NSScreen.main)?.visibleFrame {
                if origin.x < visible.minX {
                    // 左侧放不下 → 放到表盘右侧
                    origin.x = panelFrame.maxX + margin
                }
                origin.y = max(visible.minY, min(origin.y, visible.maxY - pickerSize.height))
            }
            pickerPanel.setFrameOrigin(origin)
        }

        pickerPanel.orderFrontRegardless()  // 强制置前（即使 App 未激活）
        self.themePickerPanel = pickerPanel

        // 点击外部关闭
        installThemePickerMonitor()
    }

    private func hideThemePicker() {
        themePickerPanel?.orderOut(nil)
        themePickerPanel = nil
        removeThemePickerMonitor()
    }

    private func installThemePickerMonitor() {
        removeThemePickerMonitor()
        themePickerEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hideThemePicker()
            }
        }
    }

    private func removeThemePickerMonitor() {
        if let monitor = themePickerEventMonitor {
            NSEvent.removeMonitor(monitor)
            themePickerEventMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        Task { @MainActor in
            if let window = closingWindow, window == settingsWindow {
                settingsWindow = nil
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow == panel,
              viewModel.isExpanded else { return }
        dropdownPanel.reposition(below: panel.frame)
    }
}

// MARK: - 主视图容器

struct MainView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        ClockContentView(viewModel: viewModel)
            .frame(width: FloatingPanel.panelWidth, height: FloatingPanel.collapsedHeight)
    }
}

private struct DropdownPanelView: View {
    @ObservedObject var viewModel: ViewModel
    let onResizeStart: () -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DetailDropdownView(
                tools: viewModel.visibleTools,
                theme: viewModel.selectedTheme,
                weather: viewModel.weather,
                localizedCityName: viewModel.localizedCityName,
                isLoading: viewModel.isInitialLoading
            )
            .frame(maxHeight: .infinity, alignment: .top)

            BottomResizeControl(
                onResizeStart: onResizeStart,
                onResizeChanged: onResizeChanged,
                onResizeEnded: onResizeEnded
            )
            .frame(width: FloatingPanel.panelWidth, height: FloatingPanel.resizeGripHeight)
        }
        .frame(width: FloatingPanel.panelWidth)
    }
}

private struct BottomResizeControl: NSViewRepresentable {
    let onResizeStart: () -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    func makeNSView(context: Context) -> ResizeControlNSView {
        ResizeControlNSView(
            onResizeStart: onResizeStart,
            onResizeChanged: onResizeChanged,
            onResizeEnded: onResizeEnded
        )
    }

    func updateNSView(_ nsView: ResizeControlNSView, context: Context) {
        nsView.onResizeStart = onResizeStart
        nsView.onResizeChanged = onResizeChanged
        nsView.onResizeEnded = onResizeEnded
    }
}

private final class ResizeControlNSView: NSView {
    var onResizeStart: () -> Void
    var onResizeChanged: (CGFloat) -> Void
    var onResizeEnded: () -> Void

    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false { didSet { needsDisplay = true } }
    private var isDragging = false { didSet { needsDisplay = true } }

    init(
        onResizeStart: @escaping () -> Void,
        onResizeChanged: @escaping (CGFloat) -> Void,
        onResizeEnded: @escaping () -> Void
    ) {
        self.onResizeStart = onResizeStart
        self.onResizeChanged = onResizeChanged
        self.onResizeEnded = onResizeEnded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let capsuleWidth: CGFloat = 62
        let capsuleHeight: CGFloat = 16
        let capsuleRect = NSRect(
            x: (bounds.width - capsuleWidth) / 2,
            y: 0,
            width: capsuleWidth,
            height: capsuleHeight
        )

        let fillAlpha: CGFloat = isDragging ? 0.70 : (isHovering ? 0.55 : 0.40)
        NSColor.controlAccentColor.withAlphaComponent(fillAlpha).setFill()
        NSBezierPath(roundedRect: capsuleRect, xRadius: 8, yRadius: 8).fill()

        NSColor.labelColor.withAlphaComponent(isDragging ? 0.95 : 0.75).setStroke()
        let centerX = bounds.midX
        let centerY = capsuleHeight / 2
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: centerX, y: centerY - 4))
        path.line(to: NSPoint(x: centerX, y: centerY + 4))
        path.move(to: NSPoint(x: centerX - 3, y: centerY + 1))
        path.line(to: NSPoint(x: centerX, y: centerY + 4))
        path.line(to: NSPoint(x: centerX + 3, y: centerY + 1))
        path.move(to: NSPoint(x: centerX - 3, y: centerY - 1))
        path.line(to: NSPoint(x: centerX, y: centerY - 4))
        path.line(to: NSPoint(x: centerX + 3, y: centerY - 1))
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.resizeUpDown.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let startMouseY = NSEvent.mouseLocation.y
        onResizeStart()
        NSCursor.resizeUpDown.set()

        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                onResizeChanged(startMouseY - NSEvent.mouseLocation.y)
            case .leftMouseUp:
                isDragging = false
                onResizeEnded()
                NSCursor.resizeUpDown.set()
                return
            default:
                break
            }
        }

        isDragging = false
        onResizeEnded()
    }
}
