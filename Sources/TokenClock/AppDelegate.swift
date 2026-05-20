import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: FloatingPanel!
    private var viewModel: ViewModel!
    private var settingsWindow: NSWindow?
    private var themePickerPanel: NSPanel?
    private var themePickerEventMonitor: Any?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await setup()
        }
    }

    private func setup() {
        viewModel = ViewModel()
        panel = FloatingPanel(viewModel: viewModel)

        let mainView = MainView(viewModel: viewModel)
        let contentView = NSHostingView(rootView: mainView)
        contentView.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        // 同步 alwaysOnTop 状态到面板
        if viewModel.alwaysOnTop {
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        // 绑定展开/收起直接回调，绕过 NotificationCenter 延迟
        viewModel.onExpandChanged = { [weak self] expanded in
            self?.panel?.updateSize(expanded: expanded)
        }

        // 监听天气更新（城市解析后刷新菜单标签）
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWeatherResolved(_:)),
            name: .weatherUpdated, object: nil
        )

        // 启动本地 API 服务器
        UsageAPIServer.shared.bind(viewModel: viewModel)
        UsageAPIServer.shared.start()

        panel.makeKeyAndOrderFront(nil)
        setupRightClickMenu()
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

        let apiItem = NSMenuItem(title: tr("menu.api"),
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
        if SMAppService.mainApp.status == .enabled { launchItem.state = .on }
        menu.addItem(launchItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: tr("menu.quit"),
                                  action: #selector(quitApp(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        panel.menu = menu
    }

    // MARK: - 菜单 Actions

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
        viewModel.windowOpacity = value
        if let opacityMenu = panel.menu?.items.first(where: { $0.tag == 100 })?.submenu {
            for item in opacityMenu.items {
                item.state = (item.tag == sender.tag) ? .on : .off
            }
        }
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        if sender.state == .on {
            sender.state = .off
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces]
            viewModel.alwaysOnTop = false
        } else {
            sender.state = .on
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            viewModel.alwaysOnTop = true
        }
        UserDefaults.standard.set(viewModel.alwaysOnTop, forKey: "TC_alwaysOnTop")
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.unregister()
                sender.state = .off
                viewModel.launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                viewModel.launchAtLogin = true
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
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
        pasteboard.setString("http://localhost:9988/api/usage", forType: .string)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(sender)
    }

    // MARK: - 设置窗口

    private func showSettingsWindow() {
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
        pickerPanel.level = .floating
        pickerPanel.contentView = hostingView

        // 定位到时钟面板下方
        if let panelFrame = panel?.frame {
            var origin = panelFrame.origin
            origin.y -= 170  // 面板下方
            origin.x += 10   // 稍微右移
            pickerPanel.setFrameOrigin(origin)
        }

        pickerPanel.orderFront(nil)
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
}

// MARK: - 主视图容器

struct MainView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            ClockContentView(viewModel: viewModel)

            if viewModel.isExpanded {
                DetailDropdownView(
                    tools: viewModel.sortedTools,
                    theme: viewModel.selectedTheme,
                    weather: viewModel.weather,
                    localizedCityName: viewModel.localizedCityName
                )
                .transition(.opacity)
            }
        }
        .frame(width: 300)
        .animation(.easeOut(duration: 0.18), value: viewModel.isExpanded)
    }
}
