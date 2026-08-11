import Foundation
import Win32Shim

/// Windows UI 驱动。Win32Shim（C）负责窗口/托盘/菜单/消息循环；表盘由 winrender.cpp（GDI+ +
/// UpdateLayeredWindow）逐像素 alpha 合成。数据层复用共享 Services（WindowsUsageModel 接 14 个
/// usage 服务），本地 API 服务由 winhttp.c（Winsock）后台线程承载。托盘菜单 + 位置/自启/语言等
/// 设置经 UserDefaults 持久化（镜像 macOS SettingsKey）。
final class WindowsApp: @unchecked Sendable {
    static let shared = WindowsApp()
    private init() {}

    /// GCD workers update quota data without touching the Win32 window. The UI thread reads the
    /// latest immutable snapshot on its normal 1 Hz render tick, so no AppKit-style main queue is
    /// assumed on Windows and a slow `codex app-server` can never block mouse interaction.
    private final class QuotaStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = CodexQuotaSnapshot.idle

        func snapshot() -> CodexQuotaSnapshot {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func begin(force: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value.status != .loading else { return false }
            guard force || value.status == .idle || value.isStale else { return false }
            value = .loading(previous: value)
            return true
        }

        func finish(_ snapshot: CodexQuotaSnapshot) {
            lock.lock(); value = snapshot; lock.unlock()
        }
    }

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
    private let cmdThemePicker: Int32 = 125
    private let cmdEditCustom: Int32 = 140
    private let cmdOpacityBase: Int32 = 150 // + 0...3 -> 25/50/75/100%
    private let cmdRefresh: Int32 = 160
    private let cmdSavedThemeBase: Int32 = 200
    private let cmdDeleteThemeBase: Int32 = 240

    /// 当前浮窗边长（pt）。表盘半径 = size/2 - 24；classic 主题按 radius 116（medium）校准，
    /// 其余尺寸由 winrender 按 r/116 等比缩放。切换尺寸时此值同步更新并 resize 窗口。
    private var currentSize: Int32 = 280
    private var currentHostWidth: Int32 = 280

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
    private var detailScrollRow = 0
    private var detailTotalRows = 0
    private var showsCodexQuota = false
    private let codexQuotaService = CodexQuotaService()
    private let codexQuotaState = QuotaStateBox()
    fileprivate var customCfg = WindowsCustomTheme()   // 自定义主题编辑器在用的配置
    fileprivate var editorDlg: UnsafeMutableRawPointer?
    fileprivate var settingsDlg: UnsafeMutableRawPointer?
    fileprivate var aboutDlg: UnsafeMutableRawPointer?
    fileprivate var editingSavedThemeId: String?
    private var settingsDraft: SettingsDraft?
    private var requestedSettingsSection: SettingsSection?
    private var requestedCustomSection: CustomSection?

    private enum SettingsSection { case tools, paths, thresholds, customFace, localAPI }
    private enum CustomSection { case colors, geometry }
    private struct SettingsDraft {
        var enabled: Set<String>
        var paths: [String: String]
        var cursorCloud: Bool
        var apiEnabled: Bool
        var apiPort: Int
        var rateWindow: Int
        var thresholds: [Int]
    }

    func run() {
        win_set_dpi_aware()

        currentSize = windowSize(for: clockSizeRaw)
        currentHostWidth = currentSize
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
        cb.on_scroll = appScroll
        cb.scan_interval_ms = Int32(AppConfig.Timers.dataScan * 1000)   // 30s 数据扫描
        cb.width = currentHostWidth
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

        let forecast = detailsVisible ? forecastOverlay() : (summary: "", slots: "", visible: false)

        // 固定高详情卡只渲染当前可见页；滚轮改变起始行。展开父项不会再改变窗口高度，
        // 也不会推动表盘。天气趋势占 76pt 时少显示两行，剩余行可继续滚动查看。
        let allDetailRows = detailsVisible ? buildDetailRows(tools) : []
        detailTotalRows = allDetailRows.count
        let visibleRowCapacity = forecast.visible ? 11 : 14
        let maxScroll = max(0, allDetailRows.count - visibleRowCapacity)
        detailScrollRow = min(maxScroll, max(0, detailScrollRow))
        let visibleDetailRows = Array(allDetailRows.dropFirst(detailScrollRow).prefix(visibleRowCapacity))
        renderedDetailRows = visibleDetailRows
        let detailText = visibleDetailRows.map(\.encoded).joined(separator: "\n")
        let L = L10n.shared
        let detailControls = [L.tr("detail.groupBySession"), L.tr("detail.groupByModel"), L.tr("detail.percent")].joined(separator: "\t")
        let detailHeader = [L.tr(groupingMode == .model ? "detail.model" : "detail.instance"),
                            L.tr(showPercentage ? "detail.share" : "detail.todayUsage"),
                            L.tr("detail.messages"), groupingMode == .session ? L.tr("detail.cacheRate") : ""].joined(separator: "\t")
        let quotaSnapshot = codexQuotaState.snapshot()
        let quotaText = detailsVisible ? quotaOverlay(snapshot: quotaSnapshot) : ""

        // The dial remains a compact per-pixel-alpha layered HWND. Win32Shim presents the
        // fixed 320×547 detail card in a separate non-layered Desktop Acrylic sibling, so
        // expanding never turns the round widget back into a tall rectangular host.
        let dialHeight = clockDiameter(for: clockSizeRaw)
        let newWidth = currentSize
        let newHeight = dialHeight
        if newHeight != currentHeight || newWidth != currentHostWidth {
            resizeHostKeepingCenter(width: newWidth, height: newHeight)
        }

        var wt = selectedTheme.winTheme
        Self.withCStrings([date, weather, todayLabel, tokens, messages, tool1, tool2, rate, dialImagePath,
                           detailText, detailControls, detailHeader, forecast.summary, forecast.slots,
                           L.tr("detail.codexQuota"), quotaText]) { ptrs in
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
            ov.quota_label = ptrs[14]
            ov.quota_text = ptrs[15]
            ov.detail_grouping = groupingMode == .model ? 1 : 0
            ov.detail_percentage = showPercentage ? 1 : 0
            ov.detail_visible = detailsVisible ? 1 : 0
            ov.detail_quota_visible = showsCodexQuota ? 1 : 0
            ov.clock_diameter = dialHeight
            ov.detail_card_width = 320
            win_render_clock(currentHostWidth, currentHeight,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                             &wt, &ov)
        }

        // 截图钩子：首帧画完后在时钟处弹出右键菜单（阻塞，保持打开）。
        if !menuShown, ProcessInfo.processInfo.environment["TC_MENU"] != nil {
            showTrayMenuForCapture()
        }
    }

