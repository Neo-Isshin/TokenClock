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
    private let cmdShowPercent: Int32 = 110
    private let cmdSettings: Int32 = 120
    private let cmdGroupByModel: Int32 = 130
    private let cmdEditCustom: Int32 = 140

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
    fileprivate var customCfg = WindowsCustomTheme()   // 自定义主题编辑器在用的配置
    fileprivate var editorDlg: UnsafeMutableRawPointer?

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

        // 窗口高度：收起 = currentSize；展开 = currentSize + 卡片区（gap14 + pad24 + 行×20 + 底8，与 winrender 对齐）
        let S = Double(currentSize / 2 - 24) / 116.0
        let newHeight: Int32 = detailsVisible
            ? currentSize + Int32((46.0 + 20.0 * Double(detailLines.count)) * S)
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

        // 截图钩子：首帧画完后在时钟处弹出右键菜单（阻塞，保持打开）。
        if !menuShown, ProcessInfo.processInfo.environment["TC_MENU"] != nil {
            showTrayMenuForCapture()
        }
    }

    /// 展开态明细：表头(工具数+总计) + 每个活跃工具(名+用量/百分比) + 该工具 top 会话(缩进)。
    /// 对齐 macOS DetailDropdownView：两种分组视图（by-session / by-model）+ 百分比开关。
    /// 行格式：表头行无 \t；数据行 = "label\tvalue"（前导空格为缩进）。winrender 据此画卡片。
    private func buildDetailLines(_ tools: [ToolUsage]) -> [String] {
        if let m = ProcessInfo.processInfo.environment["TC_MOCK"] {   // 调试：无真实用量时预览卡片
            return m == "model"
                ? ["按模型 3 个  ·  总计 1.3M", "🤖 gpt-5\t820K", "     🤖 Codex\t600K", "     ✳️ Claude Code\t220K", "✳️ claude-sonnet\t290K", "     ✳️ Claude Code\t180K", "     🤖 Codex\t110K", "⚡ grok-4\t42K"]
                : ["今日 3 个工具  ·  总计 1.2M", "🤖 Codex\t1.0M", "     主项目重构\t620K", "     文档翻译\t380K", "✳️ Claude Code\t150K", "     session-7a\t90K", "⚡ Grok\t42K"]
        }
        let L = L10n.shared
        let pct = showPercentage
        let active = tools.filter { $0.todayTokens > 0 }
        if active.isEmpty {
            return [L.language == .en ? "No AI usage today" : "今日暂无 AI 用量"]
        }
        let grand = active.reduce(0) { $0 + $1.todayTokens }
        let total = pct ? "100%" : TokenFormat.compact(grand)
        var lines: [String] = []
        if groupingMode == .model {
            let groups = UsageAggregator.groupedByModel(tools, unknownLabel: L.tr("detail.unknownModel"))
            lines.append(L.language == .en ? "By model  ·  \(groups.count)  ·  \(total)" : "按模型 \(groups.count) 个  ·  总计 \(total)")
            for g in groups.prefix(8) {
                lines.append("\(g.emoji) \(g.name)\t\(rowValue(g.totalTokens, formatted: g.formattedTokens, grand: grand, pct: pct))")
                for c in g.contributions.prefix(3) {
                    lines.append("     \(c.emoji) \(c.tool)\t\(rowValue(c.tokens, formatted: TokenFormat.compact(c.tokens), grand: grand, pct: pct))")
                }
            }
        } else {
            lines.append(L.language == .en ? "Today \(active.count) tools  ·  \(total)" : "今日 \(active.count) 个工具  ·  总计 \(total)")
            for tool in active.prefix(6) {
                lines.append("\(tool.emoji) \(tool.name)\t\(rowValue(tool.todayTokens, formatted: tool.formattedTokens, grand: grand, pct: pct))")
                let sessions = tool.sessions.filter { $0.todayTokens > 0 }.sorted { $0.todayTokens > $1.todayTokens }.prefix(3)
                for s in sessions {
                    lines.append("     \(s.displayName)\t\(rowValue(s.todayTokens, formatted: s.formattedTokens, grand: grand, pct: pct))")
                }
            }
        }
        return lines
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
        addMenuItem(menu, cmdEditCustom, L.language == .en ? "✏️ Edit Custom Theme…" : "✏️ 编辑自定义主题…", false)
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
        addMenuItem(menu, cmdShowPercent, L.language == .en ? "Detail %" : "详情显示百分比", showPercentage)
        addMenuItem(menu, cmdGroupByModel, L.language == .en ? "Group by Model" : "按模型分组", groupingMode == .model)
        addMenuItem(menu, cmdLaunch, L.tr("menu.launchAtLogin"), launchAtLogin)
        addSeparator(menu)
        addMenuItem(menu, cmdSettings, L.tr("menu.settings"), false)
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
        case cmdApi:        apiEnabled.toggle()
        case cmdShowPercent:
            UserDefaults.standard.setBool(!showPercentage, for: .dropdownShowPercentage)
            render()
        case cmdGroupByModel:
            UserDefaults.standard.setInt(groupingMode == .model ? 0 : 1, for: .dropdownGrouping)
            render()
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

    /// 设置面板（对齐 macOS SettingsView 的核心）：14 个工具的「启用」勾选 + 数据源路径编辑。
    /// OK 即落盘 enabledTools + 各 PathConfig，并即时刷新用量。
    private func openSettings() {
        let L = L10n.shared
        let names = ["OpenClaw", "Claude Code", "Gemini CLI", "Codex", "Hermes", "OpenCode",
                     "Qwen Code", "Copilot", "Grok", "Aider", "Antigravity", "Cline", "Continue", "Cursor Agent"]
        let enabled = Set(UserDefaults.standard.stringArray(for: .enabledTools) ?? names)
        guard let dlg = dlg_create(L.language == .en ? "TokenClock Settings" : "TokenClock 设置", 640, 720) else { return }
        dlg_add_title(dlg, L.language == .en ? "⚙️ TokenClock Settings" : "⚙️ TokenClock 设置", 20, 16, 600, 30)
        dlg_add_static(dlg, L.language == .en ? "Enable each tool and point it at its log directory." : "启用要统计的工具，并指定其日志目录。", 22, 50, 580, 20)
        dlg_add_sep(dlg, 20, 78, 600)
        dlg_add_static(dlg, L.language == .en ? "Tool" : "工具", 24, 86, 120, 18)
        dlg_add_static(dlg, L.language == .en ? "Data source path" : "数据源路径", 168, 86, 440, 18)
        let rowH: Int32 = 30
        let topY: Int32 = 110
        for (i, name) in names.enumerated() {
            let y = topY + Int32(i * Int(rowH))
            dlg_add_check(dlg, 300 + Int32(i), name, 20, y, 140, rowH, enabled.contains(name) ? 1 : 0)
            dlg_add_edit(dlg, 200 + Int32(i), pathFor(name), 168, y, 446, rowH)
        }
        let ry = topY + Int32(names.count * Int(rowH)) + 6
        dlg_add_static(dlg, L.language == .en ? "Rate window (minutes)" : "速率窗口（分钟）", 24, ry + 4, 200, 22)
        dlg_add_edit(dlg, 400, "\(model.rateWindowMinutes)", 230, ry, 80, rowH)
        let by = ry + Int32(rowH) + 12
        dlg_add_sep(dlg, 20, by, 600)
        dlg_add_push(dlg, 1, "OK", 410, by + 14, 100, 30)
        dlg_add_push(dlg, 2, L.tr("about.close"), 520, by + 14, 100, 30)
        if dlg_modal(dlg) == 1 {
            var onNames: [String] = []
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            for (i, name) in names.enumerated() {
                if dlg_check_get(dlg, 300 + Int32(i)) == 1 { onNames.append(name) }
                dlg_edit_get(dlg, 200 + Int32(i), buf, 1024)
                setPath(name, String(cString: buf))
            }
            let final = onNames.isEmpty ? names : onNames
            UserDefaults.standard.setStringArray(final, for: .enabledTools)
            model.updateEnabledTools(Set(final))
            dlg_edit_get(dlg, 400, buf, 1024)
            if let mins = Int(String(cString: buf)), mins > 0 {
                UserDefaults.standard.setInt(mins, for: .rateWindow)
            }
            scheduleScan(incremental: false)
            render()
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
        UserDefaults.standard.set(Int(x), forKey: Self.posXKey)
        UserDefaults.standard.set(Int(y), forKey: Self.posYKey)
        api?.stop()
    }

    /// 自定义主题编辑器：9 个颜色（点按钮弹系统取色器）+ 指针样式（循环）+ 外环宽度。OK 落盘。
    private func openCustomThemeEditor() {
        customCfg = WindowsCustomTheme.load()
        let L = L10n.shared, en = L.language == .en
        guard let dlg = dlg_create(en ? "Custom Theme" : "自定义主题", 520, 540) else { return }
        editorDlg = dlg
        dlg_add_title(dlg, en ? "🎨 Custom Theme" : "🎨 自定义主题", 20, 14, 480, 30)
        dlg_add_sep(dlg, 20, 50, 480)
        let labels = en ? ["Dial", "Rim", "Hour hand", "Minute hand", "Second hand", "Center cap outer", "Center cap inner", "Text", "Text (sub)"]
                        : ["表盘", "外环", "时针", "分针", "秒针", "中心帽外", "中心帽内", "文字", "文字(次)"]
        let rowH: Int32 = 30, topY: Int32 = 60
        for i in 0..<WindowsCustomTheme.colorKeys.count {
            let y = topY + Int32(i) * rowH
            dlg_add_static(dlg, labels[i], 24, y + 5, 150, 22)
            dlg_add_push(dlg, 500 + Int32(i), WindowsCustomTheme.hex(customCfg.colorField(i)), 190, y, 150, 28)
        }
        let hy = topY + Int32(WindowsCustomTheme.colorKeys.count) * rowH + 4
        dlg_add_static(dlg, en ? "Hand style" : "指针样式", 24, hy + 5, 150, 22)
        dlg_add_push(dlg, 520, handStyleLabel(customCfg.handStyle), 190, hy, 150, 28)
        let wy = hy + rowH
        dlg_add_static(dlg, en ? "Rim width" : "外环宽度", 24, wy + 5, 150, 22)
        dlg_add_edit(dlg, 530, "\(customCfg.rimWidth)", 190, wy, 80, 28)
        let by = wy + rowH + 14
        dlg_add_push(dlg, 1, "OK", 250, by, 100, 30)
        dlg_add_push(dlg, 2, L.tr("about.close"), 370, by, 100, 30)
        if dlg_modal_cb(dlg, customCmdCb, nil) == 1 {
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
            defer { buf.deallocate() }
            dlg_edit_get(dlg, 530, buf, 64)
            if let w = Double(String(cString: buf)), w >= 0 { customCfg.rimWidth = w }
            customCfg.save()
            render()
        }
        editorDlg = nil
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
private let customCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleCustomCmd(id)   // 自定义主题编辑器内按钮点击
}
