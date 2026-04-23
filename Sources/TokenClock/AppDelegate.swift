import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var viewModel: ViewModel!

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
        contentView.frame = NSRect(x: 0, y: 0, width: 260, height: 260)
        panel.contentView = contentView

        // 监听展开/收起通知
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleExpanded(_:)),
            name: .toggleExpanded, object: nil
        )

        panel.makeKeyAndOrderFront(nil)
        setupRightClickMenu()
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            panel?.savePosition()
        }
    }

    // MARK: - 展开/收起

    @objc private func handleToggleExpanded(_ notification: Notification) {
        guard let expanded = notification.object as? Bool else { return }
        panel?.updateSize(expanded: expanded)
    }

    // MARK: - 右键菜单

    private func setupRightClickMenu() {
        let menu = NSMenu()

        // 透明度子菜单
        let opacityMenu = NSMenu()
        for value in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(value)%",
                                  action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = value
            if Int(viewModel.windowOpacity * 100) == value { item.state = .on }
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        // 置顶
        let alwaysOnTopItem = NSMenuItem(title: "始终置于顶层",
                                         action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        alwaysOnTopItem.state = viewModel.alwaysOnTop ? .on : .off
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())

        // 城市选择（天气）
        let cityMenu = NSMenu()
        let cities = ["Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York"]
        let currentCity = viewModel.weatherCity
        for city in cities {
            let item = NSMenuItem(title: city,
                                  action: #selector(selectCity(_:)), keyEquivalent: "")
            item.representedObject = city
            if city == currentCity { item.state = .on }
            cityMenu.addItem(item)
        }
        let cityItem = NSMenuItem(title: "\(viewModel.weather.emoji) 城市", action: nil, keyEquivalent: "")
        cityItem.submenu = cityMenu
        menu.addItem(cityItem)
        menu.addItem(.separator())

        // 开机自启
        let launchItem = NSMenuItem(title: "开机自启",
                                    action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        if SMAppService.mainApp.status == .enabled { launchItem.state = .on }
        menu.addItem(launchItem)
        menu.addItem(.separator())

        // 关闭
        let quitItem = NSMenuItem(title: "关闭 TokenClock",
                                  action: #selector(quitApp(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // 在整个面板上启用右键菜单
        panel.menu = menu
    }

    // MARK: - 菜单 Actions

    @objc private func setOpacity(_ sender: NSMenuItem) {
        let value = Double(sender.tag) / 100.0
        panel.alphaValue = value
        viewModel.windowOpacity = value
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        if sender.state == .on {
            sender.state = .off
            panel.level = .normal
            viewModel.alwaysOnTop = false
        } else {
            sender.state = .on
            panel.level = .floating
            viewModel.alwaysOnTop = true
        }
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

    @objc private func selectCity(_ sender: NSMenuItem) {
        guard let city = sender.representedObject as? String else { return }
        viewModel.weatherCity = city
        // 重新设置菜单以更新勾选状态
        setupRightClickMenu()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(sender)
    }
}

// MARK: - 主视图容器

struct MainView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            ClockContentView(viewModel: viewModel)

            if viewModel.isExpanded {
                DetailDropdownView(tools: viewModel.tools)
            }
        }
        .frame(width: 260)
        .onChange(of: viewModel.isExpanded) { _, newValue in
            NotificationCenter.default.post(name: .toggleExpanded, object: newValue)
        }
    }
}

extension Notification.Name {
    static let toggleExpanded = Notification.Name("toggleExpanded")
}