    /// Size changes preserve the dial's screen centre. The independent 320pt detail sibling
    /// follows the resulting host rectangle in Win32Shim.
    private func resizeHostKeepingCenter(width: Int32, height: Int32) {
        if width != currentHostWidth {
            var x: Int32 = 0, y: Int32 = 0
            win_get_pos(win_self(), &x, &y)
            win_set_pos(win_self(), x + (currentHostWidth - width) / 2, y)
        }
        currentHostWidth = width
        currentHeight = height
        win_resize(win_self(), width, height)
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

    /// Converts the shared quota model to a compact renderer protocol. Data acquisition and
    /// decoding stay in CodexQuotaService; this function contains presentation only.
    private func quotaOverlay(snapshot: CodexQuotaSnapshot) -> String {
        let L = L10n.shared
        var lines = ["H\t\(L.tr("detail.codexQuota"))\t↻ \(L.tr("quota.retry"))"]
        if snapshot.status == .loading && snapshot.buckets.isEmpty {
            lines.append("L\t\(L.tr("quota.loading"))")
            return lines.joined(separator: "\n")
        }
        if snapshot.status == .idle || snapshot.status == .unavailable {
            lines.append("E\t\(L.tr("quota.unavailable"))\t\(L.tr("quota.retry"))")
            return lines.joined(separator: "\n")
        }

        for bucket in snapshot.buckets.prefix(3) {
            let window = quotaWindowLabel(minutes: bucket.windowMinutes)
            let title = bucket.name == "Codex" ? window : "\(bucket.name) · \(window)"
            let remaining = L.tr("quota.remaining", bucket.remainingPercent)
            let reset = bucket.resetsAt.map(quotaResetLabel) ?? "—"
            lines.append("B\t\(quotaField(title))\t\(quotaField(window))\t\(quotaField(remaining))\t\(quotaField(reset))\t\(String(format: "%.1f", bucket.remainingPercent))")
        }

        var meta: [String] = []
        if let plan = snapshot.planType, !plan.isEmpty {
            meta.append(L.tr("quota.plan", displayPlan(plan)))
        }
        if snapshot.hasUnlimitedCredits {
            meta.append(L.tr("quota.unlimited"))
        } else if let balance = snapshot.creditBalance, balance != "0" {
            meta.append(L.tr("quota.creditBalance", balance))
        }
        if snapshot.resetCreditCount > 0 {
            meta.append(L.tr("quota.resetCredits", snapshot.resetCreditCount))
        }
        if !meta.isEmpty { lines.append("M\t\(quotaField(meta.joined(separator: "  ·  ")))") }

        let source = L.tr(snapshot.source == .appServer ? "quota.liveSource" : "quota.logSource")
        if let refreshed = snapshot.refreshedAt {
            lines.append("S\t● \(source)  ·  \(L.tr("quota.updated", quotaUpdatedLabel(refreshed)))")
        } else {
            lines.append("S\t● \(source)")
        }
        return lines.joined(separator: "\n")
    }

    private func quotaField(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private func quotaWindowLabel(minutes: Int) -> String {
        let L = L10n.shared
        if minutes == 10_080 { return L.tr("quota.weekly") }
        if minutes >= 1_440, minutes % 1_440 == 0 { return L.tr("quota.days", minutes / 1_440) }
        if minutes >= 60, minutes % 60 == 0 { return L.tr("quota.hours", minutes / 60) }
        return L.tr("quota.minutes", minutes)
    }

    private func quotaResetLabel(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let relative: String
        if seconds >= 86_400 {
            relative = "\(Int(seconds / 86_400))d \(Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600))h"
        } else {
            relative = "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m"
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.shared.language == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.dateFormat = L10n.shared.language == .en ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return L10n.shared.tr("quota.resets", relative, formatter.string(from: date))
    }

    private func quotaUpdatedLabel(_ date: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))
        if elapsed < 60 { return L10n.shared.language == .en ? "just now" : "刚刚" }
        if elapsed < 3_600 { return L10n.shared.language == .en ? "\(elapsed / 60)m ago" : "\(elapsed / 60) 分钟前" }
        return L10n.shared.language == .en ? "\(elapsed / 3_600)h ago" : "\(elapsed / 3_600) 小时前"
    }

    private func displayPlan(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func refreshCodexQuota(force: Bool) {
        guard codexQuotaState.begin(force: force) else { return }
        let service = codexQuotaService
        let state = codexQuotaState
        DispatchQueue.global(qos: .userInitiated).async {
            state.finish(service.fetch())
        }
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
            let mockProviders = Self.providerEntries.map { ($0.displayName, $0.emoji) }
            let parents: [(String, String, Int, Int, [(String, Int, Int)])] = mock == "long"
                ? (1...18).map { index in
                    let provider = mockProviders[(index - 1) % mockProviders.count]
                    return (provider.0, provider.1, 1_000_000 - index * 21_000, 150 - index, [])
                }
                : modelMode
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
            return rows
        }

        // Percent and model grouping remain token-only. Credits/requests are separate units and
        // must never be compared with or folded into a token denominator.
        let active = tools.filter {
            $0.measurementUnit == .tokens && $0.measurementScope == .today && $0.todayTokens > 0
        }
        let currentSession = tools.filter {
            $0.measurementScope == .currentSession && $0.measurementValue != nil
        }
        let unavailable = tools.filter {
            $0.measurementScope == .contractOnly
                || ($0.measurementScope == .currentSession && $0.measurementValue == nil)
        }
        guard !active.isEmpty || !currentSession.isEmpty || !unavailable.isEmpty else {
            return [DetailRow(key: nil, label: L.language == .en ? "No AI usage today" : "今日暂无 AI 用量", value: "—", messages: "—", cache: "", isChild: true, expanded: false)]
        }
        let grand = active.reduce(0) { $0 + $1.todayTokens }
        var rows: [DetailRow] = currentSession.map { tool in
            DetailRow(key: nil, label: "\(tool.emoji) \(tool.name) · \(L.tr("detail.currentSession"))",
                      value: TokenFormat.compact(tool.value), messages: "—", cache: "—",
                      isChild: false, expanded: false)
        }
        rows.append(contentsOf: unavailable.map { tool in
            DetailRow(key: nil, label: "\(tool.emoji) \(tool.name)", value: L.tr("detail.statisticsUnavailable"),
                      messages: "—", cache: "—", isChild: false, expanded: false)
        })
        if groupingMode == .model {
            let groups = UsageAggregator.groupedByModel(active, unknownLabel: L.tr("detail.unknownModel"))
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
        return rows
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
        let detailCardWidth = 320.0
        let virtualHostWidth = max(Double(currentHostWidth), detailCardWidth)
        let cardX = (virtualHostWidth - detailCardWidth) / 2.0
        let localX = Double(x) - cardX
        guard localX >= 0, localX < detailCardWidth else { return }
        let localY = Double(y - dialHeight) - 14.0
        let forecastHeight = (weatherInfo?.cityName.isEmpty == false) ? 76.0 : 0.0
        let controlsY = localY - forecastHeight
        if controlsY >= 8, controlsY < 34 {
            let requested: GroupingMode = localX < detailCardWidth / 2.0 ? .session : .model
            UserDefaults.standard.setInt(requested == .model ? 1 : 0, for: .dropdownGrouping)
            expandedDetailKeys.removeAll()
            detailScrollRow = 0
            render()
        } else if controlsY >= 38, controlsY < 60 {
            if localX < detailCardWidth / 2.0 {
                showsCodexQuota.toggle()
                detailScrollRow = 0
                if showsCodexQuota { refreshCodexQuota(force: false) }
            } else {
                UserDefaults.standard.setBool(!showPercentage, for: .dropdownShowPercentage)
            }
            render()
        } else if showsCodexQuota, controlsY >= 68, controlsY < 112,
                  localX > detailCardWidth - 116.0 {
            refreshCodexQuota(force: true)
            render()
        } else if showsCodexQuota {
            return
        } else if controlsY >= 86 {
            let index = Int((controlsY - 86) / 30)
            guard renderedDetailRows.indices.contains(index), let key = renderedDetailRows[index].key else { return }
            if expandedDetailKeys.contains(key) { expandedDetailKeys.remove(key) }
            else { expandedDetailKeys.insert(key) }
            render()
        }
    }

    func scroll(delta: Int32) {
        guard detailsVisible, !showsCodexQuota, detailTotalRows > 0 else { return }
        let forecastRows = (weatherInfo?.cityName.isEmpty == false) ? 11 : 14
        let maxScroll = max(0, detailTotalRows - forecastRows)
        let direction = delta < 0 ? 1 : -1
        detailScrollRow = min(maxScroll, max(0, detailScrollRow + direction * 3))
        render()
    }

    private func toggleDetailsDebounced() {
        let now = Date()
        guard now.timeIntervalSince(lastTrayToggle) > 0.35 else { return }
        lastTrayToggle = now
        detailsVisible.toggle()
        if !detailsVisible { showsCodexQuota = false; detailScrollRow = 0 }
        render()
    }

    // MARK: - 托盘菜单

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        guard let menu else { return }
        let L = L10n.shared

        // macOS normal 使用独立 3x3 visual picker；菜单项直接打开同构的缩略图面板。
        addMenuItem(menu, cmdThemePicker, L.tr("menu.clockFace"), false)
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
        case cmdThemePicker: openThemePicker()
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

    private func openThemePicker() {
        let cases = WindowsClockTheme.allCases
        let themes = cases.map(\.winTheme)
        let names = cases.map(\.displayName)
        let current = cases.firstIndex(of: selectedTheme) ?? 0
        let title = L10n.shared.tr("themePicker.title")
        let selected: Int32 = title.withCString { titlePointer in
            themes.withUnsafeBufferPointer { themeBuffer in
                Self.withCStrings(names) { namePointers in
                    var nullablePointers = namePointers.map(Optional.some)
                    return nullablePointers.withUnsafeMutableBufferPointer { nameBuffer in
                        win_theme_picker(themeBuffer.baseAddress, nameBuffer.baseAddress,
                                         Int32(cases.count), Int32(current), titlePointer)
                    }
                }
            }
        }
        guard selected >= 0, Int(selected) < cases.count else { return }
        let choice = cases[Int(selected)]
        if choice == .custom {
            openCustomThemeEditor()
        } else {
            setTheme(choice)
        }
    }

    // MARK: - 设置（持久化）

    private func setSize(_ raw: String) {
        UserDefaults.standard.setString(raw, for: .clockSize)
        UserDefaults.standard.setBool(true, for: .clockSizeUserChosen)
        let sz = windowSize(for: raw)
        let dialHeight = clockDiameter(for: raw)
        currentSize = sz
        let hostWidth = sz
        let hostHeight = dialHeight
        resizeHostKeepingCenter(width: hostWidth, height: hostHeight)
        render()
    }

    private func setLang(_ lang: AppLanguage) {
        L10n.shared.language = lang          // didSet 落盘；dateFmt 为实例计算属性，下一帧即生效
        render()
    }

    private func showAbout() {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "About TokenClock" : "关于 TokenClock", 360, 430) else { return }
        aboutDlg = dlg
        defer { aboutDlg = nil; dlg_destroy(dlg) }
        dlg_add_brand_logo(dlg, 136, 22, 88, 88)
        dlg_add_title(dlg, "TokenClock", 112, 120, 180, 30)
        dlg_add_static(dlg, "v1.4.3", 154, 154, 90, 22)
        dlg_add_sep(dlg, 28, 188, 304)
        dlg_add_static(dlg, "Copyright © 2026 Neo-Isshin", 78, 210, 250, 22)
        dlg_add_static(dlg, L10n.shared.tr("about.license"), 128, 238, 180, 22)
        dlg_add_sep(dlg, 28, 274, 304)
        dlg_add_static(dlg, L10n.shared.tr("about.contact"), 138, 292, 150, 22)
        dlg_add_push(dlg, 800, "GitHub Issues", 105, 320, 150, 30)
        dlg_add_push(dlg, 1, L10n.shared.tr("about.close"), 130, 366, 100, 30)
        _ = dlg_modal_cb(dlg, aboutCmdCb, nil)
    }

    fileprivate func handleAboutCmd(_ id: Int32) {
        guard id == 800 else { return }
        "https://github.com/Neo-Isshin/TokenClock/issues".withCString { win_open_url($0) }
    }

    /// 520x548 overview mirrors the macOS normal information architecture. Each collapsed row
    /// opens a focused editor backed by an in-memory draft; only the overview Save commits it.
    private func openSettings() {
        let names = Self.providerNames
        var draft = SettingsDraft(
            enabled: WindowsProviderCatalog.enabledDisplayNames(
                saved: UserDefaults.standard.stringArray(for: .enabledTools)
            ),
            paths: Dictionary(uniqueKeysWithValues: names.map { ($0, pathFor($0)) }),
            cursorCloud: UserDefaults.standard.bool(for: .cursorCloudFetchEnabled, default: true),
            apiEnabled: apiEnabled,
            apiPort: Int(apiPort),
            rateWindow: model.rateWindowMinutes,
            thresholds: [
                UserDefaults.standard.int(for: .rateBurst, default: 500_000),
                UserDefaults.standard.int(for: .rateHot, default: 100_000),
                UserDefaults.standard.int(for: .rateActive, default: 20_000),
                UserDefaults.standard.int(for: .rateCalm, default: 2_000),
            ]
        )

        while true {
            settingsDraft = draft
            requestedSettingsSection = nil
            let result = showSettingsOverview(draft)
            draft = settingsDraft ?? draft
            if result == 1 { commitSettings(draft); break }
            guard let section = requestedSettingsSection else { break }
            switch section {
            case .tools: editToolSelection(&draft)
            case .paths: editDataSourcePaths(&draft)
            case .thresholds: editHeatThresholds(&draft)
            case .customFace: openCustomThemeEditor()
            case .localAPI: editLocalAPI(&draft)
            }
        }
        settingsDraft = nil
        requestedSettingsSection = nil
    }

    private func showSettingsOverview(_ draft: SettingsDraft) -> Int32 {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "TokenClock Settings" : "TokenClock 设置", 520, 548) else { return 0 }
        settingsDlg = dlg
        defer { settingsDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "TokenClock Settings" : "TokenClock 设置", 20, 12, 330, 30)
        dlg_add_static(dlg, en ? "Overview · select a section to edit" : "概览 · 选择分组进行编辑", 22, 47, 450, 20)
        dlg_add_sep(dlg, 20, 70, 470)

        let rows: [(Int32, String, String)] = [
            (700, en ? "Auto Detect" : "自动探测", en ? "Find readable Windows data sources" : "探测 Windows 中实际可读的数据源"),
            (710, en ? "Tool Selection  ›" : "工具选择  ›", en ? "\(draft.enabled.count) of \(Self.providerNames.count) enabled" : "已启用 \(draft.enabled.count)/\(Self.providerNames.count)"),
            (711, en ? "Data Source Paths  ›" : "数据源路径  ›", en ? "Review provider-specific Windows paths" : "检查各 provider 的 Windows 专用路径"),
            (712, en ? "Heat Thresholds  ›" : "热力阈值  ›", en ? "\(draft.rateWindow) min rate window" : "\(draft.rateWindow) 分钟速率窗口"),
            (713, en ? "Custom Clock Face  ›" : "自定义表盘  ›", en ? "Create, save, apply, and delete faces" : "创建、保存、应用与删除表盘"),
            (714, en ? "Local API  ›" : "本地 API  ›", draft.apiEnabled ? "localhost:\(draft.apiPort)" : (en ? "Disabled" : "已关闭")),
        ]
        for (index, row) in rows.enumerated() {
            let y = Int32(80 + index * 64)
            dlg_add_push(dlg, row.0, row.1, 22, y, 205, 42)
            dlg_add_static(dlg, row.2, 244, y + 5, 240, 34)
            if index < rows.count - 1 { dlg_add_sep(dlg, 22, y + 50, 462) }
        }
        dlg_add_sep(dlg, 20, 465, 470)
        dlg_add_push(dlg, 1, en ? "Save" : "保存", 288, 478, 92, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 478, 92, 30)
        return dlg_modal_cb(dlg, settingsCmdCb, nil)
    }

