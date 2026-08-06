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
    private let cmdApi: Int32 = 100         // copy endpoint (same action as macOS normal)
    private let cmdSettings: Int32 = 120
    private let cmdEditCustom: Int32 = 140
    private let cmdOpacityBase: Int32 = 150 // + 0...3 -> 25/50/75/100%
    private let cmdRefresh: Int32 = 160
    private let cmdSavedThemeBase: Int32 = 200
    private let cmdDeleteThemeBase: Int32 = 240

    /// 当前浮窗边长（pt）。表盘半径 = size/2 - 24；classic 主题按 radius 116（medium）校准，
    /// 其余尺寸由 winrender 按 r/116 等比缩放。切换尺寸时此值同步更新并 resize 窗口。
    private var currentSize: Int32 = 280

    private let model = WindowsUsageModel()
    fileprivate var api: WindowsAPIServer?
    private var didStartup = false
    private var weatherObserver: NSObjectProtocol?
    private var weatherString = ""           // 由 .weatherUpdated 通知更新，render 时叠到盘面顶部
    private var weatherInfo: WeatherInfo?     // 展开详情时复用 macOS normal 的当前天气与 12 小时趋势
    private var scanCount: Int = 0           // 天气刷新节流（每 20 次扫描≈10 分钟刷新一次）
    private var detailsVisible = false       // 左键托盘切换：展开后窗口变高，盘面下方列工具明细
    private var currentHeight: Int32 = 280   // 当前窗口高（收起 = currentSize；展开 = +明细区）
    private var lastTrayToggle = Date.distantPast   // 左键去抖（双击连发两次）
    private var expandedDetailKeys: Set<String> = []
    private var renderedDetailRows: [DetailRow] = []
    fileprivate var customCfg = WindowsCustomTheme()   // 自定义主题编辑器在用的配置
    fileprivate var editorDlg: UnsafeMutableRawPointer?
    fileprivate var settingsDlg: UnsafeMutableRawPointer?
    fileprivate var editingSavedThemeId: String?

    func run() {
        win_set_dpi_aware()

        currentSize = windowSize(for: clockSizeRaw)
        currentHeight = clockDiameter(for: clockSizeRaw)

        var cb = win_callbacks()
        cb.ctx = nil
        cb.on_paint = appPaint
        cb.on_tick = appTick
        cb.on_scan = appScan
        cb.on_tray_click = appTrayClick
        cb.on_build_menu = appBuildMenu
        cb.on_menu_cmd = appMenuCmd
        cb.on_destroy = appDestroy
        cb.on_click = appClick
        cb.scan_interval_ms = Int32(AppConfig.Timers.dataScan * 1000)   // 30s 数据扫描
        cb.width = currentSize
        cb.height = currentHeight
        cb.initial_opacity = windowOpacity
        // 上次窗口位置（无记录则居中）
        if WindowsPreferences.shared.object(forKey: SettingsKey.windowsWindowX.rawValue) != nil {
            cb.use_initial_position = 1
            cb.initial_x = Int32(UserDefaults.standard.int(for: .windowsWindowX))
            cb.initial_y = Int32(UserDefaults.standard.int(for: .windowsWindowY))
        }
        cb.class_name = nil
        cb.window_title = nil

        // 数据层：本地 API 服务（可经菜单关闭）+ 首次全量扫描（后台线程，下一帧起渲染真实用量）
        if apiEnabled {
            api = WindowsAPIServer(model: model)
            api?.start(port: apiPort)
        }
        scheduleScan(incremental: false)

        // 天气：监听 .weatherUpdated → 格式化暂存，render 时叠到盘面顶部；按选定城市抓取
        weatherObserver = NotificationCenter.default.addObserver(forName: .weatherUpdated, object: nil, queue: nil) { [weak self] note in
            guard let info = note.object as? WeatherInfo else { return }
            self?.updateWeather(info)
        }
        WindowsWeather.refresh(forCity: selectedCity)

        // 调试/截图钩子（正常流程不经此）：TC_DETAIL 启动即展开；TC_SETTINGS 启动即开设置对话框。
        if ProcessInfo.processInfo.environment["TC_DETAIL"] != nil { detailsVisible = true }
        if ProcessInfo.processInfo.environment["TC_SETTINGS"] != nil { openSettings() }
        if ProcessInfo.processInfo.environment["TC_CUSTOM"] != nil { openCustomThemeEditor() }

        _ = win_run(&cb)
    }

    /// 截图用：在时钟窗口处弹出右键菜单（TrackPopupMenu 阻塞，菜单保持打开便于截屏）。
    private var menuShown = false
    fileprivate func showTrayMenuForCapture() {
        guard !menuShown else { return }
        menuShown = true
        guard let m = menu_create() else { return }
        buildMenu(menu: m)
        var x: Int32 = 0, y: Int32 = 0
        win_get_pos(win_self(), &x, &y)
        menu_show_at(m, win_self(), x + currentSize / 2, y + 8)
    }

    private func updateWeather(_ info: WeatherInfo) {
        weatherInfo = info
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
        let todayLabel = L10n.shared.tr("clock.todayTokens")
        let messages = L10n.shared.tr("clock.messagesCount", UsageAggregator.totalMessages(tools))
        let top = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let tool1 = top.first.map { "\($0.emoji) \($0.abbreviation)" } ?? ""
        let tool2 = top.count > 1 ? "\(top[1].emoji) \(top[1].abbreviation)" : ""
        let rate = UsageAggregator.rateEmoji(tools)
        let dialImagePath = selectedTheme == .glass
            ? (Bundle.module.url(forResource: "glass_disc", withExtension: "png")?.path ?? "")
            : ""
        let weather = weatherString

        // 展开态：主题卡片内的交互行。父行默认收起，点击后才展示 session/工具贡献。
        let detailRows = detailsVisible ? buildDetailRows(tools) : []
        renderedDetailRows = detailRows
        let detailText = detailRows.map(\.encoded).joined(separator: "\n")
        let L = L10n.shared
        let detailControls = [L.tr("detail.groupBySession"), L.tr("detail.groupByModel"), L.tr("detail.percent")].joined(separator: "\t")
        let detailHeader = [L.tr(groupingMode == .model ? "detail.model" : "detail.instance"),
                            L.tr(showPercentage ? "detail.share" : "detail.todayUsage"),
                            L.tr("detail.messages"), groupingMode == .session ? L.tr("detail.cacheRate") : ""].joined(separator: "\t")
        let forecast = detailsVisible ? forecastOverlay() : (summary: "", slots: "", visible: false)

        // 卡片布局：gap14 + 天气趋势 76（有城市时）+ controls/header 94 + row×30。
        let dialHeight = clockDiameter(for: clockSizeRaw)
        let S = Double(dialHeight / 2 - 4) / 116.0
        let forecastHeight = forecast.visible ? 76.0 : 0.0
        let newHeight: Int32 = detailsVisible
            ? dialHeight + Int32((108.0 + forecastHeight + 30.0 * Double(detailRows.count)) * S)
            : dialHeight
        if newHeight != currentHeight {
            currentHeight = newHeight
            win_resize(win_self(), currentSize, currentHeight)
        }

        var wt = selectedTheme.winTheme
        Self.withCStrings([date, weather, todayLabel, tokens, messages, tool1, tool2, rate, dialImagePath,
                           detailText, detailControls, detailHeader, forecast.summary, forecast.slots]) { ptrs in
            var ov = win_overlay()
            ov.date = ptrs[0]
            ov.weather = ptrs[1]
            ov.today_label = ptrs[2]
            ov.tokens = ptrs[3]
            ov.messages = ptrs[4]
            ov.tool_left1 = ptrs[5]
            ov.tool_left2 = ptrs[6]
            ov.rate = ptrs[7]
            ov.dial_image_path = ptrs[8]
            ov.detail_text = ptrs[9]
            ov.detail_controls = ptrs[10]
            ov.detail_header = ptrs[11]
            ov.forecast_summary = ptrs[12]
            ov.forecast_slots = ptrs[13]
            ov.detail_grouping = groupingMode == .model ? 1 : 0
            ov.detail_percentage = showPercentage ? 1 : 0
            win_render_clock(currentSize, currentHeight,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                             &wt, &ov)
        }

        // 截图钩子：首帧画完后在时钟处弹出右键菜单（阻塞，保持打开）。
        if !menuShown, ProcessInfo.processInfo.environment["TC_MENU"] != nil {
            showTrayMenuForCapture()
        }
    }

    /// Encode the same current 3-hour slot plus the next three slots used by
    /// DetailDropdownView on macOS. The renderer owns only presentation, so the selection and
    /// Fahrenheit conversion stay here with the shared weather model.
    private func forecastOverlay() -> (summary: String, slots: String, visible: Bool) {
        guard let weatherInfo, !weatherInfo.cityName.isEmpty else { return ("", "", false) }
        let f = useFahrenheit
        func converted(_ c: Int) -> Int { f ? Int(Double(c) * 9.0 / 5.0 + 32.0) : c }
        func hour(_ raw: String) -> Int {
            if raw.count <= 2 { return Int(raw) ?? 0 }
            return Int(raw.prefix(raw.count == 3 ? 1 : 2)) ?? 0
        }

        let currentHour = effectiveCalendar.component(.hour, from: Date())
        var currentIndex = 0
        var previousHour = -1
        for (index, slot) in weatherInfo.forecast.enumerated() {
            let h = hour(slot.time)
            if previousHour > h { break }
            if h <= currentHour { currentIndex = index } else { break }
            previousHour = h
        }
        let selected = (0..<4).compactMap { offset -> HourlyForecast? in
            let index = currentIndex + offset
            return weatherInfo.forecast.indices.contains(index) ? weatherInfo.forecast[index] : nil
        }
        let slots = selected.map { slot in
            String(format: "%02d:00", hour(slot.time)) + "|\(slot.emoji)|\(converted(slot.tempC))°"
        }.joined(separator: "\t")
        let summary = "\(weatherInfo.emoji) \(weatherInfo.cityName) \(converted(weatherInfo.temperature))°\(f ? "F" : "C")|\(L10n.shared.tr("detail.forecast"))"
        return (summary, slots, true)
    }

    private struct DetailRow {
        let key: String?
        let label: String
        let value: String
        let messages: String
        let cache: String
        let isChild: Bool
        let expanded: Bool

        var encoded: String {
            let kind = isChild ? "C" : (expanded ? "V" : "P")
            return "\(kind)|\(label)\t\(value)\t\(messages)\t\(cache)"
        }
    }

    /// 对齐 macOS DetailDropdownView：按会话/按模型、百分比、可展开父行以及消息/缓存列。
    private func buildDetailRows(_ tools: [ToolUsage]) -> [DetailRow] {
        let L = L10n.shared
        let pct = showPercentage
        if let mock = ProcessInfo.processInfo.environment["TC_MOCK"] {
            let modelMode = mock == "model" || groupingMode == .model
            let parents: [(String, String, Int, Int, [(String, Int, Int)])] = modelMode
                ? [("gpt-5", "🧠", 820_000, 118, [("Codex", 600_000, 80), ("Claude Code", 220_000, 38)]),
                   ("claude-sonnet", "✳", 290_000, 42, [("Claude Code", 180_000, 27), ("Codex", 110_000, 15)]),
                   ("grok-4", "⚡", 42_000, 9, [])]
                : [("Codex", "●", 1_000_000, 146, [("主项目重构", 620_000, 84), ("文档翻译", 380_000, 62)]),
                   ("Claude Code", "✳", 150_000, 31, [("session-7a", 90_000, 18)]),
                   ("Grok", "⚡", 42_000, 9, [])]
            let grand = parents.reduce(0) { $0 + $1.2 }
            var rows: [DetailRow] = []
            for p in parents {
                let key = "mock:\(p.0)"
                let open = expandedDetailKeys.contains(key)
                rows.append(DetailRow(key: key, label: "\(p.1) \(p.0)", value: rowValue(p.2, formatted: TokenFormat.compact(p.2), grand: grand, pct: pct), messages: "\(p.3)", cache: modelMode ? "" : "42%", isChild: false, expanded: open))
                if open {
                    for child in p.4 { rows.append(DetailRow(key: nil, label: child.0, value: rowValue(child.1, formatted: TokenFormat.compact(child.1), grand: grand, pct: pct), messages: "\(child.2)", cache: "", isChild: true, expanded: false)) }
                }
            }
            return Array(rows.prefix(14))
        }

        let active = tools.filter { $0.todayTokens > 0 }
        guard !active.isEmpty else {
            return [DetailRow(key: nil, label: L.language == .en ? "No AI usage today" : "今日暂无 AI 用量", value: "—", messages: "—", cache: "", isChild: true, expanded: false)]
        }
        let grand = active.reduce(0) { $0 + $1.todayTokens }
        var rows: [DetailRow] = []
        if groupingMode == .model {
            let groups = UsageAggregator.groupedByModel(tools, unknownLabel: L.tr("detail.unknownModel"))
            for group in groups.prefix(10) {
                let key = "model:\(group.id)"
                let open = expandedDetailKeys.contains(key)
                rows.append(DetailRow(key: key, label: "\(group.emoji) \(group.name)", value: rowValue(group.totalTokens, formatted: group.formattedTokens, grand: grand, pct: pct), messages: "\(group.totalMessages)", cache: "", isChild: false, expanded: open))
                if open {
                    for contribution in group.contributions.prefix(5) {
                        rows.append(DetailRow(key: nil, label: "\(contribution.emoji) \(contribution.tool)", value: rowValue(contribution.tokens, formatted: TokenFormat.compact(contribution.tokens), grand: grand, pct: pct), messages: "\(contribution.messages)", cache: "", isChild: true, expanded: false))
                    }
                }
            }
        } else {
            for tool in active.prefix(10) {
                let key = "tool:\(tool.id)"
                let open = expandedDetailKeys.contains(key)
                let cache = tool.cacheRate > 0 ? String(format: "%.0f%%", tool.cacheRate * 100) : "—"
                rows.append(DetailRow(key: key, label: "\(tool.emoji) \(tool.name)", value: rowValue(tool.todayTokens, formatted: tool.formattedTokens, grand: grand, pct: pct), messages: "\(tool.todayMessages)", cache: cache, isChild: false, expanded: open))
                if open {
                    let sessions = tool.sessions.filter { $0.todayTokens > 0 }.sorted { $0.todayTokens > $1.todayTokens }
                    for session in sessions.prefix(5) {
                        let source = session.source.map { " · \($0)" } ?? ""
                        rows.append(DetailRow(key: nil, label: "\(session.displayName)\(source)", value: rowValue(session.todayTokens, formatted: session.formattedTokens, grand: grand, pct: pct), messages: "\(session.todayMessages)", cache: "", isChild: true, expanded: false))
                    }
                }
            }
        }
        return Array(rows.prefix(14))
    }

    /// pct=true ⇒ "42%"；否则用紧凑 token 数。
    private func rowValue(_ tokens: Int, formatted: String, grand: Int, pct: Bool) -> String {
        guard pct, grand > 0 else { return formatted }
        let percent = Double(tokens) / Double(grand) * 100
        return percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    private var showPercentage: Bool { UserDefaults.standard.bool(for: .dropdownShowPercentage) }

    private enum GroupingMode { case session, model }
    private var groupingMode: GroupingMode {
        if ProcessInfo.processInfo.environment["TC_GROUPING"] == "model" { return .model }
        if ProcessInfo.processInfo.environment["TC_GROUPING"] == "session" { return .session }
        return UserDefaults.standard.int(for: .dropdownGrouping) == 1 ? .model : .session
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
            toggleDetailsDebounced()
        }
    }

    /// Main-window click callback. The upper clock toggles the dropdown; controls and parent
    /// rows inside the card update their own state without turning the whole panel into a drag area.
    func click(x: Int32, y: Int32) {
        let dialHeight = clockDiameter(for: clockSizeRaw)
        if y < dialHeight {
            toggleDetailsDebounced()
            return
        }
        guard detailsVisible else { return }
        let scale = Double(dialHeight / 2 - 4) / 116.0
        let localY = Double(y - dialHeight) / scale - 14.0
        let forecastHeight = (weatherInfo?.cityName.isEmpty == false) ? 76.0 : 0.0
        let controlsY = localY - forecastHeight
        if controlsY >= 8, controlsY < 34 {
            let requested: GroupingMode = Double(x) < Double(currentSize) / 2.0 ? .session : .model
            UserDefaults.standard.setInt(requested == .model ? 1 : 0, for: .dropdownGrouping)
            expandedDetailKeys.removeAll()
            render()
        } else if controlsY >= 38, controlsY < 60 {
            UserDefaults.standard.setBool(!showPercentage, for: .dropdownShowPercentage)
            render()
        } else if controlsY >= 86 {
            let index = Int((controlsY - 86) / 30)
            guard renderedDetailRows.indices.contains(index), let key = renderedDetailRows[index].key else { return }
            if expandedDetailKeys.contains(key) { expandedDetailKeys.remove(key) }
            else { expandedDetailKeys.insert(key) }
            render()
        }
    }

    private func toggleDetailsDebounced() {
        let now = Date()
        guard now.timeIntervalSince(lastTrayToggle) > 0.35 else { return }
        lastTrayToggle = now
        detailsVisible.toggle()
        render()
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
        let savedThemes = WindowsSavedCustomTheme.loadAll()
        if !savedThemes.isEmpty, let savedMenu = menu_create() {
            let activeId = UserDefaults.standard.string(for: .activeCustomThemeId)
            for (index, saved) in savedThemes.prefix(32).enumerated() {
                addMenuItem(savedMenu, cmdSavedThemeBase + Int32(index), saved.name,
                            selectedTheme == .custom && activeId == saved.id)
            }
            addSubmenu(menu, L.tr("menu.myClockFaces"), savedMenu)
            if let deleteMenu = menu_create() {
                for (index, saved) in savedThemes.prefix(32).enumerated() {
                    addMenuItem(deleteMenu, cmdDeleteThemeBase + Int32(index), saved.name, false)
                }
                addSubmenu(menu, L.language == .en ? "Delete Custom Face" : "删除自定义表盘", deleteMenu)
            }
        }
        addMenuItem(menu, cmdEditCustom, L.language == .en ? "✏️ Edit Custom Theme…" : "✏️ 编辑自定义主题…", false)
        // 尺寸子菜单
        if let sm = menu_create() {
            addMenuItem(sm, cmdSizeSmall,  L.tr("size.small"),      clockSizeRaw == "small")
            addMenuItem(sm, cmdSizeMedium, L.tr("size.medium"),     clockSizeRaw != "small" && clockSizeRaw != "large" && clockSizeRaw != "extraLarge")
            addMenuItem(sm, cmdSizeLarge,  L.tr("size.large"),      clockSizeRaw == "large")
            addMenuItem(sm, cmdSizeXL,     L.tr("size.extraLarge"), clockSizeRaw == "extraLarge")
            addSubmenu(menu, L.tr("menu.size"), sm)
        }
        addMenuItem(menu, cmdApi, L.tr("menu.api", Int(apiPort)), false)
        addSeparator(menu)
        if let om = menu_create() {
            for (index, percent) in Self.opacityLevels.enumerated() {
                addMenuItem(om, cmdOpacityBase + Int32(index), "\(percent)%",
                            Int((windowOpacity * 100).rounded()) == percent)
            }
            addSubmenu(menu, L.tr("menu.opacity"), om)
        }
        addSeparator(menu)
        addMenuItem(menu, cmdTopmost, L.tr("menu.alwaysOnTop"), alwaysOnTop)
        addSeparator(menu)

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
        addMenuItem(menu, cmdRefresh, L.language == .en ? "Refresh Now" : "立即刷新", false)
        addSeparator(menu)
        addMenuItem(menu, cmdSettings, L.tr("menu.settings"), false)
        addSeparator(menu)
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
        case cmdSettings:   openSettings()
        case cmdEditCustom: openCustomThemeEditor()
        case cmdTempC:      setUseFahrenheit(false)
        case cmdTempF:      setUseFahrenheit(true)
        case cmdApi:        copyAPIEndpoint()
        case cmdRefresh:
            scheduleScan(incremental: false)
            WindowsWeather.refresh(forCity: selectedCity)
        case let c where c >= cmdCityBase && c < cmdCityBase + Int32(Self.cities.count):
            setCity(Self.cities[Int(c - cmdCityBase)])
        case let c where c >= cmdTzBase && c < cmdTzBase + Int32(Self.timezones.count):
            setTimezone(Self.timezones[Int(c - cmdTzBase)])
        case let c where c >= cmdOpacityBase && c < cmdOpacityBase + Int32(Self.opacityLevels.count):
            setOpacity(Self.opacityLevels[Int(c - cmdOpacityBase)])
        case let c where c >= cmdSavedThemeBase && c < cmdSavedThemeBase + 32:
            applySavedTheme(index: Int(c - cmdSavedThemeBase))
        case let c where c >= cmdDeleteThemeBase && c < cmdDeleteThemeBase + 32:
            deleteSavedTheme(index: Int(c - cmdDeleteThemeBase))
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
        let dialHeight = clockDiameter(for: raw)
        currentSize = sz
        currentHeight = dialHeight
        win_resize(win_self(), sz, dialHeight)
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

    /// Windows 原生设置面板：provider 开关/路径/浏览/自动探测、Cursor 云端、API、
    /// 速率窗口与四档热力阈值。所有修改只在 OK 后原子落盘；Cancel 不产生副作用。
    private func openSettings() {
        let L = L10n.shared
        let names = Self.providerNames
        let enabled = Set(UserDefaults.standard.stringArray(for: .enabledTools) ?? names)
        let en = L.language == .en
        guard let dlg = dlg_create(en ? "TokenClock Settings" : "TokenClock 设置", 720, 780) else { return }
        settingsDlg = dlg
        defer {
            settingsDlg = nil
            dlg_destroy(dlg)
        }
        dlg_add_title(dlg, en ? "TokenClock Settings" : "TokenClock 设置", 20, 12, 470, 30)
        dlg_add_push(dlg, 700, en ? "Auto Detect" : "自动探测", 570, 14, 120, 28)
        dlg_add_static(dlg, en ? "Select providers and verify their Windows data directories." : "选择 provider，并确认其 Windows 数据目录。", 22, 48, 650, 20)
        dlg_add_sep(dlg, 20, 72, 670)
        dlg_add_static(dlg, en ? "Provider" : "Provider", 24, 80, 130, 18)
        dlg_add_static(dlg, en ? "Data source path" : "数据源路径", 168, 80, 365, 18)
        let rowH: Int32 = 28
        let topY: Int32 = 100
        for (i, name) in names.enumerated() {
            let y = topY + Int32(i * Int(rowH))
            dlg_add_check(dlg, 300 + Int32(i), name, 20, y, 140, rowH, enabled.contains(name) ? 1 : 0)
            dlg_add_edit(dlg, 200 + Int32(i), pathFor(name), 168, y, 370, 26)
            dlg_add_push(dlg, 600 + Int32(i), en ? "Browse…" : "浏览…", 548, y, 82, 26)
        }
        let sy = topY + Int32(names.count * Int(rowH)) + 4
        dlg_add_sep(dlg, 20, sy, 670)
        dlg_add_check(dlg, 410, en ? "Cursor cloud usage (sends credentials to cursor.com)" : "Cursor 云端用量（会向 cursor.com 发送凭证）",
                      24, sy + 8, 440, 24, UserDefaults.standard.bool(for: .cursorCloudFetchEnabled, default: true) ? 1 : 0)
        dlg_add_check(dlg, 411, en ? "Local API server" : "本地 API 服务", 24, sy + 34, 170, 24, apiEnabled ? 1 : 0)
        dlg_add_static(dlg, en ? "Port" : "端口", 205, sy + 38, 42, 20)
        dlg_add_edit(dlg, 412, "\(apiPort)", 250, sy + 34, 72, 24)

        dlg_add_static(dlg, en ? "Rate window (min)" : "速率窗口（分钟）", 350, sy + 38, 135, 20)
        dlg_add_edit(dlg, 400, "\(model.rateWindowMinutes)", 490, sy + 34, 70, 24)
        let burst = UserDefaults.standard.int(for: .rateBurst, default: 500_000)
        let hot = UserDefaults.standard.int(for: .rateHot, default: 100_000)
        let active = UserDefaults.standard.int(for: .rateActive, default: 20_000)
        let calm = UserDefaults.standard.int(for: .rateCalm, default: 2_000)
        let ty = sy + 66
        dlg_add_static(dlg, en ? "Burst" : "爆发", 24, ty + 3, 52, 20); dlg_add_edit(dlg, 401, "\(burst)", 78, ty, 92, 24)
        dlg_add_static(dlg, en ? "Hot" : "高热", 190, ty + 3, 42, 20); dlg_add_edit(dlg, 402, "\(hot)", 235, ty, 92, 24)
        dlg_add_static(dlg, en ? "Active" : "活跃", 350, ty + 3, 52, 20); dlg_add_edit(dlg, 403, "\(active)", 405, ty, 92, 24)
        dlg_add_static(dlg, en ? "Calm" : "平静", 520, ty + 3, 45, 20); dlg_add_edit(dlg, 404, "\(calm)", 568, ty, 92, 24)

        let by = ty + 36
        dlg_add_sep(dlg, 20, by, 670)
        dlg_add_push(dlg, 1, en ? "Save" : "保存", 470, by + 12, 100, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 585, by + 12, 100, 30)
        if dlg_modal_cb(dlg, settingsCmdCb, nil) == 1 {
            var onNames: [String] = []
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            for (i, name) in names.enumerated() {
                if dlg_check_get(dlg, 300 + Int32(i)) == 1 { onNames.append(name) }
                dlg_edit_get(dlg, 200 + Int32(i), buf, 1024)
                setPath(name, String(cString: buf))
            }
            let final = onNames
            UserDefaults.standard.setStringArray(final, for: .enabledTools)
            model.updateEnabledTools(Set(final))
            model.reloadProviderPaths()
            dlg_edit_get(dlg, 400, buf, 1024)
            if let mins = Int(String(cString: buf)), mins > 0 {
                UserDefaults.standard.setInt(mins, for: .rateWindow)
            }
            let thresholdKeys: [SettingsKey] = [.rateBurst, .rateHot, .rateActive, .rateCalm]
            var thresholds: [Int] = []
            for (offset, key) in thresholdKeys.enumerated() {
                dlg_edit_get(dlg, 401 + Int32(offset), buf, 1024)
                thresholds.append(max(0, Int(String(cString: buf)) ?? UserDefaults.standard.int(for: key)))
            }
            var b = thresholds[0], h = thresholds[1], a = thresholds[2], c = thresholds[3]
            if h >= b { h = max(0, b - 1) }
            if a >= h { a = max(0, h - 1) }
            if c >= a { c = max(0, a - 1) }
            if a <= c { a = c + 1 }; if h <= a { h = a + 1 }; if b <= h { b = h + 1 }
            for (key, value) in zip(thresholdKeys, [b, h, a, c]) { UserDefaults.standard.setInt(value, for: key) }
            UserDefaults.standard.setBool(dlg_check_get(dlg, 410) == 1, for: .cursorCloudFetchEnabled)

            let wasAPIEnabled = apiEnabled
            let oldPort = apiPort
            dlg_edit_get(dlg, 412, buf, 1024)
            let requestedPort = Int(String(cString: buf)) ?? Int(oldPort)
            let newPort = (1024...65535).contains(requestedPort) ? requestedPort : Int(oldPort)
            UserDefaults.standard.setInt(newPort, for: .apiServerPort)
            let newAPIEnabled = dlg_check_get(dlg, 411) == 1
            if wasAPIEnabled && !newAPIEnabled { api?.pause() }
            UserDefaults.standard.setBool(newAPIEnabled, for: .apiServerEnabled)
            if newAPIEnabled {
                if api == nil { api = WindowsAPIServer(model: model) }
                api?.start(port: UInt16(newPort))
            }
            scheduleScan(incremental: false)
            render()
        }
    }

    /// Settings dialog callbacks: per-provider folder picker and full path re-detection.
    fileprivate func handleSettingsCmd(_ id: Int32) {
        guard let dlg = settingsDlg else { return }
        if id >= 600 && id < 600 + Int32(Self.providerNames.count) {
            let index = Int(id - 600)
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
            defer { buf.deallocate() }
            dlg_edit_get(dlg, 200 + Int32(index), buf, 2048)
            let initial = String(cString: buf)
            let title = L10n.shared.language == .en ? "Select \(Self.providerNames[index]) data directory" : "选择 \(Self.providerNames[index]) 数据目录"
            let selected = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
            defer { selected.deallocate() }
            let picked = title.withCString { tp in
                initial.withCString { ip in win_pick_folder(dlg, tp, ip, selected, 2048) }
            }
            if picked == 1 { dlg_set_text(dlg, 200 + Int32(index), String(cString: selected)) }
        } else if id == 700 {
            let summary = PathDetector.runFullDetection()
            for result in summary.results where result.exists {
                if let index = Self.providerServiceIDs.firstIndex(of: result.service) {
                    dlg_set_text(dlg, 200 + Int32(index), result.detectedPath)
                    // Detection is evidence-backed: enable only providers with a readable source.
                    // Existing user selections for missing providers remain untouched.
                    dlg_set_check(dlg, 300 + Int32(index), 1)
                }
            }
            let label = L10n.shared.language == .en
                ? "Detected \(summary.foundCount)/\(summary.totalCount)"
                : "已探测 \(summary.foundCount)/\(summary.totalCount)"
            dlg_set_text(dlg, 700, label)
        }
    }

    private func pathFor(_ name: String) -> String {
        switch name {
        case "OpenClaw": return PathConfig.openclawHome()
        case "Claude Code": return PathConfig.claudeCodeHome()
        case "Gemini CLI": return PathConfig.geminiHome()
        case "Codex": return PathConfig.codexHome()
        case "Hermes": return PathConfig.hermesHome()
        case "OpenCode": return PathConfig.opencodeHome()
        case "Qwen Code": return PathConfig.qwenHome()
        case "Copilot": return PathConfig.copilotHome()
        case "Grok": return PathConfig.grokHome()
        case "Aider": return PathConfig.aiderHome()
        case "Antigravity": return PathConfig.antigravityHome()
        case "Cline": return PathConfig.clineHome()
        case "Continue": return PathConfig.continueHome()
        case "Cursor Agent": return PathConfig.cursorAgentHome()
        default: return ""
        }
    }

    private func setPath(_ name: String, _ p: String) {
        switch name {
        case "OpenClaw": PathConfig.setOpenclawPath(p)
        case "Claude Code": PathConfig.setClaudeCodePath(p)
        case "Gemini CLI": PathConfig.setGeminiPath(p)
        case "Codex": PathConfig.setCodexPath(p)
        case "Hermes": PathConfig.setHermesPath(p)
        case "OpenCode": PathConfig.setOpenCodePath(p)
        case "Qwen Code": PathConfig.setQwenPath(p)
        case "Copilot": PathConfig.setCopilotPath(p)
        case "Grok": PathConfig.setGrokPath(p)
        case "Aider": PathConfig.setAiderPath(p)
        case "Antigravity": PathConfig.setAntigravityPath(p)
        case "Cline": PathConfig.setClinePath(p)
        case "Continue": PathConfig.setContinuePath(p)
        case "Cursor Agent": PathConfig.setCursorAgentPath(p)
        default: break
        }
    }

    fileprivate func shutdown() {
        var x: Int32 = 0, y: Int32 = 0
        win_get_pos(win_self(), &x, &y)
        UserDefaults.standard.setInt(Int(x), for: .windowsWindowX)
        UserDefaults.standard.setInt(Int(y), for: .windowsWindowY)
        if let weatherObserver {
            NotificationCenter.default.removeObserver(weatherObserver)
            self.weatherObserver = nil
        }
        api?.stop()
    }

    /// Full custom-face editor: named presets, 16 colors, hand geometry, ticks/numbers/decoration.
    private func openCustomThemeEditor() {
        let L = L10n.shared, en = L.language == .en
        let saved = WindowsSavedCustomTheme.loadAll()
        let activeId = UserDefaults.standard.string(for: .activeCustomThemeId)
        if let active = saved.first(where: { $0.id == activeId }) {
            customCfg = active.config
            editingSavedThemeId = active.id
        } else {
            customCfg = WindowsCustomTheme.load()
            editingSavedThemeId = nil
        }
        guard let dlg = dlg_create(en ? "Custom Clock Face" : "自定义表盘", 700, 650) else { return }
        editorDlg = dlg
        defer {
            editorDlg = nil
            editingSavedThemeId = nil
            dlg_destroy(dlg)
        }
        dlg_add_title(dlg, en ? "Custom Clock Face" : "自定义表盘", 20, 10, 430, 30)
        dlg_add_static(dlg, en ? "Name" : "名称", 22, 48, 60, 22)
        let activeName = saved.first(where: { $0.id == activeId })?.name ?? (en ? "Custom \(saved.count + 1)" : "自定义 \(saved.count + 1)")
        dlg_add_edit(dlg, 540, activeName, 84, 44, 350, 28)
        dlg_add_push(dlg, 560, en ? "New" : "新建", 450, 44, 90, 28)
        dlg_add_sep(dlg, 20, 78, 650)
        let labels = en
            ? ["Dial", "Rim", "Hour", "Minute", "Second", "Cap outer", "Cap inner", "Numbers",
               "Ticks", "Major ticks", "Text", "Subtext", "Panel bg", "Panel text", "Panel subtext", "Panel border"]
            : ["表盘", "外环", "时针", "分针", "秒针", "中心帽外", "中心帽内", "数字",
               "刻度", "主刻度", "文字", "次文字", "面板背景", "面板文字", "面板次文字", "面板边框"]
        let rowH: Int32 = 30, topY: Int32 = 86
        for i in 0..<WindowsCustomTheme.colorKeys.count {
            let column = i / 8, row = i % 8
            let x: Int32 = column == 0 ? 22 : 352
            let y = topY + Int32(row) * rowH
            dlg_add_static(dlg, labels[i], x, y + 5, 112, 22)
            dlg_add_push(dlg, 500 + Int32(i), WindowsCustomTheme.hex(customCfg.colorField(i)), x + 116, y, 180, 28)
        }
        let gy = topY + 8 * rowH + 10
        dlg_add_static(dlg, en ? "Hand style" : "指针样式", 22, gy + 5, 92, 22)
        dlg_add_push(dlg, 520, handStyleLabel(customCfg.handStyle), 118, gy, 138, 28)
        dlg_add_static(dlg, en ? "Rim width" : "外环宽度", 282, gy + 5, 90, 22)
        dlg_add_edit(dlg, 530, formatNumber(customCfg.rimWidth), 376, gy, 72, 28)
        dlg_add_push(dlg, 553, numberStyleLabel(), 480, gy, 145, 28)

        let wy = gy + 36
        dlg_add_static(dlg, en ? "Hand widths H / M / S" : "指针宽度 时 / 分 / 秒", 22, wy + 5, 180, 22)
        dlg_add_edit(dlg, 531, formatNumber(customCfg.hourWidth), 205, wy, 64, 26)
        dlg_add_edit(dlg, 532, formatNumber(customCfg.minuteWidth), 278, wy, 64, 26)
        dlg_add_edit(dlg, 533, formatNumber(customCfg.secondWidth), 351, wy, 64, 26)
        dlg_add_static(dlg, en ? "Lengths H / M / S" : "长度 时 / 分 / 秒", 438, wy + 5, 120, 22)
        dlg_add_edit(dlg, 534, formatNumber(customCfg.hourLength), 562, wy, 55, 26)
        dlg_add_edit(dlg, 535, formatNumber(customCfg.minuteLength), 622, wy, 55, 26)
        let ly = wy + 32
        dlg_add_static(dlg, en ? "Second length" : "秒针长度", 438, ly + 5, 120, 22)
        dlg_add_edit(dlg, 536, formatNumber(customCfg.secondLength), 562, ly, 55, 26)
        dlg_add_check(dlg, 550, en ? "Show numbers" : "显示数字", 22, ly, 130, 26, customCfg.showNumbers ? 1 : 0)
        dlg_add_check(dlg, 551, en ? "Tick marks" : "显示刻度", 160, ly, 120, 26, customCfg.showTicks ? 1 : 0)
        dlg_add_check(dlg, 552, en ? "Sky decoration" : "天空装饰", 288, ly, 130, 26, customCfg.hasDecoration ? 1 : 0)
        let by = ly + 38
        dlg_add_sep(dlg, 20, by, 650)
        dlg_add_push(dlg, 1, en ? "Save & Apply" : "保存并应用", 455, by + 12, 110, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 580, by + 12, 100, 30)
        if dlg_modal_cb(dlg, customCmdCb, nil) == 1 {
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
            defer { buf.deallocate() }
            func readDouble(_ id: Int32, _ fallback: Double, range: ClosedRange<Double>) -> Double {
                dlg_edit_get(dlg, id, buf, 512)
                guard let value = Double(String(cString: buf)), value.isFinite else { return fallback }
                return min(range.upperBound, max(range.lowerBound, value))
            }
            customCfg.rimWidth = readDouble(530, customCfg.rimWidth, range: 0...20)
            customCfg.hourWidth = readDouble(531, customCfg.hourWidth, range: 0.5...20)
            customCfg.minuteWidth = readDouble(532, customCfg.minuteWidth, range: 0.5...20)
            customCfg.secondWidth = readDouble(533, customCfg.secondWidth, range: 0.5...20)
            customCfg.hourLength = readDouble(534, customCfg.hourLength, range: 0.1...0.95)
            customCfg.minuteLength = readDouble(535, customCfg.minuteLength, range: 0.1...0.95)
            customCfg.secondLength = readDouble(536, customCfg.secondLength, range: 0.1...0.98)
            customCfg.showNumbers = dlg_check_get(dlg, 550) == 1
            customCfg.showTicks = dlg_check_get(dlg, 551) == 1
            customCfg.hasDecoration = dlg_check_get(dlg, 552) == 1
            customCfg.save()
            dlg_edit_get(dlg, 540, buf, 512)
            let proposed = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = proposed.isEmpty ? (en ? "Custom Face" : "自定义表盘") : proposed
            var themes = WindowsSavedCustomTheme.loadAll()
            let id: String
            if let editingSavedThemeId, let index = themes.firstIndex(where: { $0.id == editingSavedThemeId }) {
                themes[index].name = name; themes[index].config = customCfg; id = editingSavedThemeId
            } else {
                id = UUID().uuidString
                themes.append(WindowsSavedCustomTheme(id: id, name: name, config: customCfg))
            }
            WindowsSavedCustomTheme.saveAll(themes)
            UserDefaults.standard.setString(id, for: .activeCustomThemeId)
            UserDefaults.standard.setString(WindowsClockTheme.custom.rawValue, for: .selectedTheme)
            render()
        }
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func numberStyleLabel() -> String {
        let en = L10n.shared.language == .en
        return customCfg.numberStyle == 2 ? (en ? "Chinese numbers ▾" : "中文数字 ▾") : (en ? "Arabic numbers ▾" : "阿拉伯数字 ▾")
    }

    private func handStyleLabel(_ s: Int) -> String {
        let en = L10n.shared.language == .en
        switch s {
        case 1: return en ? "Tapered ▾" : "锥形 ▾"
        case 2: return en ? "Lance ▾" : "菱形 ▾"
        case 3: return en ? "Sword ▾" : "剑形 ▾"
        default: return en ? "Round ▾" : "圆头 ▾"
        }
    }

    /// 编辑器内按钮点击（由 dlg_modal_cb 回调）：颜色按钮弹取色器、指针样式循环。
    fileprivate func handleCustomCmd(_ id: Int32) {
        if id >= 500 && id < 500 + Int32(WindowsCustomTheme.colorKeys.count) {
            let i = Int(id - 500)
            var out: UInt32 = 0
            if win_pick_color(customCfg.colorField(i), &out) == 1 {
                customCfg.setColorField(i, out)
                if let dlg = editorDlg { dlg_set_text(dlg, id, WindowsCustomTheme.hex(out)) }
            }
        } else if id == 520 {
            customCfg.handStyle = (customCfg.handStyle + 1) % 4
            if let dlg = editorDlg { dlg_set_text(dlg, 520, handStyleLabel(customCfg.handStyle)) }
        } else if id == 553 {
            customCfg.numberStyle = customCfg.numberStyle == 2 ? 1 : 2
            if let dlg = editorDlg { dlg_set_text(dlg, 553, numberStyleLabel()) }
        } else if id == 560 {
            customCfg = WindowsCustomTheme()
            editingSavedThemeId = nil
            if let dlg = editorDlg {
                let count = WindowsSavedCustomTheme.loadAll().count + 1
                dlg_set_text(dlg, 540, L10n.shared.language == .en ? "Custom \(count)" : "自定义 \(count)")
                for i in 0..<WindowsCustomTheme.colorKeys.count { dlg_set_text(dlg, 500 + Int32(i), WindowsCustomTheme.hex(customCfg.colorField(i))) }
                dlg_set_text(dlg, 520, handStyleLabel(customCfg.handStyle)); dlg_set_text(dlg, 530, formatNumber(customCfg.rimWidth))
                dlg_set_text(dlg, 531, formatNumber(customCfg.hourWidth)); dlg_set_text(dlg, 532, formatNumber(customCfg.minuteWidth)); dlg_set_text(dlg, 533, formatNumber(customCfg.secondWidth))
                dlg_set_text(dlg, 534, formatNumber(customCfg.hourLength)); dlg_set_text(dlg, 535, formatNumber(customCfg.minuteLength)); dlg_set_text(dlg, 536, formatNumber(customCfg.secondLength))
                dlg_set_check(dlg, 550, customCfg.showNumbers ? 1 : 0); dlg_set_check(dlg, 551, customCfg.showTicks ? 1 : 0); dlg_set_check(dlg, 552, customCfg.hasDecoration ? 1 : 0)
                dlg_set_text(dlg, 553, numberStyleLabel())
            }
        }
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
        if t != .custom { UserDefaults.standard.remove(.activeCustomThemeId) }
        render()
    }

    private func applySavedTheme(index: Int) {
        let themes = WindowsSavedCustomTheme.loadAll()
        guard themes.indices.contains(index) else { return }
        let saved = themes[index]
        saved.config.save()
        UserDefaults.standard.setString(saved.id, for: .activeCustomThemeId)
        UserDefaults.standard.setString(WindowsClockTheme.custom.rawValue, for: .selectedTheme)
        render()
    }

    private func deleteSavedTheme(index: Int) {
        var themes = WindowsSavedCustomTheme.loadAll()
        guard themes.indices.contains(index) else { return }
        let name = themes[index].name
        let title = L10n.shared.language == .en ? "Delete Clock Face" : "删除表盘"
        let message = L10n.shared.language == .en
            ? "Delete “\(name)”? This cannot be undone."
            : "确定删除“\(name)”吗？此操作无法撤销。"
        let confirmed = title.withCString { titlePtr in
            message.withCString { messagePtr in win_confirm(titlePtr, messagePtr) == 1 }
        }
        guard confirmed else { return }
        let removed = themes.remove(at: index)
        WindowsSavedCustomTheme.saveAll(themes)
        if UserDefaults.standard.string(for: .activeCustomThemeId) == removed.id {
            UserDefaults.standard.remove(.activeCustomThemeId)
            UserDefaults.standard.setString(WindowsClockTheme.classic.rawValue, for: .selectedTheme)
        }
        render()
    }

    private func windowSize(for raw: String) -> Int32 {
        switch raw {
        case "small":      return 280
        case "large":      return 380
        case "extraLarge": return 440
        default:            return 320   // medium: 240pt dial + 40pt transparent margin each side
        }
    }

    private func clockDiameter(for raw: String) -> Int32 {
        switch raw {
        case "small":      return 200
        case "large":      return 300
        case "extraLarge": return 360
        default:            return 240
        }
    }

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(for: .alwaysOnTop, default: true) }
        set { UserDefaults.standard.setBool(newValue, for: .alwaysOnTop) }
    }

    private var launchAtLogin: Bool { win_autostart_get() == 1 }
    private func setLaunchAtLogin(_ on: Bool) { _ = win_autostart_set(on ? 1 : 0) }

    // 城市 / 温度 / 时区 / API（镜像 macOS SettingsKey）
    private static let providerNames = ["OpenClaw", "Claude Code", "Gemini CLI", "Codex", "Hermes", "OpenCode",
                                        "Qwen Code", "Copilot", "Grok", "Aider", "Antigravity", "Cline", "Continue", "Cursor Agent"]
    private static let providerServiceIDs = ["openclaw", "claudeCode", "gemini", "codex", "hermes", "opencode",
                                             "qwen", "copilot", "grok", "aider", "antigravity", "cline", "continue", "cursorAgent"]
    private static let cities = ["auto", "Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York"]
    private static let timezones = ["auto", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo", "Asia/Singapore", "America/New_York", "Europe/London", "America/Los_Angeles"]
    private static let opacityLevels = [25, 50, 75, 100]

    private var selectedCity: String {
        let value = ProcessInfo.processInfo.environment["TC_CITY"] ?? UserDefaults.standard.string(for: .selectedCity) ?? "auto"
        return value.caseInsensitiveCompare("auto") == .orderedSame ? "auto" : value
    }
    private var selectedTimezoneRaw: String {
        ProcessInfo.processInfo.environment["TC_TZ"] ?? UserDefaults.standard.string(for: .selectedTimezone) ?? "auto"
    }
    private var useFahrenheit: Bool { UserDefaults.standard.bool(for: .useFahrenheit) }

    private var apiEnabled: Bool {
        get {
            UserDefaults.standard.bool(for: .apiServerEnabled, default: true)
        }
        set {
            UserDefaults.standard.setBool(newValue, for: .apiServerEnabled)
            if newValue { if api == nil { api = WindowsAPIServer(model: model) }; api?.start(port: apiPort) }
            else { api?.pause() }
        }
    }

    private var apiPort: UInt16 {
        let stored = UserDefaults.standard.int(for: .apiServerPort)
        return (1024...65535).contains(stored) ? UInt16(stored) : AppConfig.LocalServer.defaultPort
    }

    private var windowOpacity: Double {
        let value = UserDefaults.standard.double(for: .windowOpacity, default: 1.0)
        return min(1.0, max(0.25, value))
    }

    private func setOpacity(_ percent: Int) {
        let value = Double(percent) / 100.0
        UserDefaults.standard.setDouble(value, for: .windowOpacity)
        win_set_opacity(win_self(), value)
        render()
    }

    private func copyAPIEndpoint() {
        let endpoint = "http://localhost:\(apiPort)\(AppConfig.LocalServer.usageEndpoint)"
        endpoint.withCString { _ = win_clipboard_set_text($0) }
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
        if c == "auto" { return L10n.shared.language == .en ? "Auto" : "自动" }
        return c
    }
    private func tzLabel(_ id: String) -> String {
        switch id {
        case "Asia/Hong_Kong": return L10n.shared.tr("tz.hongKong")
        case "Asia/Shanghai":  return L10n.shared.tr("tz.shanghai")
        case "Asia/Tokyo":     return L10n.shared.tr("tz.tokyo")
        case "Asia/Singapore": return L10n.shared.tr("tz.singapore")
        case "America/New_York": return L10n.shared.tr("tz.newYork")
        case "Europe/London": return L10n.shared.tr("tz.london")
        case "America/Los_Angeles": return L10n.shared.tr("tz.losAngeles")
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
private let appClick: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, x, y in
    WindowsApp.shared.click(x: x, y: y)
}
private let customCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleCustomCmd(id)   // 自定义主题编辑器内按钮点击
}
private let settingsCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleSettingsCmd(id)
}
