import SwiftUI
import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: FloatingPanel!
    private var dropdownPanel: DropdownPanel!
    private var viewModel: ViewModel!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var themePickerPanel: NSPanel?
    private var themePickerEventMonitor: Any?

    // 全屏智能隐藏（仅 alwaysOnTop=OFF 时启用）：见下方 MARK 区
    private var fullscreenCheckTimer: Timer?
    private var isHiddenForFullscreen = false

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
        // 启动即应用持久化的透明度（否则要等用户首次右键设置才生效）
        panel.alphaValue = viewModel.windowOpacity

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
            },
            onCodexQuotaShown: { [weak self] in
                guard let self else { return }
                let comfortableHeight: CGFloat = self.viewModel.weather.cityName.isEmpty ? 280 : 356
                self.dropdownPanel.ensureHeight(comfortableHeight)
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
        } else {
            // 非置顶 = 普通窗口：NSPanel 即使 level=normal 也排在普通窗口之上，故 Apple TV 等
            // 播放器的伪全屏（铺屏普通窗口）盖不住它。这里启用智能隐藏：被大面积覆盖就隐藏。
            panel.level = .normal
            panel.collectionBehavior = []
            startFullscreenDetection()
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
            // 先停 ViewModel 定时器（含 historyTimer），再处理其余清理
            viewModel?.shutdown()
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

        // 表盘外观子菜单（液态玻璃：文字颜色 / 玻璃材质 / 玻璃底色）
        let appearanceMenu = NSMenu()

        // — 文字颜色（解决浅色壁纸上白色文字不可见）—
        let textColorMenu = NSMenu()
        for (mode, title) in [(DialTextMode.theme, tr("menu.dialTextTheme")),
                              (DialTextMode.white, tr("menu.dialTextWhite")),
                              (DialTextMode.black, tr("menu.dialTextBlack"))] {
            let item = NSMenuItem(title: title, action: #selector(setDialTextMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            if viewModel.dialTextMode == mode { item.state = .on }
            textColorMenu.addItem(item)
        }
        let customTextItem = NSMenuItem(title: tr("menu.dialTextCustom"),
                                        action: #selector(pickDialTextColor(_:)), keyEquivalent: "")
        if viewModel.dialTextMode == .custom { customTextItem.state = .on }
        textColorMenu.addItem(customTextItem)
        let textColorItem = NSMenuItem(title: tr("menu.dialTextColor"), action: nil, keyEquivalent: "")
        textColorItem.submenu = textColorMenu
        appearanceMenu.addItem(textColorItem)

        // — 详情面板文字色（覆写下拉面板文字色；nil = 跟随主题）—
        let panelHex = viewModel.dropdownTextColorHex
        let panelTextMenu = NSMenu()
        let panelThemeItem = NSMenuItem(title: tr("menu.panelTextTheme"),
                                        action: #selector(setDropdownTextColorPreset(_:)), keyEquivalent: "")
        // representedObject 默认 nil → 跟随主题
        if panelHex == nil { panelThemeItem.state = .on }
        panelTextMenu.addItem(panelThemeItem)
        let panelWhiteItem = NSMenuItem(title: tr("menu.panelTextWhite"),
                                        action: #selector(setDropdownTextColorPreset(_:)), keyEquivalent: "")
        panelWhiteItem.representedObject = "#FFFFFF"
        if panelHex == "#FFFFFF" { panelWhiteItem.state = .on }
        panelTextMenu.addItem(panelWhiteItem)
        let panelBlackItem = NSMenuItem(title: tr("menu.panelTextBlack"),
                                        action: #selector(setDropdownTextColorPreset(_:)), keyEquivalent: "")
        panelBlackItem.representedObject = "#000000"
        if panelHex == "#000000" { panelBlackItem.state = .on }
        panelTextMenu.addItem(panelBlackItem)
        let panelCustomItem = NSMenuItem(title: tr("menu.panelTextCustom"),
                                         action: #selector(pickDropdownTextColor(_:)), keyEquivalent: "")
        if panelHex != nil && panelHex != "#FFFFFF" && panelHex != "#000000" { panelCustomItem.state = .on }
        panelTextMenu.addItem(panelCustomItem)
        let panelTextItem = NSMenuItem(title: tr("menu.panelTextColor"), action: nil, keyEquivalent: "")
        panelTextItem.submenu = panelTextMenu
        appearanceMenu.addItem(panelTextItem)

        // — 玻璃底色（私有 tintColor SPI；27 Beta 可能渲染偏实心）—
        let tintMenu = NSMenu()
        let noTintItem = NSMenuItem(title: tr("menu.tintNone"), action: #selector(clearDialTint(_:)), keyEquivalent: "")
        if viewModel.glassTintHex == nil { noTintItem.state = .on }
        tintMenu.addItem(noTintItem)
        let customTintItem = NSMenuItem(title: tr("menu.tintCustom"),
                                        action: #selector(pickDialTint(_:)), keyEquivalent: "")
        if viewModel.glassTintHex != nil { customTintItem.state = .on }
        tintMenu.addItem(customTintItem)
        let tintSubItem = NSMenuItem(title: tr("menu.dialTint"), action: nil, keyEquivalent: "")
        tintSubItem.submenu = tintMenu
        appearanceMenu.addItem(tintSubItem)

        // — 毛玻璃底板透明度（公开 NSVisualEffectView.alphaValue；折射玻璃下层，0=无底板）—
        let backingMenu = NSMenu()
        for value in [0, 25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setGlassBackingAlpha(_:)), keyEquivalent: "")
            item.tag = value
            if Int(viewModel.glassBackingAlpha * 100) == value { item.state = .on }
            backingMenu.addItem(item)
        }
        let backingItem = NSMenuItem(title: tr("menu.glassBacking"), action: nil, keyEquivalent: "")
        backingItem.submenu = backingMenu
        appearanceMenu.addItem(backingItem)

        // 液态玻璃折射总开关（实验性私有 API；关 → 回退公开 .clear 玻璃）
        let glassToggle = NSMenuItem(title: tr("menu.glassRefraction"),
                                     action: #selector(toggleGlassRefraction(_:)), keyEquivalent: "")
        glassToggle.state = viewModel.glassRefractionEnabled ? .on : .off
        appearanceMenu.addItem(glassToggle)

        // 一键恢复默认：文字→跟随主题、材质→标准、底色→无
        appearanceMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: tr("menu.dialResetDefaults"),
                                   action: #selector(resetDialAppearance(_:)), keyEquivalent: "")
        appearanceMenu.addItem(resetItem)

        let appearanceItem = NSMenuItem(title: tr("menu.dialAppearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

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

        let aboutItem = NSMenuItem(title: tr("menu.about"),
                                   action: #selector(showAbout(_:)), keyEquivalent: "")
        menu.addItem(aboutItem)

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

    // MARK: - 表盘外观（液态玻璃）Actions

    @objc private func setDialTextMode(_ sender: NSMenuItem) {
        guard let mode = DialTextMode(rawValue: sender.tag) else { return }
        viewModel.dialTextMode = mode
        setupRightClickMenu()
    }

    /// 毛玻璃底板透明度档位（0/25/50/75/100%）：公开 NSVisualEffectView.alphaValue，折射玻璃下层。
    @objc private func setGlassBackingAlpha(_ sender: NSMenuItem) {
        viewModel.glassBackingAlpha = Double(sender.tag) / 100.0
        setupRightClickMenu()
    }

    @objc private func pickDialTextColor(_ sender: NSMenuItem) {
        openColorPicker(for: .dialText)
    }

    @objc private func clearDialTint(_ sender: NSMenuItem) {
        viewModel.glassTintHex = nil
        setupRightClickMenu()
    }

    @objc private func pickDialTint(_ sender: NSMenuItem) {
        openColorPicker(for: .glassTint)
    }

    @objc private func pickDropdownTextColor(_ sender: NSMenuItem) {
        openColorPicker(for: .dropdownText)
    }

    @objc private func setDropdownTextColorPreset(_ sender: NSMenuItem) {
        viewModel.dropdownTextColorHex = sender.representedObject as? String
        setupRightClickMenu()
    }

    private enum ColorPickerTarget { case dialText, glassTint, dropdownText }
    private var colorPickerTarget: ColorPickerTarget = .dialText

    /// 打开系统拾色器（target/action 实时回写 viewModel）。两类目标复用同一 NSColorPanel。
    private func openColorPicker(for target: ColorPickerTarget) {
        colorPickerTarget = target
        NSLog("TC pickDialColor open target=\(target)")
        // accessory app 里直接 makeKeyAndOrderFront 会被菜单 modal tracking 吞掉且面板不上前；
        // dispatch 到下个 runloop + 显式激活 app + 不随失焦隐藏。
        DispatchQueue.main.async {
            let picker = NSColorPanel.shared
            picker.showsAlpha = false
            picker.hidesOnDeactivate = false
            switch target {
            case .dialText:
                picker.color = CodableColor(hex: self.viewModel.dialTextColorHex)?.nsColor ?? .white
            case .glassTint:
                picker.color = self.viewModel.glassTintHex.flatMap { CodableColor(hex: $0)?.nsColor }
                    ?? NSColor(srgbRed: 0.55, green: 0.72, blue: 0.92, alpha: 1)
            case .dropdownText:
                picker.color = self.viewModel.dropdownTextColorHex.flatMap { CodableColor(hex: $0)?.nsColor } ?? .white
            }
            picker.setTarget(self)
            picker.setAction(#selector(self.colorPanelChanged(_:)))
            NSApp.activate()
            picker.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        let hex = CodableColor(nsColor: panel.color).hexString
        switch colorPickerTarget {
        case .dialText:
            viewModel.dialTextMode = .custom
            viewModel.dialTextColorHex = hex
        case .glassTint:
            viewModel.glassTintHex = hex
        case .dropdownText:
            viewModel.dropdownTextColorHex = hex
        }
    }

    /// 一键恢复表盘外观默认：文字→跟随主题（hex 复位）、材质→标准(dock)、底色→无。
    @objc private func resetDialAppearance(_ sender: NSMenuItem) {
        NSLog("TC resetDialAppearance fired")
        viewModel.dialTextMode = .theme
        viewModel.dialTextColorHex = "#FFFFFF"
        viewModel.glassMaterialVariant = 2
        viewModel.glassTintHex = nil
        viewModel.glassBackingAlpha = 0
        viewModel.dropdownTextColorHex = nil
        setupRightClickMenu()
    }

    /// 液态玻璃折射总开关。表盘立即在折射玻璃 / 公开 .clear 之间切换；
    /// _hasActiveAppearance 覆写为启动时决策，彻底关闭/重开需重启。
    @objc private func toggleGlassRefraction(_ sender: NSMenuItem) {
        viewModel.glassRefractionEnabled.toggle()
        setupRightClickMenu()
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
            panel.collectionBehavior = []
            dropdownPanel.configureLevel(alwaysOnTop: false)
            viewModel.alwaysOnTop = false
        } else {
            sender.state = .on
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            dropdownPanel.configureLevel(alwaysOnTop: true)
            viewModel.alwaysOnTop = true
        }
        // 重显（用 orderFront 而非 orderFrontRegardless：后者无视 collectionBehavior 强制塞进
        // 当前全屏 Space）。OFF 模式下被播放器全屏覆盖改由下方智能隐藏机制处理。
        panel.orderFront(nil)
        UserDefaults.standard.set(viewModel.alwaysOnTop, forKey: SettingsKey.alwaysOnTop.rawValue)
        // OFF：在重显后启动智能隐藏（避免立即 orderOut 与上面的 orderFront 打架）；
        // ON：停止检测（若曾被隐藏，顺带恢复可见）。
        if viewModel.alwaysOnTop { stopFullscreenDetection() } else { startFullscreenDetection() }
    }

    // MARK: - 全屏智能隐藏（仅 alwaysOnTop=OFF 时启用）
    //
    // NSPanel（nonactivatingPanel）即使 level=normal 也排在普通窗口之上，故"取消置顶"后仍会
    // 浮在 Apple TV 等播放器的伪全屏窗口（铺满副屏的普通窗口，非系统原生全屏）之上 —— level
    // 与 collectionBehavior 都治不了它（panel 的固有 z-order）。这里在 OFF 模式轮询窗口栈：
    // 若时钟面板被其他 app 的「大窗口」（layer≤0 且面积≥所在屏 60%，即全屏/最大化级别）覆盖，
    // 就 orderOut 主动隐藏让视频干净呈现；退出该状态再 orderFront 恢复。ON 模式不轮询
    //（statusBar level 最高，本就不会被盖）。用户正展开下拉详情时不隐藏，避免打断阅读。
    private func startFullscreenDetection() {
        guard fullscreenCheckTimer == nil else { return }
        // 0.5s 轮询：CGWindowListCopyWindowInfo 只读窗口元数据（非截图），开销极小；
        // 用 0.5s 而非 1s 让进入/退出全屏的隐藏与恢复都更跟手。
        fullscreenCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // Timer 回调在主线程（main runloop）；assumeIsolated 把执行交接回 @MainActor 上下文。
            MainActor.assumeIsolated { self?.evaluateFullscreenHide() }
        }
        evaluateFullscreenHide()
    }

    private func stopFullscreenDetection() {
        fullscreenCheckTimer?.invalidate()
        fullscreenCheckTimer = nil
        if isHiddenForFullscreen { unhideForFullscreen() }
    }

    private func evaluateFullscreenHide() {
        guard let panel = self.panel else { return }
        if dropdownPanel.isVisible { return }   // 用户正在看下拉详情，不打断
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let clockScreen = (NSScreen.screens.first { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let screenFrameCG = nsToCG(clockScreen.frame)
        let clockFrame = nsToCG(panel.frame)

        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }

        var shouldHide = false
        for w in info {
            if (w[kCGWindowOwnerName as String] as? String) == "TokenClock" { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0 else { continue }   // 仅普通 app 窗口（排除菜单栏/Dock 正层 + 桌面/WindowServer 负层）
            guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let rect = CGRect(x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
                              y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
                              width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
                              height: (b["Height"] as? NSNumber)?.doubleValue ?? 0)
            let inter = clockFrame.intersection(rect)
            guard !inter.isNull else { continue }   // 必须与时钟有重叠
            // 真全屏判据：窗口贴屏顶 + 近满高 + 近满宽（即覆盖菜单栏区）。以此区分「全屏」与
            // 「最大化（顶部留菜单栏）」——后者不该隐藏时钟，让用户退出全屏（变最大化）后时钟可见。
            let isFullscreen = rect.minY <= screenFrameCG.minY + 5
                && rect.height >= screenFrameCG.height - 5
                && rect.width >= screenFrameCG.width - 5
            if isFullscreen { shouldHide = true; break }
        }

        if shouldHide {
            if !isHiddenForFullscreen { hideForFullscreen() }
        } else if isHiddenForFullscreen {
            unhideForFullscreen()
        }
    }

    private func hideForFullscreen() {
        isHiddenForFullscreen = true
        panel.orderOut(nil)
    }

    private func unhideForFullscreen() {
        isHiddenForFullscreen = false
        panel.orderFront(nil)
    }

    /// NSWindow.frame 用 NSScreen 全局坐标（左下原点）；CGWindowList 的 bounds 用 CG 全局坐标
    /// （左上原点）。统一到 CG 坐标做交集。
    private func nsToCG(_ nsRect: CGRect) -> CGRect {
        guard let main = NSScreen.main else { return nsRect }
        return CGRect(x: nsRect.minX,
                      y: main.frame.height - nsRect.maxY,
                      width: nsRect.width,
                      height: nsRect.height)
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

    @objc private func showAbout(_ sender: NSMenuItem) {
        // 关于面板恒定浮于普通窗口之上（独立于时钟 alwaysOnTop 设置），
        // 确保从菜单调用时始终可见、不会被其它 app 压底。
        NSApp.activate(ignoringOtherApps: true)
        if let window = aboutWindow {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView(onDone: { [weak self] in
            self?.aboutWindow?.close()
            self?.aboutWindow = nil
        })
        let hostingView = NSHostingView(rootView: aboutView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.shared.tr("menu.about")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hostingView
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.aboutWindow = window
    }

    // MARK: - 设置窗口

    private func showSettingsWindow() {
        // 时钟面板是非激活的 floating 窗；打开设置时必须显式激活 app，否则前台仍是
        // 终端等其它 app，设置窗口里的 TextField 收不到键盘输入（敲字全跑到前台 app）。
        NSApp.activate(ignoringOtherApps: true)
        // 设置窗口恒定浮于普通窗口之上（独立于时钟 alwaysOnTop 设置），
        // 点开后不会被其它 app 的 .normal 窗口压底。
        if let window = settingsWindow {
            window.level = .floating
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
        window.level = .floating
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

    // MARK: - 清理

    /// 移除 NotificationCenter 观察者（setup 注册了 .weatherResolved）
    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
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
    let onCodexQuotaShown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DetailDropdownView(
                tools: viewModel.visibleTools,
                theme: viewModel.selectedTheme,
                dropdownTextColorOverride: viewModel.dropdownTextColorHex.flatMap { CodableColor(hex: $0)?.swiftUIColor },
                weather: viewModel.weather,
                localizedCityName: viewModel.localizedCityName,
                isLoading: viewModel.isInitialLoading,
                groupingMode: viewModel.groupingMode,
                onGroupingChange: { viewModel.groupingMode = $0 },
                showPercentage: viewModel.showPercentage,
                onShowPercentageChange: { viewModel.showPercentage = $0 },
                showsCodexQuota: viewModel.showsCodexQuota,
                codexQuota: viewModel.codexQuota,
                onCodexQuotaToggle: {
                    viewModel.toggleCodexQuota()
                    if viewModel.showsCodexQuota { onCodexQuotaShown() }
                },
                onCodexQuotaRefresh: { viewModel.refreshCodexQuota() }
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
