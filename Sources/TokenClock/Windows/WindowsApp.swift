import Foundation
import Win32Shim

/// Windows UI 驱动。Win32Shim（C）负责窗口/托盘/菜单/消息循环；表盘由 winrender.cpp（GDI+ +
/// UpdateLayeredWindow）逐像素 alpha 合成。数据层复用共享 Services（WindowsUsageModel 接 14 个
/// usage 服务），本地 API 服务由 winhttp.c（Winsock）后台线程承载。托盘菜单 + 位置/自启/语言等
/// 设置经 UserDefaults 持久化（镜像 macOS SettingsKey）。
final class WindowsApp: @unchecked Sendable {
    static let shared = WindowsApp()
    private init() {}

    // MARK: - 命令 ID
    private let cmdQuit: Int32 = 1
    private let cmdTopmost: Int32 = 10
    private let cmdSizeSmall: Int32 = 20, cmdSizeMedium: Int32 = 21
    private let cmdSizeLarge: Int32 = 22, cmdSizeXL: Int32 = 23
    private let cmdLangHans: Int32 = 30, cmdLangHant: Int32 = 31, cmdLangEn: Int32 = 32
    private let cmdLaunch: Int32 = 40
    private let cmdAbout: Int32 = 50

    /// 当前浮窗边长（pt）。表盘半径 = size/2 - 24；classic 主题按 radius 116（medium）校准，
    /// 其余尺寸由 winrender 按 r/116 等比缩放。切换尺寸时此值同步更新并 resize 窗口。
    private var currentSize: Int32 = 280

    private let model = WindowsUsageModel()
    fileprivate var api: WindowsAPIServer?
    private var didStartup = false
    private var weatherString = ""           // 由 .weatherUpdated 通知更新，render 时叠到盘面顶部
    private var scanCount: Int = 0           // 天气刷新节流（每 20 次扫描≈10 分钟刷新一次）

    func run() {
        win_set_dpi_aware()

        currentSize = windowSize(for: clockSizeRaw)

        var cb = win_callbacks()
        cb.ctx = nil
        cb.on_paint = appPaint
        cb.on_tick = appTick
        cb.on_scan = appScan
        cb.on_tray_click = appTrayClick
        cb.on_build_menu = appBuildMenu
        cb.on_menu_cmd = appMenuCmd
        cb.on_destroy = appDestroy
        cb.scan_interval_ms = Int32(AppConfig.Timers.dataScan * 1000)   // 30s 数据扫描
        cb.width = currentSize
        cb.height = currentSize
        cb.initial_opacity = 1.0
        // 上次窗口位置（无记录则居中）
        if UserDefaults.standard.object(forKey: Self.posXKey) != nil {
            cb.use_initial_position = 1
            cb.initial_x = Int32(UserDefaults.standard.integer(forKey: Self.posXKey))
            cb.initial_y = Int32(UserDefaults.standard.integer(forKey: Self.posYKey))
        }
        cb.class_name = nil
        cb.window_title = nil

        // 数据层：本地 API 服务 + 首次全量扫描（后台线程，下一帧起渲染真实用量）
        api = WindowsAPIServer(model: model)
        api?.start()
        scheduleScan(incremental: false)

        // 天气（IP 定位）：监听 .weatherUpdated → 格式化暂存，render 时叠到盘面顶部
        NotificationCenter.default.addObserver(forName: .weatherUpdated, object: nil, queue: nil) { [weak self] note in
            guard let info = note.object as? WeatherInfo else { return }
            self?.updateWeather(info)
        }
        WindowsWeather.refresh()

        _ = win_run(&cb)
    }

    private func updateWeather(_ info: WeatherInfo) {
        let f = UserDefaults.standard.bool(for: .useFahrenheit)
        let temp = f ? Int(Double(info.temperature) * 9.0 / 5.0 + 32.0) : info.temperature
        weatherString = "\(info.emoji) \(temp)°\(f ? "F" : "C")"
    }

