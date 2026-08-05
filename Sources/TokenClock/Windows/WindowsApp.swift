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
    private let cmdThemeBase: Int32 = 60   // + 索引 → WindowsClockTheme.allCases[i]
    private let cmdTempC: Int32 = 70, cmdTempF: Int32 = 71
    private let cmdCityBase: Int32 = 80    // + 索引 → cities[i]
    private let cmdTzBase: Int32 = 90      // + 索引 → timezones[i]
    private let cmdApi: Int32 = 100

    /// 当前浮窗边长（pt）。表盘半径 = size/2 - 24；classic 主题按 radius 116（medium）校准，
    /// 其余尺寸由 winrender 按 r/116 等比缩放。切换尺寸时此值同步更新并 resize 窗口。
    private var currentSize: Int32 = 280

    private let model = WindowsUsageModel()
    fileprivate var api: WindowsAPIServer?
    private var didStartup = false
    private var weatherString = ""           // 由 .weatherUpdated 通知更新，render 时叠到盘面顶部
    private var scanCount: Int = 0           // 天气刷新节流（每 20 次扫描≈10 分钟刷新一次）
    private var detailsVisible = false       // 左键托盘切换：展开后窗口变高，盘面下方列工具明细
    private var currentHeight: Int32 = 280   // 当前窗口高（收起 = currentSize；展开 = +明细区）
    private var lastTrayToggle = Date.distantPast   // 左键去抖（双击连发两次）

    func run() {
        win_set_dpi_aware()

        currentSize = windowSize(for: clockSizeRaw)
        currentHeight = currentSize

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

        // 数据层：本地 API 服务（可经菜单关闭）+ 首次全量扫描（后台线程，下一帧起渲染真实用量）
        if apiEnabled {
            api = WindowsAPIServer(model: model)
            api?.start()
        }
        scheduleScan(incremental: false)

        // 天气：监听 .weatherUpdated → 格式化暂存，render 时叠到盘面顶部；按选定城市抓取
        NotificationCenter.default.addObserver(forName: .weatherUpdated, object: nil, queue: nil) { [weak self] note in
            guard let info = note.object as? WeatherInfo else { return }
            self?.updateWeather(info)
        }
        WindowsWeather.refresh(forCity: selectedCity)

        _ = win_run(&cb)
    }

    private func updateWeather(_ info: WeatherInfo) {
        let f = UserDefaults.standard.bool(for: .useFahrenheit)
        let temp = f ? Int(Double(info.temperature) * 9.0 / 5.0 + 32.0) : info.temperature
        weatherString = "\(info.emoji) \(temp)°\(f ? "F" : "C")"
    }

    /// 渲染一帧：忠实 classic 表盘 + 叠加真实用量（日期 / 天气 / token 计数 / 消息数 / 活跃工具）。
    /// 展开态额外在盘面下方列工具明细，并把窗口高度撑开。表盘配色/几何由 winrender.cpp 内置并按尺寸缩放。
    func render() {
        if !didStartup {
            didStartup = true
            applyStartupAppearance()
        }

        let now = Date()
        let comps = effectiveCalendar.dateComponents([.hour, .minute, .second], from: now)
        let date = dateFmt.string(from: now)

        let tools = model.tools
        let tokens = TokenFormat.compact(UsageAggregator.totalTokens(tools))
        let messages = L10n.shared.tr("clock.messagesCount", UsageAggregator.totalMessages(tools))
        let top = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let tool1 = top.first.map { "\($0.emoji) \($0.abbreviation)" } ?? ""
        let tool2 = top.count > 1 ? "\(top[1].emoji) \(top[1].abbreviation)" : ""
        let weather = weatherString

        // 展开态：盘面下方工具明细（多行）。空则给一句占位。
        let detailLines = detailsVisible ? buildDetailLines(tools) : []
        let detailText = detailLines.joined(separator: "\n")

        // 窗口高度：收起 = currentSize；展开 = currentSize + 明细区（与 winrender 的 16*S 起始 + 19*S 行高 对齐）
        let S = Double(currentSize / 2 - 24) / 116.0
        let newHeight: Int32 = detailsVisible
            ? currentSize + Int32((26.0 + 19.0 * Double(detailLines.count)) * S)
            : currentSize
        if newHeight != currentHeight {
            currentHeight = newHeight
            win_resize(win_self(), currentSize, currentHeight)
        }

        var wt = selectedTheme.winTheme
        Self.withCStrings([date, weather, tokens, messages, tool1, tool2, detailText]) { ptrs in
            var ov = win_overlay()
            ov.date = ptrs[0]
            ov.weather = ptrs[1]
            ov.tokens = ptrs[2]
            ov.messages = ptrs[3]
            ov.tool_left1 = ptrs[4]
            ov.tool_left2 = ptrs[5]
            ov.detail_text = ptrs[6]
            win_render_clock(currentSize, currentHeight,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                             &wt, &ov)
        }
    }

    /// 展开态的明细行：活跃工具（按 token 排序）「emoji 简写  用量」，最多 10 行；无用量时一句占位。
    private func buildDetailLines(_ tools: [ToolUsage]) -> [String] {
        let active = tools.filter { $0.isActive || $0.todayTokens > 0 }
        if active.isEmpty {
            switch L10n.shared.language {
            case .zhHans, .zhHant: return ["今日暂无 AI 用量"]
            case .en:              return ["No AI usage today"]
            }
        }
        return active.prefix(10).map { "\($0.emoji) \($0.abbreviation)  \($0.formattedTokens)" }
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
        if scanCount % 20 == 0 { WindowsWeather.refresh(forCity: selectedCity) }   // 每 ~10 分钟刷新一次天气
    }

    func trayClick(button: Int32) {
        // 左键托盘图标：切换详情面板（盘面下方展开工具明细）。
        // 双击会连发两次 LBUTTONUP，用 0.35s 去抖保证单击/双击都只切一次。
        if button == 1 {
            let now = Date()
            if now.timeIntervalSince(lastTrayToggle) > 0.35 {
                lastTrayToggle = now
                detailsVisible.toggle()
                render()
            }
        }
    }

    // MARK: - 托盘菜单

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        guard let menu else { return }
        let L = L10n.shared

        // 表盘子菜单（8 个内置主题）
        if let tm = menu_create() {
            for (i, theme) in WindowsClockTheme.allCases.enumerated() {
                addMenuItem(tm, cmdThemeBase + Int32(i), theme.displayName, theme.rawValue == selectedTheme.rawValue)
            }
            addSubmenu(menu, L.tr("menu.clockFace"), tm)
        }
        // 尺寸子菜单
        if let sm = menu_create() {
            addMenuItem(sm, cmdSizeSmall,  L.tr("size.small"),      clockSizeRaw == "small")
            addMenuItem(sm, cmdSizeMedium, L.tr("size.medium"),     clockSizeRaw != "small" && clockSizeRaw != "large" && clockSizeRaw != "extraLarge")
            addMenuItem(sm, cmdSizeLarge,  L.tr("size.large"),      clockSizeRaw == "large")
            addMenuItem(sm, cmdSizeXL,     L.tr("size.extraLarge"), clockSizeRaw == "extraLarge")
            addSubmenu(menu, L.tr("menu.size"), sm)
        }
        addMenuItem(menu, cmdTopmost, L.tr("menu.alwaysOnTop"), alwaysOnTop)

        // 温度单位
        if let um = menu_create() {
            addMenuItem(um, cmdTempC, L.tr("menu.celsius"), !useFahrenheit)
            addMenuItem(um, cmdTempF, L.tr("menu.fahrenheit"), useFahrenheit)
            addSubmenu(menu, L.tr("menu.temperature"), um)
        }
        // 城市（Auto=IP 定位 + 6 预置）
        if let cm = menu_create() {
            for (i, c) in Self.cities.enumerated() {
                addMenuItem(cm, cmdCityBase + Int32(i), cityLabel(c), c == selectedCity)
            }
            addSubmenu(menu, L.tr("menu.city"), cm)
        }
        // 时区
        if let zm = menu_create() {
            for (i, tz) in Self.timezones.enumerated() {
                addMenuItem(zm, cmdTzBase + Int32(i), tzLabel(tz), tz == selectedTimezoneRaw)
            }
            addSubmenu(menu, L.tr("menu.timezone"), zm)
        }
        addSeparator(menu)

        // 语言子菜单
        if let lm = menu_create() {
            let lang = L.language
            addMenuItem(lm, cmdLangHans, AppLanguage.zhHans.displayName, lang == .zhHans)
            addMenuItem(lm, cmdLangHant, AppLanguage.zhHant.displayName, lang == .zhHant)
            addMenuItem(lm, cmdLangEn,   AppLanguage.en.displayName,     lang == .en)
            addSubmenu(menu, L.tr("menu.language"), lm)
        }
        addMenuItem(menu, cmdApi, L.language == .en ? "🔌 API Server" : "🔌 API 服务", apiEnabled)
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
        case cmdTempC:      setUseFahrenheit(false)
        case cmdTempF:      setUseFahrenheit(true)
        case cmdApi:        apiEnabled.toggle()
        case let c where c >= cmdCityBase && c < cmdCityBase + Int32(Self.cities.count):
            setCity(Self.cities[Int(c - cmdCityBase)])
        case let c where c >= cmdTzBase && c < cmdTzBase + Int32(Self.timezones.count):
            setTimezone(Self.timezones[Int(c - cmdTzBase)])
        case let c where c >= cmdThemeBase && c < cmdThemeBase + Int32(WindowsClockTheme.allCases.count):
            setTheme(WindowsClockTheme.allCases[Int(c - cmdThemeBase)])
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

    private var selectedTheme: WindowsClockTheme {
        // 调试覆盖：TC_THEME=midnight 等可临时强制主题（不落盘）。生产取持久化值。
        if let env = ProcessInfo.processInfo.environment["TC_THEME"],
           let t = WindowsClockTheme(rawValue: env) { return t }
        return WindowsClockTheme(rawValue: UserDefaults.standard.string(for: .selectedTheme) ?? "classic") ?? .classic
    }
    private func setTheme(_ t: WindowsClockTheme) {
        UserDefaults.standard.setString(t.rawValue, for: .selectedTheme)
        render()
    }

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

    // 城市 / 温度 / 时区 / API（镜像 macOS SettingsKey）
    private static let cities = ["Auto", "Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York"]
    private static let timezones = ["auto", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo"]

    private var selectedCity: String {
        ProcessInfo.processInfo.environment["TC_CITY"] ?? UserDefaults.standard.string(for: .selectedCity) ?? "Auto"
    }
    private var selectedTimezoneRaw: String {
        ProcessInfo.processInfo.environment["TC_TZ"] ?? UserDefaults.standard.string(for: .selectedTimezone) ?? "auto"
    }
    private var useFahrenheit: Bool { UserDefaults.standard.bool(for: .useFahrenheit) }

    private var apiEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.apiServerEnabled.rawValue) == nil { return true }
            return UserDefaults.standard.bool(for: .apiServerEnabled)
        }
        set {
            UserDefaults.standard.setBool(newValue, for: .apiServerEnabled)
            if newValue { if api == nil { api = WindowsAPIServer(model: model) }; api?.start() }
            else { api?.stop() }
        }
    }

    /// 按选定时区取 Calendar（auto ⇒ 系统时区）。
    private var effectiveCalendar: Calendar {
        var c = Calendar.current
        let raw = selectedTimezoneRaw
        c.timeZone = (raw == "auto") ? TimeZone.current : (TimeZone(identifier: raw) ?? TimeZone.current)
        return c
    }

    private func setUseFahrenheit(_ v: Bool) {
        UserDefaults.standard.setBool(v, for: .useFahrenheit)
        WindowsWeather.refresh(forCity: selectedCity)   // 重新按新单位格式化温度
        render()
    }
    private func setCity(_ c: String) {
        UserDefaults.standard.setString(c, for: .selectedCity)
        WindowsWeather.refresh(forCity: c)
        render()
    }
    private func setTimezone(_ tz: String) {
        UserDefaults.standard.setString(tz, for: .selectedTimezone)
        render()   // 时钟按新时区走
    }

    private func cityLabel(_ c: String) -> String {
        if c == "Auto" { return L10n.shared.language == .en ? "Auto" : "自动" }
        return c
    }
    private func tzLabel(_ id: String) -> String {
        switch id {
        case "Asia/Hong_Kong": return L10n.shared.tr("tz.hongKong")
        case "Asia/Shanghai":  return L10n.shared.tr("tz.shanghai")
        case "Asia/Tokyo":     return L10n.shared.tr("tz.tokyo")
        default:               return L10n.shared.tr("tz.auto")
        }
    }

    /// 顶部日期格式器（镜像 ViewModel.dateString：zh `M月d日 EEEE`，en 本地化模板）。
    /// 实例计算属性——语言切换后下一帧即用新 locale。
    private var dateFmt: DateFormatter {
        let f = DateFormatter()
        switch L10n.shared.language {
        case .zhHans: f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        case .zhHant: f.locale = Locale(identifier: "zh_TW"); f.dateFormat = "M月d日 EEEE"
        case .en:     f.locale = Locale(identifier: "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        }
        let raw = selectedTimezoneRaw
        f.timeZone = (raw == "auto") ? TimeZone.current : (TimeZone(identifier: raw) ?? TimeZone.current)
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