    private func editToolSelection(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Tool Selection" : "工具选择", 520, 548) else { return }
        dlg_add_title(dlg, en ? "Tool Selection" : "工具选择", 20, 12, 360, 30)
        dlg_add_static(dlg, en ? "Only enabled providers participate in scans." : "仅扫描已启用的 provider。", 22, 48, 460, 20)
        dlg_add_sep(dlg, 20, 72, 470)
        for (i, name) in Self.providerNames.enumerated() {
            let col = i / 6, row = i % 6
            let entry = Self.providerEntries[i]
            let label = entry.statisticsSupport == .contractOnly
                ? "\(name) · \(en ? "No stats" : "仅发现")"
                : name
            dlg_add_check(dlg, 300 + Int32(i), label, 24 + Int32(col * 160), 86 + Int32(row * 42), 150, 28, draft.enabled.contains(name) ? 1 : 0)
        }
        dlg_add_sep(dlg, 20, 344, 470)
        dlg_add_check(dlg, 410, en ? "Cursor cloud usage (contacts cursor.com)" : "Cursor 云端用量（会访问 cursor.com）", 24, 356, 445, 26, draft.cursorCloud ? 1 : 0)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 458, 92, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 458, 92, 30)
        if dlg_modal(dlg) == 1 {
            draft.enabled = Set(Self.providerNames.enumerated().compactMap { dlg_check_get(dlg, 300 + Int32($0.offset)) == 1 ? $0.element : nil })
            draft.cursorCloud = dlg_check_get(dlg, 410) == 1
        }
        dlg_destroy(dlg)
    }

    private func editDataSourcePaths(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Data Source Paths" : "数据源路径", 520, 548) else { return }
        settingsDlg = dlg; settingsDraft = draft
        defer { settingsDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "Data Source Paths" : "数据源路径", 20, 10, 350, 30)
        dlg_add_static(dlg, en ? "Windows paths are kept provider-specific." : "Windows 路径按 provider 独立维护。", 22, 44, 470, 20)
        let top: Int32 = 70
        for (i, entry) in Self.providerEntries.enumerated() {
            let col = i / 8, row = i % 8
            let x = Int32(16 + col * 250), y = top + Int32(row * 46)
            let sourceLabel = entry.statisticsSupport == .contractOnly
                ? "\(entry.displayName) · \(en ? "discovery only" : "仅发现")"
                : entry.displayName
            dlg_add_static(dlg, sourceLabel, x, y, 225, 20)
            dlg_add_edit(dlg, 200 + Int32(i), draft.paths[entry.displayName] ?? "", x, y + 20, entry.supportsFolderPicker ? 170 : 224, 24)
            if entry.supportsFolderPicker {
                dlg_add_push(dlg, 600 + Int32(i), en ? "Browse" : "浏览", x + 174, y + 20, 66, 24)
            }
        }
        dlg_add_sep(dlg, 20, 468, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 478, 92, 28)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 478, 92, 28)
        if dlg_modal_cb(dlg, settingsCmdCb, nil) == 1 {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 2048); defer { buffer.deallocate() }
            for (i, name) in Self.providerNames.enumerated() {
                dlg_edit_get(dlg, 200 + Int32(i), buffer, 2048)
                draft.paths[name] = String(cString: buffer)
            }
        }
        settingsDraft = draft
    }

    private func editHeatThresholds(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Heat Thresholds" : "热力阈值", 520, 330) else { return }
        dlg_add_title(dlg, en ? "Heat Thresholds" : "热力阈值", 20, 12, 360, 30)
        dlg_add_static(dlg, en ? "Rate window (minutes)" : "速率窗口（分钟）", 24, 66, 180, 22); dlg_add_edit(dlg, 400, "\(draft.rateWindow)", 220, 62, 90, 26)
        let labels = en ? ["Burst", "Hot", "Active", "Calm"] : ["爆发", "高热", "活跃", "平静"]
        for i in 0..<4 {
            let y = 104 + Int32(i * 36)
            dlg_add_static(dlg, labels[i], 24, y + 4, 130, 22); dlg_add_edit(dlg, 401 + Int32(i), "\(draft.thresholds[i])", 160, y, 150, 26)
        }
        dlg_add_sep(dlg, 20, 250, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 264, 92, 30); dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 264, 92, 30)
        if dlg_modal(dlg) == 1 {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128); defer { buffer.deallocate() }
            dlg_edit_get(dlg, 400, buffer, 128); draft.rateWindow = max(1, Int(String(cString: buffer)) ?? draft.rateWindow)
            for i in 0..<4 { dlg_edit_get(dlg, 401 + Int32(i), buffer, 128); draft.thresholds[i] = max(0, Int(String(cString: buffer)) ?? draft.thresholds[i]) }
            normalizeThresholds(&draft.thresholds)
        }
        dlg_destroy(dlg)
    }

    private func editLocalAPI(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Local API" : "本地 API", 520, 245) else { return }
        dlg_add_title(dlg, en ? "Local API" : "本地 API", 20, 12, 360, 30)
        dlg_add_static(dlg, en ? "Loopback-only usage and history endpoints" : "仅本机可访问的 usage/history 接口", 22, 48, 460, 20)
        dlg_add_check(dlg, 411, en ? "Enable Local API server" : "启用本地 API 服务", 24, 84, 250, 28, draft.apiEnabled ? 1 : 0)
        dlg_add_static(dlg, en ? "Port" : "端口", 24, 126, 70, 22); dlg_add_edit(dlg, 412, "\(draft.apiPort)", 100, 122, 110, 27)
        dlg_add_sep(dlg, 20, 164, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 178, 92, 30); dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 178, 92, 30)
        if dlg_modal(dlg) == 1 {
            draft.apiEnabled = dlg_check_get(dlg, 411) == 1
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128); defer { buffer.deallocate() }
            dlg_edit_get(dlg, 412, buffer, 128)
            let port = Int(String(cString: buffer)) ?? draft.apiPort
            if (1024...65535).contains(port) { draft.apiPort = port }
        }
        dlg_destroy(dlg)
    }

    private func normalizeThresholds(_ values: inout [Int]) {
        guard values.count == 4 else { return }
        var b = values[0], h = values[1], a = values[2], c = values[3]
        if h >= b { h = max(0, b - 1) }; if a >= h { a = max(0, h - 1) }; if c >= a { c = max(0, a - 1) }
        if a <= c { a = c + 1 }; if h <= a { h = a + 1 }; if b <= h { b = h + 1 }
        values = [b, h, a, c]
    }

    private func commitSettings(_ draft: SettingsDraft) {
        let enabled = Self.providerNames.filter { draft.enabled.contains($0) }
        UserDefaults.standard.setStringArray(enabled, for: .enabledTools)
        model.updateEnabledTools(Set(enabled))
        for name in Self.providerNames { setPath(name, draft.paths[name] ?? "") }
        model.reloadProviderPaths()
        UserDefaults.standard.setBool(draft.cursorCloud, for: .cursorCloudFetchEnabled)
        UserDefaults.standard.setInt(draft.rateWindow, for: .rateWindow)
        for (key, value) in zip([SettingsKey.rateBurst, .rateHot, .rateActive, .rateCalm], draft.thresholds) { UserDefaults.standard.setInt(value, for: key) }

        let wasEnabled = apiEnabled
        if wasEnabled && !draft.apiEnabled { api?.pause() }
        UserDefaults.standard.setInt(draft.apiPort, for: .apiServerPort)
        UserDefaults.standard.setBool(draft.apiEnabled, for: .apiServerEnabled)
        if draft.apiEnabled {
            if api == nil { api = WindowsAPIServer(model: model) }
            api?.start(port: UInt16(draft.apiPort))
        }
        scheduleScan(incremental: false); render()
    }

    /// Overview section routing, provider folder browsing, and evidence-backed auto detection.
    fileprivate func handleSettingsCmd(_ id: Int32) {
        guard let dlg = settingsDlg else { return }
        if id >= 600 && id < 600 + Int32(Self.providerNames.count) {
            let index = Int(id - 600)
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 2048); defer { buffer.deallocate() }
            dlg_edit_get(dlg, 200 + Int32(index), buffer, 2048)
            let initial = String(cString: buffer)
            let title = L10n.shared.language == .en ? "Select \(Self.providerNames[index]) data directory" : "选择 \(Self.providerNames[index]) 数据目录"
            let selected = UnsafeMutablePointer<CChar>.allocate(capacity: 2048); defer { selected.deallocate() }
            let picked = title.withCString { titlePointer in initial.withCString { win_pick_folder(dlg, titlePointer, $0, selected, 2048) } }
            if picked == 1 { dlg_set_text(dlg, 200 + Int32(index), String(cString: selected)) }
            return
        }
        if id == 700 {
            let summary = PathDetector.runFullDetection(probeLoopbackServices: true)
            if var draft = settingsDraft {
                for result in summary.results where result.exists {
                    if let entry = WindowsProviderCatalog.entry(serviceID: result.service) {
                        draft.paths[entry.displayName] = result.detectedPath
                        draft.enabled.insert(entry.displayName)
                    }
                }
                settingsDraft = draft
            }
            dlg_set_text(dlg, 700, L10n.shared.language == .en ? "Detected \(summary.foundCount)/\(summary.totalCount)" : "已探测 \(summary.foundCount)/\(summary.totalCount)")
            return
        }
        switch id {
        case 710: requestedSettingsSection = .tools
        case 711: requestedSettingsSection = .paths
        case 712: requestedSettingsSection = .thresholds
        case 713: requestedSettingsSection = .customFace
        case 714: requestedSettingsSection = .localAPI
        default: return
        }
        dlg_end(dlg, 0)
    }

    private func pathFor(_ name: String) -> String {
        guard let entry = WindowsProviderCatalog.entry(displayName: name) else { return "" }
        return WindowsProviderCatalog.configuredSource(for: entry.id)
    }

    private func setPath(_ name: String, _ p: String) {
        guard let entry = WindowsProviderCatalog.entry(displayName: name) else { return }
        WindowsProviderCatalog.setConfiguredSource(p, for: entry.id)
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

    /// Full custom-face editor with the same 520x548 overview-and-disclosure structure as
    /// Settings. The draft stays in memory while Colors and Geometry are edited; only
    /// Save & Apply writes the named face and selects it.
    private func openCustomThemeEditor() {
        let en = L10n.shared.language == .en
        let saved = WindowsSavedCustomTheme.loadAll()
        let activeId = UserDefaults.standard.string(for: .activeCustomThemeId)
        if let active = saved.first(where: { $0.id == activeId }) {
            customCfg = active.config
            editingSavedThemeId = active.id
        } else {
            customCfg = WindowsCustomTheme.load()
            editingSavedThemeId = nil
        }
        var name = saved.first(where: { $0.id == activeId })?.name
            ?? (en ? "Custom \(saved.count + 1)" : "自定义 \(saved.count + 1)")
        var shouldSave = false

        while true {
            requestedCustomSection = nil
            let overview = showCustomOverview(name: name, savedCount: saved.count)
            name = overview.name
            if overview.result == 1 { shouldSave = true; break }
            guard let section = requestedCustomSection else { break }
            switch section {
            case .colors: editCustomColors()
            case .geometry: editCustomGeometry()
            }
        }
        requestedCustomSection = nil
        defer { editingSavedThemeId = nil }
        guard shouldSave else { return }

        customCfg.save()
        let proposed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = proposed.isEmpty ? (en ? "Custom Face" : "自定义表盘") : proposed
        var themes = WindowsSavedCustomTheme.loadAll()
        let id: String
        if let editingSavedThemeId, let index = themes.firstIndex(where: { $0.id == editingSavedThemeId }) {
            themes[index].name = finalName; themes[index].config = customCfg; id = editingSavedThemeId
        } else {
            id = UUID().uuidString
            themes.append(WindowsSavedCustomTheme(id: id, name: finalName, config: customCfg))
        }
        WindowsSavedCustomTheme.saveAll(themes)
        UserDefaults.standard.setString(id, for: .activeCustomThemeId)
        UserDefaults.standard.setString(WindowsClockTheme.custom.rawValue, for: .selectedTheme)
        render()
    }

    private func showCustomOverview(name: String, savedCount: Int) -> (result: Int32, name: String) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Custom Clock Face" : "自定义表盘", 520, 548) else { return (0, name) }
        editorDlg = dlg
        defer { editorDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "Custom Clock Face" : "自定义表盘", 20, 12, 360, 30)
        dlg_add_static(dlg, en ? "Overview · edit one group at a time" : "概览 · 按分组编辑", 22, 47, 450, 20)
        dlg_add_sep(dlg, 20, 70, 470)
        dlg_add_static(dlg, en ? "Name" : "名称", 22, 88, 60, 22)
        dlg_add_edit(dlg, 540, name, 84, 84, 288, 28)
        dlg_add_push(dlg, 560, en ? "New" : "新建", 388, 84, 96, 28)

        dlg_add_push(dlg, 570, en ? "Colors  ›" : "颜色  ›", 22, 140, 205, 44)
        dlg_add_static(dlg, en ? "8 face · 8 overlay/detail colors" : "8 项表盘 · 8 项叠加层/详情颜色", 244, 146, 240, 34)
        dlg_add_sep(dlg, 22, 196, 462)
        dlg_add_push(dlg, 571, en ? "Geometry and Markings  ›" : "几何与刻度  ›", 22, 210, 205, 44)
        let marks = en
            ? "\(handStyleLabel(customCfg.handStyle).replacingOccurrences(of: " ▾", with: "")) hands · \(customCfg.showTicks ? "ticks" : "no ticks")"
            : "\(handStyleLabel(customCfg.handStyle).replacingOccurrences(of: " ▾", with: ""))指针 · \(customCfg.showTicks ? "显示刻度" : "隐藏刻度")"
        dlg_add_static(dlg, marks, 244, 216, 240, 34)
        dlg_add_sep(dlg, 22, 266, 462)
        dlg_add_static(dlg, en ? "SAVED FACES" : "已保存表盘", 22, 284, 150, 20)
        dlg_add_static(dlg,
                       en ? "\(savedCount) saved · manage apply/delete from My Clock Faces" : "已保存 \(savedCount) 个 · 在“我的表盘”中应用/删除",
                       22, 312, 462, 42)
        dlg_add_static(dlg,
                       en ? "Changes remain a draft until Save and Apply." : "所有修改仅在“保存并应用”后写入。",
                       22, 386, 462, 28)
        dlg_add_sep(dlg, 20, 465, 470)
        dlg_add_push(dlg, 1, en ? "Save and Apply" : "保存并应用", 272, 478, 108, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 478, 92, 30)
        let result = dlg_modal_cb(dlg, customCmdCb, nil)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512); defer { buffer.deallocate() }
        dlg_edit_get(dlg, 540, buffer, 512)
        return (result, String(cString: buffer))
    }

    private func editCustomColors() {
        let en = L10n.shared.language == .en
        let original = customCfg
        guard let dlg = dlg_create(en ? "Custom Colors" : "自定义颜色", 520, 548) else { return }
        editorDlg = dlg
        defer { editorDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "Custom Colors" : "自定义颜色", 20, 12, 360, 30)
        dlg_add_static(dlg, en ? "Face colors" : "表盘颜色", 22, 48, 180, 20)
        dlg_add_static(dlg, en ? "Overlay and detail colors" : "叠加层与详情颜色", 264, 48, 220, 20)
        dlg_add_sep(dlg, 20, 72, 470)
        let labels = en
            ? ["Dial", "Rim", "Hour", "Minute", "Second", "Cap outer", "Cap inner", "Numbers",
               "Ticks", "Major ticks", "Text", "Subtext", "Panel bg", "Panel text", "Panel subtext", "Panel border"]
            : ["表盘", "外环", "时针", "分针", "秒针", "中心帽外", "中心帽内", "数字",
               "刻度", "主刻度", "文字", "次文字", "面板背景", "面板文字", "面板次文字", "面板边框"]
        for i in 0..<WindowsCustomTheme.colorKeys.count {
            let column = i / 8, row = i % 8
            let x: Int32 = column == 0 ? 22 : 264
            let y = Int32(84 + row * 42)
            dlg_add_static(dlg, labels[i], x, y + 5, 92, 22)
            dlg_add_push(dlg, 500 + Int32(i), WindowsCustomTheme.hex(customCfg.colorField(i)), x + 96, y, 132, 28)
        }
        dlg_add_sep(dlg, 20, 438, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 452, 92, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 452, 92, 30)
        if dlg_modal_cb(dlg, customCmdCb, nil) != 1 { customCfg = original }
    }

    private func editCustomGeometry() {
        let en = L10n.shared.language == .en
        let original = customCfg
        guard let dlg = dlg_create(en ? "Geometry and Markings" : "几何与刻度", 520, 430) else { return }
        editorDlg = dlg
        defer { editorDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "Geometry and Markings" : "几何与刻度", 20, 12, 390, 30)
        dlg_add_static(dlg, en ? "Hands" : "指针", 22, 54, 120, 20)
        dlg_add_static(dlg, en ? "Hand style" : "指针样式", 22, 84, 112, 22); dlg_add_push(dlg, 520, handStyleLabel(customCfg.handStyle), 142, 80, 138, 28)
        dlg_add_static(dlg, en ? "Number style" : "数字样式", 294, 84, 100, 22); dlg_add_push(dlg, 553, numberStyleLabel(), 392, 80, 104, 28)
        dlg_add_static(dlg, en ? "Rim width" : "外环宽度", 22, 124, 112, 22); dlg_add_edit(dlg, 530, formatNumber(customCfg.rimWidth), 142, 120, 82, 28)
        dlg_add_static(dlg, en ? "Hand widths · H / M / S" : "指针宽度 · 时 / 分 / 秒", 22, 164, 190, 22)
        dlg_add_edit(dlg, 531, formatNumber(customCfg.hourWidth), 230, 160, 66, 26); dlg_add_edit(dlg, 532, formatNumber(customCfg.minuteWidth), 306, 160, 66, 26); dlg_add_edit(dlg, 533, formatNumber(customCfg.secondWidth), 382, 160, 66, 26)
        dlg_add_static(dlg, en ? "Hand lengths · H / M / S" : "指针长度 · 时 / 分 / 秒", 22, 204, 190, 22)
        dlg_add_edit(dlg, 534, formatNumber(customCfg.hourLength), 230, 200, 66, 26); dlg_add_edit(dlg, 535, formatNumber(customCfg.minuteLength), 306, 200, 66, 26); dlg_add_edit(dlg, 536, formatNumber(customCfg.secondLength), 382, 200, 66, 26)
        dlg_add_sep(dlg, 20, 246, 470)
        dlg_add_check(dlg, 550, en ? "Show numbers" : "显示数字", 22, 262, 130, 26, customCfg.showNumbers ? 1 : 0)
        dlg_add_check(dlg, 551, en ? "Tick marks" : "显示刻度", 178, 262, 120, 26, customCfg.showTicks ? 1 : 0)
        dlg_add_check(dlg, 552, en ? "Sky decoration" : "天空装饰", 322, 262, 150, 26, customCfg.hasDecoration ? 1 : 0)
        dlg_add_sep(dlg, 20, 318, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 334, 92, 30); dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 334, 92, 30)
        guard dlg_modal_cb(dlg, customCmdCb, nil) == 1 else { customCfg = original; return }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128); defer { buffer.deallocate() }
        func readDouble(_ id: Int32, _ fallback: Double, range: ClosedRange<Double>) -> Double {
            dlg_edit_get(dlg, id, buffer, 128)
            guard let value = Double(String(cString: buffer)), value.isFinite else { return fallback }
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
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func numberStyleLabel() -> String {
        let en = L10n.shared.language == .en
        return customCfg.numberStyle == 2 ? (en ? "Chinese ▾" : "中文 ▾") : (en ? "Arabic ▾" : "阿拉伯数字 ▾")
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
        } else if id == 570 || id == 571 {
            requestedCustomSection = id == 570 ? .colors : .geometry
            if let dlg = editorDlg { dlg_end(dlg, 0) }
        } else if id == 560 {
            customCfg = WindowsCustomTheme()
            editingSavedThemeId = nil
            if let dlg = editorDlg {
                let count = WindowsSavedCustomTheme.loadAll().count + 1
                dlg_set_text(dlg, 540, L10n.shared.language == .en ? "Custom \(count)" : "自定义 \(count)")
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
    private static let providerEntries = WindowsProviderCatalog.orderedEntries
    private static let providerNames = providerEntries.map(\.displayName)
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
private let appScroll: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, delta in
    WindowsApp.shared.scroll(delta: delta)
}
private let customCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleCustomCmd(id)   // 自定义主题编辑器内按钮点击
}
private let settingsCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleSettingsCmd(id)
}
private let aboutCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleAboutCmd(id)
}