    /// 渲染一帧：忠实 classic 表盘 + 叠加真实用量（日期 / token 计数 / 消息数 / 活跃工具）。
    /// 天气（IP 定位）尚未接入，暂留空。表盘配色/几何由 winrender.cpp 内置并按尺寸缩放。
    func render() {
        if !didStartup {
            didStartup = true
            applyStartupAppearance()
        }

        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let date = dateFmt.string(from: now)

        let tools = model.tools
        let tokens = TokenFormat.compact(UsageAggregator.totalTokens(tools))
        let messages = L10n.shared.tr("clock.messagesCount", UsageAggregator.totalMessages(tools))
        let top = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let tool1 = top.first.map { "\($0.emoji) \($0.abbreviation)" } ?? ""
        let tool2 = top.count > 1 ? "\(top[1].emoji) \(top[1].abbreviation)" : ""
        let weather = weatherString

        Self.withCStrings([date, weather, tokens, messages, tool1, tool2]) { ptrs in
            var ov = win_overlay()
            ov.date = ptrs[0]
            ov.weather = ptrs[1]
            ov.tokens = ptrs[2]
            ov.messages = ptrs[3]
            ov.tool_left1 = ptrs[4]
            ov.tool_left2 = ptrs[5]
            win_render_clock(currentSize, currentSize,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                             &ov)
        }
    }

    /// 首帧前应用持久化的外观：非置顶时取消 TOPMOST（窗口默认创建为置顶）。
    private func applyStartupAppearance() {
        if !alwaysOnTop { win_set_topmost(win_self(), 0) }
    }

    /// 后台扫描用量；完成后下一个 1s tick 自动重绘出新数据（render 经 UpdateLayeredWindow，无需显式 invalidate）。
    fileprivate func scheduleScan(incremental: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.model.scan(incremental: incremental)
        }
        scanCount &+= 1
        if scanCount % 20 == 0 { WindowsWeather.refresh() }   // 每 ~10 分钟刷新一次天气
    }

    func trayClick(button: Int32) { /* TODO: 左键展开详情面板（P6） */ }

    // MARK: - 托盘菜单

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        guard let menu else { return }
        let L = L10n.shared

        // 尺寸子菜单
        if let sm = menu_create() {
            addMenuItem(sm, cmdSizeSmall,  L.tr("size.small"),      clockSizeRaw == "small")
            addMenuItem(sm, cmdSizeMedium, L.tr("size.medium"),     clockSizeRaw != "small" && clockSizeRaw != "large" && clockSizeRaw != "extraLarge")
            addMenuItem(sm, cmdSizeLarge,  L.tr("size.large"),      clockSizeRaw == "large")
            addMenuItem(sm, cmdSizeXL,     L.tr("size.extraLarge"), clockSizeRaw == "extraLarge")
            addSubmenu(menu, L.tr("menu.size"), sm)
        }
        addMenuItem(menu, cmdTopmost, L.tr("menu.alwaysOnTop"), alwaysOnTop)
        addSeparator(menu)

        // 语言子菜单
        if let lm = menu_create() {
            let lang = L.language
            addMenuItem(lm, cmdLangHans, AppLanguage.zhHans.displayName, lang == .zhHans)
            addMenuItem(lm, cmdLangHant, AppLanguage.zhHant.displayName, lang == .zhHant)
            addMenuItem(lm, cmdLangEn,   AppLanguage.en.displayName,     lang == .en)
            addSubmenu(menu, L.tr("menu.language"), lm)
        }
        addMenuItem(menu, cmdLaunch, L.tr("menu.launchAtLogin"), launchAtLogin)
        addSeparator(menu)
        addMenuItem(menu, cmdAbout, L.tr("menu.about"), false)
        addMenuItem(menu, cmdQuit, L.tr("menu.quit"), false)
    }

    func menuCmd(cmd: Int32) {
        switch cmd {
        case cmdQuit:       win_quit(win_self())
        case cmdTopmost:
            alwaysOnTop.toggle()
            win_set_topmost(win_self(), alwaysOnTop ? 1 : 0)
        case cmdSizeSmall:  setSize("small")
        case cmdSizeMedium: setSize("medium")
        case cmdSizeLarge:  setSize("large")
        case cmdSizeXL:     setSize("extraLarge")
        case cmdLangHans:   setLang(.zhHans)
        case cmdLangHant:   setLang(.zhHant)
        case cmdLangEn:     setLang(.en)
        case cmdLaunch:     setLaunchAtLogin(!launchAtLogin)
        case cmdAbout:      showAbout()
        default: break
        }
    }

    // MARK: - 设置（持久化）

    private func setSize(_ raw: String) {
        UserDefaults.standard.setString(raw, for: .clockSize)
        UserDefaults.standard.setBool(true, for: .clockSizeUserChosen)
        let sz = windowSize(for: raw)
        currentSize = sz
        win_resize(win_self(), sz, sz)
        render()
    }

    private func setLang(_ lang: AppLanguage) {
        L10n.shared.language = lang          // didSet 落盘；dateFmt 为实例计算属性，下一帧即生效
        render()
    }

    private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let body = "TokenClock \(version)\nMIT License\n\ngithub.com/Neo-Isshin/TokenClock"
        body.withCString { bp in
            "TokenClock".withCString { tp in
                win_message_box(tp, bp)
            }
        }
    }

    fileprivate func shutdown() {
        var x: Int32 = 0, y: Int32 = 0
        win_get_pos(win_self(), &x, &y)
        UserDefaults.standard.set(Int(x), forKey: Self.posXKey)
        UserDefaults.standard.set(Int(y), forKey: Self.posYKey)
        api?.stop()
    }

    // MARK: - 状态读取

    private var clockSizeRaw: String { UserDefaults.standard.string(for: .clockSize) ?? "medium" }

    private func windowSize(for raw: String) -> Int32 {
        switch raw {
        case "small":      return 240
        case "large":      return 340
        case "extraLarge": return 400
        default:           return 280   // medium
        }
    }

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(for: .alwaysOnTop, default: true) }
        set { UserDefaults.standard.setBool(newValue, for: .alwaysOnTop) }
    }

    private var launchAtLogin: Bool { win_autostart_get() == 1 }
    private func setLaunchAtLogin(_ on: Bool) { _ = win_autostart_set(on ? 1 : 0) }

    /// 顶部日期格式器（镜像 ViewModel.dateString：zh `M月d日 EEEE`，en 本地化模板）。
    /// 实例计算属性——语言切换后下一帧即用新 locale。
    private var dateFmt: DateFormatter {
        let f = DateFormatter()
        switch L10n.shared.language {
        case .zhHans: f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        case .zhHant: f.locale = Locale(identifier: "zh_TW"); f.dateFormat = "M月d日 EEEE"
        case .en:     f.locale = Locale(identifier: "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        }
        return f
    }

    private static let posXKey = "TCWinWindowX"
    private static let posYKey = "TCWinWindowY"

    // MARK: - C 菜单辅助

    private func addMenuItem(_ menu: UnsafeMutableRawPointer?, _ id: Int32, _ label: String, _ checked: Bool) {
        label.withCString { p in menu_add_item(menu, id, p, checked ? 1 : 0) }
    }
    private func addSubmenu(_ menu: UnsafeMutableRawPointer?, _ label: String, _ sub: UnsafeMutableRawPointer?) {
        label.withCString { p in menu_add_submenu(menu, p, sub) }
    }
    private func addSeparator(_ menu: UnsafeMutableRawPointer?) {
        menu_add_separator(menu)
    }

    /// 把一组 Swift String 的 C 字符串指针在同一个活跃作用域内交给 body——
    /// 这样 win_render_clock 调用期间所有指针都有效，无需 strdup/释放。
    private static func withCStrings<T>(_ ss: [String], _ body: ([UnsafePointer<CChar>]) -> T) -> T {
        func recur(_ i: Int, _ acc: [UnsafePointer<CChar>]) -> T {
            if i == ss.count { return body(acc) }
            return ss[i].withCString { p in recur(i + 1, acc + [p]) }
        }
        return recur(0, [])
    }
}

// MARK: - @convention(c) trampolines → WindowsApp.shared

private let appPaint: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, _, _, _ in
    WindowsApp.shared.render()      // layered window: render via UpdateLayeredWindow
}
private let appTick: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.render()      // 每秒重绘一帧（秒针走动 + 用量刷新）
}
private let appScan: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.scheduleScan(incremental: true)
}
private let appTrayClick: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, button in
    WindowsApp.shared.trayClick(button: button)
}
private let appBuildMenu: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, menu in
    WindowsApp.shared.buildMenu(menu: menu)
}
private let appMenuCmd: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, cmd in
    WindowsApp.shared.menuCmd(cmd: cmd)
}
private let appDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.shutdown()    // 落盘窗口位置 + 关闭本地 API 服务
}
