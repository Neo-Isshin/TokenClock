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

    /// Claude's snapshot is a distinct type from Codex's snapshot, so keep a separate locked
    /// container while preserving the same non-blocking UI-thread contract.
    private final class ClaudeQuotaStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ClaudeQuotaSnapshot.idle

        func snapshot() -> ClaudeQuotaSnapshot {
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

        func finish(_ snapshot: ClaudeQuotaSnapshot) {
            lock.lock(); value = snapshot; lock.unlock()
        }
    }

    private final class ProviderQuotaStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProviderQuotaSnapshot
        init(source: String) { value = .idle(source: source) }
        func snapshot() -> ProviderQuotaSnapshot { lock.withLock { value } }
        func begin(force: Bool) -> Bool {
            lock.withLock {
                guard value.status != .loading else { return false }
                guard force || value.status == .idle || value.isStale else { return false }
                value = .loading(previous: value)
                return true
            }
        }
        func finish(_ snapshot: ProviderQuotaSnapshot) { lock.withLock { value = snapshot } }
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
    private let cmdOverview: Int32 = 110
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
    private let weatherLock = NSLock()
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
    private let codexQuotaService = CodexQuotaService()
    private let codexQuotaState = QuotaStateBox()
    private let claudeQuotaService = ClaudeQuotaService()
    private let claudeQuotaState = ClaudeQuotaStateBox()
    private let antigravityQuotaService = AntigravityQuotaService()
    private let antigravityQuotaState = ProviderQuotaStateBox(source: "Antigravity local service")
    private let cursorQuotaService = CursorQuotaService()
    private let cursorQuotaState = ProviderQuotaStateBox(source: "Cursor dashboard")
    fileprivate var customCfg = WindowsCustomTheme()   // 自定义主题编辑器在用的配置
    fileprivate var editorDlg: UnsafeMutableRawPointer?
    fileprivate var settingsDlg: UnsafeMutableRawPointer?
    fileprivate var overviewDlg: UnsafeMutableRawPointer?
    fileprivate var quotaDlg: UnsafeMutableRawPointer?
    fileprivate var aboutDlg: UnsafeMutableRawPointer?
    fileprivate var editingSavedThemeId: String?
    private var settingsDraft: SettingsDraft?
    private var expandedSettingsSection: SettingsSection?
    private var settingsDetectionStatus: String?
    private var pricingDlg: UnsafeMutableRawPointer?
    private var pricingVisibleRows = 1
    private var settingsPricingRows: [SettingsPriceRow] = []
    private var requestedCustomSection: CustomSection?

    private enum OverviewPeriod { case week, month, custom }
    private enum OverviewChartStyle { case automatic, line, stacked }
    private enum QuotaProvider: String, CaseIterable { case codex, claude, antigravity, cursor }
    private var overviewPeriod: OverviewPeriod = .week
    private var overviewChartStyle: OverviewChartStyle = .automatic
    private var overviewSelectedDayKey: String?
    private var overviewGrouping: UsageOverviewGrouping = .tool
    private var overviewIncludesCacheRead = false
    private var overviewCustomStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    private var overviewCustomEnd = Date()
    private var quotaOrderEditing = false
    private var quotaProviderOrder: [QuotaProvider] = {
        let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.subscriptionQuotaOrder.rawValue) ?? []
        var order = saved.compactMap(QuotaProvider.init(rawValue:))
        for provider in QuotaProvider.allCases where !order.contains(provider) { order.append(provider) }
        return order
    }()

    private enum SettingsSection { case autoDetect, tools, paths, thresholds, pricing, customFace, localAPI }
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
    private struct SettingsPriceRow {
        var model: String
        var input: String
        var output: String
        var cacheRead: String
        var cacheWrite: String
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
        if ProcessInfo.processInfo.environment["TC_OVERVIEW"] != nil { openUsageOverview() }
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
        weatherLock.withLock {
            weatherInfo = info
            weatherString = "\(info.emoji) \(temp)°\(f ? "F" : "C")"
        }
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
        let tokens = TokenFormat.compact(UsageAggregator.totalTokens(tools, includingCacheRead: usageIncludesCache))
        let todayLabel = L10n.shared.tr("clock.todayTokens")
        let messages = L10n.shared.tr("clock.messagesCount", UsageAggregator.totalMessages(tools))
        let top = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let tool1 = top.first.map { "\($0.emoji) \($0.abbreviation)" } ?? ""
        let tool2 = top.count > 1 ? "\(top[1].emoji) \(top[1].abbreviation)" : ""
        let rate = UsageAggregator.rateEmoji(tools)
        let dialImagePath = selectedTheme == .glass
            ? (Bundle.module.url(forResource: "glass_disc", withExtension: "png")?.path ?? "")
            : ""
        let weatherSnapshot = weatherLock.withLock { (weatherString, weatherInfo) }
        let weather = weatherSnapshot.0
        let forecast = detailsVisible
            ? forecastOverlay(weatherInfo: weatherSnapshot.1)
            : (summary: "", slots: "", visible: false)

        // 固定高详情卡只渲染当前可见页；滚轮改变起始行。展开父项不会再改变窗口高度，
        // 也不会推动表盘。天气趋势占 76pt 时少显示两行，剩余行可继续滚动查看。
        let allDetailRows = detailsVisible ? buildDetailRows(tools) : []
        detailTotalRows = allDetailRows.count
        let visibleRowCapacity = forecast.visible ? 8 : 11
        let maxScroll = max(0, allDetailRows.count - visibleRowCapacity)
        detailScrollRow = min(maxScroll, max(0, detailScrollRow))
        let visibleDetailRows = Array(allDetailRows.dropFirst(detailScrollRow).prefix(visibleRowCapacity))
        renderedDetailRows = visibleDetailRows
        let detailText = visibleDetailRows.map(\.encoded).joined(separator: "\n")
        let L = L10n.shared
        let modeLabel = valueMode == .tokens
            ? "\(L.tr("detail.byCost"))\n\(L.tr("detail.byPercent"))"
            : "\(L.tr("detail.byPercent"))\n\(L.tr("detail.todayUsage"))"
        let detailControls = [
            "\(L.tr("detail.modelDetectLine1"))\n\(L.tr("detail.modelDetectLine2"))", "",
            "\(L.tr("detail.subscriptionQuotaLine1"))\n\(L.tr("detail.subscriptionQuotaLine2"))", "",
            L.tr("detail.groupBySession"), L.tr("detail.groupByModel"),
            "\(L.tr("detail.cacheDataLine1"))\n\(L.tr("detail.cacheDataLine2"))",
            "\(L.tr("detail.textColorLine1"))\n\(L.tr("detail.textColorLine2"))",
            "\(L.tr("detail.historyUsageLine1"))\n\(L.tr("detail.historyUsageLine2"))", "", modeLabel,
        ].joined(separator: "\t")
        let detailHeader = [L.tr(groupingMode == .model ? "detail.model" : "detail.instance"),
                            L.tr(valueMode == .tokens ? "detail.todayUsage" : "detail.cost"),
                            L.tr(valueMode == .tokens ? "detail.messages" : "detail.share"),
                            groupingMode == .session ? L.tr("detail.cacheRate") : ""].joined(separator: "\t")
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
                           "", ""]) { ptrs in
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
            ov.detail_percentage = valueMode == .costPercent ? 1 : 0
            ov.detail_includes_cache = usageIncludesCache ? 1 : 0
            ov.detail_visible = detailsVisible ? 1 : 0
            ov.detail_quota_visible = 0
            ov.clock_diameter = dialHeight
            ov.detail_card_width = 320
            applyDetailTextPreset(to: &wt)
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
    private func forecastOverlay(weatherInfo: WeatherInfo?) -> (summary: String, slots: String, visible: Bool) {
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

    /// Converts both subscription quota models to the compact renderer protocol. The panel is
    /// deliberately capped at the two primary windows per provider so it fits the fixed detail
    /// card without changing the widget layout.
    private func quotaOverlay(codex: CodexQuotaSnapshot, claude: ClaudeQuotaSnapshot) -> String {
        let L = L10n.shared
        var lines = ["H\t\(L.tr("quota.subscriptions"))\t↻ \(L.tr("quota.retry"))"]
        let codexPlan = codex.planType.map { " · \(displayPlan($0))" } ?? ""
        lines.append("P\t🤖 Codex\(codexPlan)")
        appendQuotaProvider(
            status: codex.status, buckets: codex.buckets,
            loading: L.tr("quota.loadingCodex"), unavailable: L.tr("quota.codexUnavailable"),
            to: &lines
        )
        let claudePlan = claude.planType.map { " · \(displayPlan($0))" } ?? ""
        lines.append("P\t✳️ Claude Code\(claudePlan)")
        appendQuotaProvider(
            status: claude.status, buckets: claude.buckets,
            loading: L.tr("quota.loadingClaude"), unavailable: L.tr("quota.claudeUnavailable"),
            to: &lines
        )
        return lines.joined(separator: "\n")
    }

    private func appendQuotaProvider(
        status: CodexQuotaStatus, buckets: [CodexQuotaBucket], loading: String,
        unavailable: String, to lines: inout [String]
    ) {
        if status == .loading && buckets.isEmpty {
            lines.append("L\t\(quotaField(loading))")
            return
        }
        guard status == .available, !buckets.isEmpty else {
            lines.append("E\t\(quotaField(unavailable))")
            return
        }
        for bucket in buckets.prefix(2) {
            let window = quotaWindowLabel(minutes: bucket.windowMinutes)
            let reset = bucket.resetsAt.map(quotaResetLabels)
            lines.append(
                "B\t\(quotaField(window))"
                    + "\t\(quotaField(L10n.shared.tr("quota.remainingLabel")))"
                    + "\t\(String(format: "%.0f%%", bucket.remainingPercent))"
                    + "\t\(quotaField(reset?.relative ?? "—"))"
                    + "\t\(String(format: "%.1f", bucket.remainingPercent))"
                    + "\t\(quotaField(reset?.absolute ?? ""))"
            )
        }
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

    private func quotaResetLabels(_ date: Date) -> (relative: String, absolute: String) {
        let seconds = max(0, date.timeIntervalSinceNow)
        let relative: String
        if seconds >= 86_400 {
            relative = "\(Int(seconds / 86_400))d \(Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600))h"
        } else {
            relative = "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m"
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.shared.language == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.dateFormat = L10n.shared.language == .en ? "MMM d · h:mm a" : "M月d日 · HH:mm"
        return (
            L10n.shared.tr("quota.resetsRelative", relative),
            formatter.string(from: date)
        )
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

    private var quickContrastPreset: Int {
        UserDefaults.standard.int(for: .quickContrastPreset, default: 0)
    }

    private func cycleQuickContrast() {
        let next = quickContrastPreset >= 3 ? 1 : quickContrastPreset + 1
        UserDefaults.standard.setInt(next, for: .quickContrastPreset)
    }

    private func applyDetailTextPreset(to theme: inout win_theme) {
        Self.applyDetailTextPreset(quickContrastPreset, to: &theme)
    }

    static func applyDetailTextPreset(_ preset: Int, to theme: inout win_theme) {
        let primary: UInt32
        let secondary: UInt32
        switch preset {
        case 1: primary = 0xFFFFFFFF; secondary = 0xB8FFFFFF
        case 2: primary = 0xFF000000; secondary = 0xB8000000
        case 3: primary = 0xFFFFD60A; secondary = 0xB8FFD60A
        default: return
        }
        theme.dd_text = primary
        theme.dd_subtext = secondary
    }

    private func refreshSubscriptionQuotas(force: Bool) {
        if codexQuotaState.begin(force: force) {
            let service = codexQuotaService
            let state = codexQuotaState
            DispatchQueue.global(qos: .userInitiated).async {
                state.finish(service.fetch())
                if let dialog = WindowsApp.shared.quotaDlg { dlg_post_command(dialog, 980) }
            }
        }
        if claudeQuotaState.begin(force: force) {
            let service = claudeQuotaService
            let state = claudeQuotaState
            DispatchQueue.global(qos: .userInitiated).async {
                state.finish(service.fetch())
                if let dialog = WindowsApp.shared.quotaDlg { dlg_post_command(dialog, 980) }
            }
        }
        if antigravityQuotaState.begin(force: force) {
            let service = antigravityQuotaService, state = antigravityQuotaState
            DispatchQueue.global(qos: .userInitiated).async {
                state.finish(service.fetch())
                if let dialog = WindowsApp.shared.quotaDlg { dlg_post_command(dialog, 980) }
            }
        }
        if cursorQuotaState.begin(force: force) {
            let service = cursorQuotaService, state = cursorQuotaState
            DispatchQueue.global(qos: .userInitiated).async {
                state.finish(service.fetch())
                if let dialog = WindowsApp.shared.quotaDlg { dlg_post_command(dialog, 980) }
            }
        }
    }

    private struct DetailRow {
        let key: String?
        let label: String
        /// 主列：用量（紧凑 token）或 费用（随 valueMode 切换）
        let value: String
        /// 次列：消息数或占总数百分比（随 valueMode 切换）
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
        if let mock = ProcessInfo.processInfo.environment["TC_MOCK"] {
            let modelMode = mock == "model" || mock == "emoji" || groupingMode == .model
            let mockProviders = Self.providerEntries.map { ($0.displayName, $0.emoji) }
            let parents: [(String, String, Int, Int, [(String, Int, Int)])] = mock == "emoji"
                ? [("Kiro CLI", "🟦", 760_000, 76, []),
                   ("CodeBuddy CLI", "🧩", 690_000, 69, []),
                   ("glm-5", "🅉", 540_000, 54, []),
                   ("doubao-pro", "🫘", 430_000, 43, []),
                   ("llama-4", "🦙", 320_000, 32, []),
                   ("mistral-large", "🌪️", 210_000, 21, []),
                   (L.tr("detail.unknownModel"), "❓", 100_000, 10, [])]
                : mock == "long"
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
                rows.append(DetailRow(key: key, label: "\(p.1) \(p.0)", value: valueMode == .tokens ? TokenFormat.compact(p.2) : "—", messages: secondaryValue(tokens: p.2, messages: p.3, grand: grand), cache: modelMode ? "" : "42%", isChild: false, expanded: open))
                if open {
                    for child in p.4 { rows.append(DetailRow(key: nil, label: child.0, value: valueMode == .tokens ? TokenFormat.compact(child.1) : "—", messages: secondaryValue(tokens: child.1, messages: child.2, grand: grand), cache: "", isChild: true, expanded: false)) }
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
        let grand = active.reduce(0) {
            $0 + $1.todayTokens + (usageIncludesCache ? $1.todayCacheReadTokens : 0)
        }
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
                rows.append(DetailRow(key: key, label: "\(group.emoji) \(group.name)", value: primaryValue(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, cost: group.totalCost), messages: secondaryValue(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, messages: group.totalMessages, grand: grand), cache: "", isChild: false, expanded: open))
                if open {
                    for contribution in group.contributions.prefix(5) {
                        rows.append(DetailRow(key: nil, label: "\(contribution.emoji) \(contribution.tool)", value: primaryValue(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, cost: contribution.cost), messages: secondaryValue(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, messages: contribution.messages, grand: grand), cache: "", isChild: true, expanded: false))
                    }
                }
            }
        } else {
            for tool in active.prefix(10) {
                let key = "tool:\(tool.id)"
                let open = expandedDetailKeys.contains(key)
                let cache = tool.cacheRate > 0 ? String(format: "%.0f%%", tool.cacheRate * 100) : "—"
                rows.append(DetailRow(key: key, label: "\(tool.emoji) \(tool.name)", value: primaryValue(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, cost: tool.todayCost), messages: secondaryValue(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, messages: tool.todayMessages, grand: grand), cache: cache, isChild: false, expanded: open))
                if open {
                    let sessions = tool.sessions.filter { $0.todayTokens > 0 }.sorted { $0.todayTokens > $1.todayTokens }
                    for session in sessions.prefix(5) {
                        let source = session.source.map { " · \($0)" } ?? ""
                        rows.append(DetailRow(key: nil, label: "\(session.displayName)\(source)", value: primaryValue(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, cost: session.todayCost), messages: secondaryValue(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, messages: session.todayMessages, grand: grand), cache: "", isChild: true, expanded: false))
                    }
                }
            }
        }
        return rows
    }

    /// 主列（用量 ↔ 费用），与 macOS DetailValueMode 一致；tokens=0 时费用列显示 "—"。
    private func primaryValue(tokens: Int, cacheRead: Int = 0, cost: CostEstimate = .zero) -> String {
        switch valueMode {
        case .tokens:
            return TokenFormat.compact(usageIncludesCache ? tokens + cacheRead : tokens)
        case .costPercent:
            return tokens > 0 ? CostFormat.estimate(cost) : "—"
        }
    }

    /// 次列（消息数 ↔ 占比）；占比分母与主列同口径（含缓存时把缓存读计入）。
    private func secondaryValue(tokens: Int, cacheRead: Int = 0, messages: Int, grand: Int) -> String {
        guard valueMode == .costPercent, grand > 0 else { return "\(messages)" }
        let shown = usageIncludesCache ? tokens + cacheRead : tokens
        let percent = Double(shown) / Double(grand) * 100
        return percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    /// 详情面板数值模式（用量+消息数 ↔ 费用+占比），与 macOS DetailValueMode 一致。
    /// 迁移：旧版 dropdownShowPercentage=true 归入 .costPercent。
    private var valueMode: DetailValueMode {
        // Windows typed setters persist through WindowsPreferences, not Foundation UserDefaults.
        // Checking the latter made every redraw discard the just-selected cost mode.
        if WindowsPreferences.shared.object(forKey: SettingsKey.dropdownValueMode.rawValue) != nil {
            return DetailValueMode(rawValue: UserDefaults.standard.int(for: .dropdownValueMode)) ?? .tokens
        }
        return UserDefaults.standard.bool(for: .dropdownShowPercentage) ? .costPercent : .tokens
    }
    private func setValueMode(_ mode: DetailValueMode) {
        UserDefaults.standard.setInt(mode.rawValue, for: .dropdownValueMode)
    }
    /// 用量口径：token 展示是否包含缓存读（详情快捷按钮切换；默认排除）
    private var usageIncludesCache: Bool { UserDefaults.standard.bool(for: .usageIncludesCacheRead) }

    private enum GroupingMode { case session, model }
    private var groupingMode: GroupingMode {
        let environment = ProcessInfo.processInfo.environment
        if environment["TC_GROUPING"] == "model" || environment["TC_MOCK"] == "emoji" { return .model }
        if environment["TC_GROUPING"] == "session" { return .session }
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
        let forecastHeight = weatherLock.withLock { weatherInfo?.cityName.isEmpty == false } ? 76.0 : 0.0
        let controlsY = localY - forecastHeight
        if controlsY >= 8, controlsY < 57 {
            if localX >= detailCardWidth / 2.0 { openSubscriptionQuota() }
            return
        } else if controlsY >= 65, controlsY < 91 {
            let requested: GroupingMode = localX < detailCardWidth / 2.0 ? .session : .model
            UserDefaults.standard.setInt(requested == .model ? 1 : 0, for: .dropdownGrouping)
            expandedDetailKeys.removeAll()
            detailScrollRow = 0
            render()
        } else if controlsY >= 97, controlsY < 136 {
            let compactX = min(307, max(0, localX - 6.0))
            let item: Int
            if compactX < 67 {
                item = 0
            } else if compactX < 128 {
                item = 1
            } else if compactX < 215 {
                item = 2
            } else {
                item = 3
            }
            if item == 0 {
                UserDefaults.standard.setBool(!usageIncludesCache, for: .usageIncludesCacheRead)
            } else if item == 1 {
                cycleQuickContrast()
            } else if item == 2 {
                openUsageOverview()
            } else {
                setValueMode(valueMode.next)
            }
            render()
        } else if controlsY >= 163 {
            let index = Int((controlsY - 163) / 30)
            guard renderedDetailRows.indices.contains(index), let key = renderedDetailRows[index].key else { return }
            if expandedDetailKeys.contains(key) { expandedDetailKeys.remove(key) }
            else { expandedDetailKeys.insert(key) }
            render()
        }
    }

    func scroll(delta: Int32) {
        guard detailsVisible, detailTotalRows > 0 else { return }
        let forecastRows = weatherLock.withLock { weatherInfo?.cityName.isEmpty == false } ? 8 : 11
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
        if !detailsVisible { detailScrollRow = 0 }
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
        case cmdOverview:   openUsageOverview()
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
        WindowsWeather.refresh(forCity: selectedCity)
        render()
    }

    private func showAbout() {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "About TokenClock" : "关于 TokenClock", 360, 430) else { return }
        aboutDlg = dlg
        defer { aboutDlg = nil; dlg_destroy(dlg) }
        dlg_add_brand_logo(dlg, 136, 22, 88, 88)
        dlg_add_title(dlg, "TokenClock", 112, 120, 180, 30)
        dlg_add_static(dlg, "v1.5.3", 154, 154, 90, 22)
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

    // MARK: - 用量总览

    private func openSubscriptionQuota() {
        guard quotaDlg == nil,
              let dialog = dlg_create(L10n.shared.tr("quota.windowTitle"), 470, 700) else { return }
        quotaDlg = dialog
        refreshSubscriptionQuotas(force: false)
        rebuildSubscriptionQuotaDialog()
        _ = dlg_modal_cb(dialog, quotaCmdCb, nil)
        quotaDlg = nil
        dlg_destroy(dialog)
    }

    fileprivate func handleQuotaCmd(_ id: Int32) {
        switch id {
        case 980: rebuildSubscriptionQuotaDialog()
        case 981:
            refreshSubscriptionQuotas(force: true)
            rebuildSubscriptionQuotaDialog()
        case 982:
            if let dialog = quotaDlg { dlg_end(dialog, 0) }
        case 983:
            quotaOrderEditing.toggle()
            rebuildSubscriptionQuotaDialog()
        case 990...993:
            moveQuotaProvider(atDefaultIndex: Int(id - 990), by: -1)
            rebuildSubscriptionQuotaDialog()
        case 994...997:
            moveQuotaProvider(atDefaultIndex: Int(id - 994), by: 1)
            rebuildSubscriptionQuotaDialog()
        default: break
        }
    }

    private func rebuildSubscriptionQuotaDialog() {
        guard let dialog = quotaDlg else { return }
        let codex = codexQuotaState.snapshot(), claude = claudeQuotaState.snapshot()
        let antigravity = antigravityQuotaState.snapshot(), cursor = cursorQuotaState.snapshot()
        let estimatedBuckets = codex.buckets.count + claude.buckets.count
            + antigravity.groups.reduce(0) { $0 + $1.buckets.count }
            + cursor.groups.reduce(0) { $0 + $1.buckets.count }
        let contentHeight = max(680, 230 + estimatedBuckets * 82)
        dlg_reset_content(dialog, Int32(contentHeight))
        dlg_add_title(dialog, L10n.shared.tr("quota.windowTitle"), 24, 16, 270, 30)
        dlg_add_subtitle(dialog, L10n.shared.tr("quota.windowSubtitle"), 24, 47, 390, 22)
        dlg_add_push(dialog, 983, L10n.shared.tr(quotaOrderEditing ? "quota.finishOrder" : "quota.editOrder"), 254, 16, 76, 30)
        dlg_add_push(dialog, 981, L10n.shared.tr("quota.retry"), 338, 16, 98, 30)
        var y: Int32 = 82
        for provider in quotaProviderOrder {
            switch provider {
            case .codex:
                y = appendQuotaDialogProvider(dialog, provider: provider, title: "🤖 Codex", plan: codex.planType,
                    status: codex.status, buckets: codex.buckets,
                    unavailable: L10n.shared.tr("quota.codexUnavailable"), y: y)
            case .claude:
                y = appendQuotaDialogProvider(dialog, provider: provider, title: "✳️ Claude Code", plan: claude.planType,
                    status: claude.status, buckets: claude.buckets,
                    unavailable: L10n.shared.tr("quota.claudeUnavailable"), y: y)
            case .antigravity:
                y = appendQuotaDialogProvider(dialog, provider: provider, title: "🛸 Antigravity", plan: antigravity.planType,
                    status: antigravity.status, buckets: antigravity.groups.flatMap(\.buckets),
                    unavailable: L10n.shared.tr("quota.antigravityUnavailable"), y: y)
            case .cursor:
                y = appendQuotaDialogProvider(dialog, provider: provider, title: "🖱️ Cursor", plan: cursor.planType,
                    status: cursor.status, buckets: cursor.groups.flatMap(\.buckets),
                    unavailable: L10n.shared.tr("quota.cursorUnavailable"), y: y)
            }
        }
        dlg_add_push(dialog, 982, L10n.shared.language == .en ? "Close" : "关闭", 336, y + 8, 100, 30)
    }

    private func appendQuotaDialogProvider(
        _ dialog: UnsafeMutableRawPointer, provider: QuotaProvider, title: String, plan: String?,
        status: CodexQuotaStatus, buckets: [CodexQuotaBucket], unavailable: String, y: Int32
    ) -> Int32 {
        var cursorY = y
        let planText = plan.map { " · \(displayPlan($0))" } ?? ""
        if quotaOrderEditing, let defaultIndex = QuotaProvider.allCases.firstIndex(of: provider) {
            let current = quotaProviderOrder.firstIndex(of: provider) ?? 0
            dlg_add_push(dialog, 990 + Int32(defaultIndex), current == 0 ? "·" : "↑", 22, cursorY - 2, 24, 22)
            dlg_add_push(dialog, 994 + Int32(defaultIndex), current == quotaProviderOrder.count - 1 ? "·" : "↓", 50, cursorY - 2, 24, 22)
            dlg_add_section(dialog, title + planText, 82, cursorY, 336, 22)
        } else {
            dlg_add_section(dialog, title + planText, 28, cursorY, 390, 22)
        }
        cursorY += 28
        if buckets.isEmpty {
            dlg_add_card(dialog, 22, cursorY, 414, 66)
            let message = status == .loading ? L10n.shared.tr("quota.loadingProvider", title) : unavailable
            dlg_add_subtitle(dialog, message, 36, cursorY + 11, 380, 44)
            return cursorY + 80
        }
        for bucket in buckets {
            dlg_add_card(dialog, 22, cursorY, 414, 72)
            let label = bucket.name.isEmpty ? quotaWindowLabel(minutes: bucket.windowMinutes) : bucket.name
            let percent = String(format: "%.0f%% %@", bucket.remainingPercent, L10n.shared.tr("quota.remainingLabel"))
            dlg_add_static(dialog, label, 36, cursorY + 8, 230, 20)
            dlg_add_static(dialog, percent, 302, cursorY + 8, 114, 20)
            dlg_add_progress(dialog, 36, cursorY + 32, 380, 8,
                             Int32(bucket.remainingPercent.rounded()))
            if let reset = bucket.resetsAt {
                let labels = quotaResetLabels(reset)
                dlg_add_subtitle(dialog, "\(labels.relative) · \(labels.absolute)", 36, cursorY + 49, 370, 17)
            }
            cursorY += 80
        }
        return cursorY + 4
    }

    private func moveQuotaProvider(atDefaultIndex index: Int, by offset: Int) {
        guard QuotaProvider.allCases.indices.contains(index) else { return }
        let provider = QuotaProvider.allCases[index]
        guard let source = quotaProviderOrder.firstIndex(of: provider) else { return }
        let destination = source + offset
        guard quotaProviderOrder.indices.contains(destination) else { return }
        quotaProviderOrder.swapAt(source, destination)
        UserDefaults.standard.set(quotaProviderOrder.map(\.rawValue), forKey: SettingsKey.subscriptionQuotaOrder.rawValue)
    }

    private func openUsageOverview() {
        model.persistCurrentUsage()
        guard let dlg = dlg_create(L10n.shared.tr("overview.title"), 820, 680) else { return }
        overviewDlg = dlg
        renderUsageOverview(scrollToTop: true)
        _ = dlg_modal_cb(dlg, overviewCmdCb, nil)
        overviewDlg = nil
        dlg_destroy(dlg)
    }

    fileprivate func handleOverviewCmd(_ id: Int32) {
        switch id {
        case 900: overviewPeriod = .week; overviewSelectedDayKey = nil
        case 901: overviewPeriod = .month; overviewSelectedDayKey = nil
        case 902: overviewPeriod = .custom; overviewSelectedDayKey = nil
        case 903: overviewGrouping = .tool
        case 904: overviewGrouping = .model
        case 905: overviewIncludesCacheRead.toggle()
        case 906: overviewChartStyle = .automatic
        case 907: overviewChartStyle = .line
        case 908: overviewChartStyle = .stacked
        case 909: overviewSelectedDayKey = nil
        case 1000...1099:
            let dates = overviewDates
            let data = UsageOverviewBuilder.load(
                startDate: dates.0, endDate: dates.1, grouping: overviewGrouping,
                includingCacheRead: overviewIncludesCacheRead
            )
            let index = Int(id - 1000)
            let visibleDays = Array(data.days.suffix(30))
            if visibleDays.indices.contains(index) { overviewSelectedDayKey = visibleDays[index].dateKey }
        case 914:
            guard let dlg = overviewDlg else { return }
            if let value = parseOverviewDate(settingsEditText(dlg, 912)) { overviewCustomStart = value }
            if let value = parseOverviewDate(settingsEditText(dlg, 913)) { overviewCustomEnd = min(Date(), value) }
        default: return
        }
        renderUsageOverview(scrollToTop: false)
    }

    private func renderUsageOverview(scrollToTop: Bool) {
        guard let dlg = overviewDlg else { return }
        let dates = overviewDates
        let data = UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: overviewGrouping,
            includingCacheRead: overviewIncludesCacheRead
        )
        let modelData = overviewGrouping == .model ? data : UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: .model,
            includingCacheRead: overviewIncludesCacheRead
        )
        let tokenTitle = L10n.shared.tr(
            overviewIncludesCacheRead ? "overview.tokensWithCache" : "overview.tokens"
        )
        let tokenHeader = L10n.shared.tr(
            overviewIncludesCacheRead ? "overview.tokensWithCacheShort" : "overview.tokens"
        )
        let dayRows = min(30, data.days.count)
        let activeDay = overviewSelectedDayKey.flatMap { key in data.days.first { $0.dateKey == key } }
        let displayRows = activeDay?.rows ?? data.rows
        let rowCount = max(1, displayRows.count)
        let customHeight: Int32 = overviewPeriod == .custom ? 46 : 0
        let chartHeight: Int32 = overviewChartStyle == .automatic && overviewPeriod != .month
            ? Int32(dayRows * 26 + 46) : 210
        let contentHeight = Int32(330 + rowCount * 30) + chartHeight + customHeight
        dlg_reset_content(dlg, contentHeight)

        dlg_add_title(dlg, L10n.shared.tr("overview.title"), 24, 14, 260, 30)
        dlg_add_subtitle(dlg, "\(overviewDisplayDate(dates.0)) – \(overviewDisplayDate(dates.1))", 24, 46, 280, 20)
        dlg_add_push(dlg, 900, overviewPeriod == .week ? "✓  \(L10n.shared.tr("overview.last7Days"))" : L10n.shared.tr("overview.last7Days"), 390, 18, 116, 30)
        dlg_add_push(dlg, 901, overviewPeriod == .month ? "✓  \(L10n.shared.tr("overview.last30Days"))" : L10n.shared.tr("overview.last30Days"), 512, 18, 126, 30)
        dlg_add_push(dlg, 902, overviewPeriod == .custom ? "✓  \(L10n.shared.tr("overview.custom"))" : L10n.shared.tr("overview.custom"), 644, 18, 118, 30)
        dlg_add_push(dlg, 903, overviewGrouping == .tool ? "✓  \(L10n.shared.tr("overview.byTool"))" : L10n.shared.tr("overview.byTool"), 606, 54, 88, 28)
        dlg_add_push(dlg, 904, overviewGrouping == .model ? "✓  \(L10n.shared.tr("overview.byModel"))" : L10n.shared.tr("overview.byModel"), 700, 54, 88, 28)
        dlg_add_push(dlg, 905, overviewIncludesCacheRead ? "✓  \(L10n.shared.tr("overview.includeCache"))" : L10n.shared.tr("overview.includeCache"), 474, 54, 126, 28)
        dlg_add_push(dlg, 906, overviewChartStyle == .automatic ? "✓ ▦" : "▦", 24, 86, 48, 26)
        dlg_add_push(dlg, 907, overviewChartStyle == .line ? "✓ 📈" : "📈", 78, 86, 54, 26)
        dlg_add_push(dlg, 908, overviewChartStyle == .stacked ? "✓ 📊" : "📊", 138, 86, 54, 26)

        var y: Int32 = 122
        if overviewPeriod == .custom {
            dlg_add_static(dlg, L10n.shared.tr("overview.from"), 380, y + 3, 28, 22)
            dlg_add_edit(dlg, 912, DateHelper.dateKey(from: overviewCustomStart), 410, y, 112, 26)
            dlg_add_static(dlg, L10n.shared.tr("overview.to"), 530, y + 3, 24, 22)
            dlg_add_edit(dlg, 913, DateHelper.dateKey(from: overviewCustomEnd), 556, y, 112, 26)
            dlg_add_push(dlg, 914, L10n.shared.tr("settings.done"), 678, y, 84, 27)
            y += 42
        }

        appendOverviewMetricCard(dlg, x: 22, y: y, width: 184, title: tokenTitle, value: TokenFormat.compact(data.summary.displayedTokens(includingCacheRead: overviewIncludesCacheRead)))
        appendOverviewMetricCard(dlg, x: 214, y: y, width: 184, title: L10n.shared.tr("overview.messages"), value: overviewNumber(data.summary.messages))
        appendOverviewMetricCard(dlg, x: 406, y: y, width: 184, title: L10n.shared.tr("overview.cost"), value: CostFormat.estimate(data.summary.cost))
        appendOverviewMetricCard(dlg, x: 598, y: y, width: 184, title: L10n.shared.tr("overview.averageCache"), value: String(format: "%@%.2f%%", data.summary.cacheIsExact ? "" : "≈", data.summary.averageCacheRate * 100))
        y += 86

        y = appendWindowsOverviewChart(dlg, data: data, modelData: modelData, y: y)

        dlg_add_section(dlg, L10n.shared.tr("overview.breakdown"), 24, y, 200, 24)
        dlg_add_push(dlg, 909, overviewSelectedDayKey == nil ? "✓ \(L10n.shared.tr("overview.overview"))" : L10n.shared.tr("overview.overview"), 222, y - 2, 96, 26)
        y += 28
        let listHeight = Int32(56 + rowCount * 30)
        dlg_add_card(dlg, 22, y, 760, listHeight)
        dlg_add_static(dlg, activeDay?.dateKey ?? L10n.shared.tr("overview.overview"), 36, y + 7, 220, 22)
        appendOverviewColumns(dlg, y: y + 29, name: L10n.shared.tr("overview.name"), tokens: tokenHeader, messages: L10n.shared.tr("overview.messages"), cost: L10n.shared.tr("overview.cost"), cache: L10n.shared.tr("overview.averageCache"))
        if displayRows.isEmpty {
            dlg_add_subtitle(dlg, L10n.shared.tr("overview.noData"), 42, y + 38, 700, 24)
        }
        for (index, row) in displayRows.enumerated() {
            let rowY = y + 56 + Int32(index * 30)
            let name = row.name == "Unknown" ? L10n.shared.tr("detail.unknownModel") : row.name
            appendOverviewColumns(
                dlg, y: rowY, name: "\(row.emoji)  \(name)",
                tokens: TokenFormat.compact(row.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)),
                messages: overviewNumber(row.metrics.messages),
                cost: CostFormat.estimate(row.metrics.cost),
                cache: String(format: "%@%.2f%%", row.metrics.cacheIsExact ? "" : "≈", row.metrics.averageCacheRate * 100)
            )
        }
        y += listHeight + 12

        var notes: [String] = []
        if data.summary.cost.available { notes.append(L10n.shared.tr("overview.apiEquivalentCost")) }
        if data.containsLegacyCacheEstimate { notes.append(L10n.shared.tr("overview.estimatedCache")) }
        if data.containsUnavailableCost { notes.append(L10n.shared.tr("overview.partialCost")) }
        if data.containsUnknownModel { notes.append(L10n.shared.tr("overview.unknownModel")) }
        if !notes.isEmpty { dlg_add_subtitle(dlg, "ⓘ  " + notes.joined(separator: "   ·   "), 24, y, 650, 32) }
        dlg_add_push(dlg, 2, L10n.shared.tr("about.close"), 694, y, 88, 30)
        if scrollToTop { dlg_scroll_to(dlg, 0) }
    }

    private func appendOverviewMetricCard(
        _ dlg: UnsafeMutableRawPointer, x: Int32, y: Int32, width: Int32,
        title: String, value: String
    ) {
        dlg_add_card(dlg, x, y, width, 72)
        dlg_add_subtitle(dlg, title, x + 14, y + 10, width - 28, 20)
        dlg_add_title(dlg, value, x + 14, y + 32, width - 28, 26)
    }

    private func appendWindowsOverviewChart(
        _ dlg: UnsafeMutableRawPointer,
        data: UsageOverviewData,
        modelData: UsageOverviewData,
        y: Int32
    ) -> Int32 {
        dlg_add_section(dlg, L10n.shared.tr("overview.daily"), 24, y, 200, 24)
        let cardY = y + 28
        let days = Array(data.days.suffix(30))
        let maxTokens = max(1, days.map { $0.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead) }.max() ?? 1)

        if overviewChartStyle == .automatic, overviewPeriod != .month {
            dlg_add_card(dlg, 22, cardY, 760, Int32(days.count * 26 + 18))
            for (index, day) in days.enumerated() {
                let rowY = cardY + 8 + Int32(index * 26)
                let tokens = day.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)
                dlg_add_push(dlg, 1000 + Int32(index), String(day.dateKey.suffix(5)), 30, rowY - 2, 58, 23)
                dlg_add_tooltip(dlg, 1000 + Int32(index), overviewDayTooltip(day))
                dlg_add_static(dlg, overviewBar(tokens, maximum: maxTokens), 96, rowY, 558, 20)
                dlg_add_static(dlg, TokenFormat.compact(tokens), 676, rowY, 88, 20)
            }
            return cardY + Int32(days.count * 26 + 32)
        }

        let chartHeight: Int32 = 174
        dlg_add_card(dlg, 22, cardY, 760, chartHeight)
        switch overviewChartStyle {
        case .automatic:
            let leading = days.first.flatMap { overviewDate($0.dateKey) }.map {
                (Calendar.current.component(.weekday, from: $0) - Calendar.current.firstWeekday + 7) % 7
            } ?? 0
            for (index, day) in days.enumerated() {
                let slot = leading + index
                let column = slot / 7, row = slot % 7
                let tokens = day.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)
                let ratio = tokens > 0 ? log(Double(tokens) + 1) / log(Double(maxTokens) + 1) : 0
                let glyphs = ["·", "▫", "▪", "◼", "■"]
                let glyph = glyphs[min(4, Int((ratio * 4).rounded()))]
                dlg_add_push(dlg, 1000 + Int32(index), glyph, 42 + Int32(column * 36), cardY + 18 + Int32(row * 20), 30, 19)
                dlg_add_tooltip(dlg, 1000 + Int32(index), overviewDayTooltip(day))
            }
            dlg_add_subtitle(dlg, L10n.shared.tr("overview.hoverDay"), 270, cardY + 18, 470, 22)
        case .line:
            let glyphs = Array("▁▂▃▄▅▆▇█")
            let sparkline = days.map { day -> Character in
                let ratio = Double(day.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)) / Double(maxTokens)
                return glyphs[min(glyphs.count - 1, Int((ratio * Double(glyphs.count - 1)).rounded()))]
            }
            dlg_add_title(dlg, String(sparkline), 36, cardY + 18, 728, 48)
            appendWindowsDayButtons(dlg, days: days, y: cardY + 86)
        case .stacked:
            let modelDays = Array(modelData.days.suffix(30))
            for (index, day) in modelDays.enumerated() {
                let x = 30 + Int32(index * 24)
                let label = overviewStackGlyph(day, models: modelData.rows)
                    + "\n" + overviewAxisLabel(day.dateKey, previous: index > 0 ? modelDays[index - 1].dateKey : nil)
                dlg_add_push(dlg, 1000 + Int32(index), label, x, cardY + 24, 23, 112)
                dlg_add_tooltip(dlg, 1000 + Int32(index), overviewDayTooltip(day))
            }
        }
        return cardY + chartHeight + 14
    }

    private func appendWindowsDayButtons(
        _ dlg: UnsafeMutableRawPointer,
        days: [UsageOverviewDay],
        y: Int32
    ) {
        for (index, day) in days.enumerated() {
            let label = overviewAxisLabel(day.dateKey, previous: index > 0 ? days[index - 1].dateKey : nil)
            dlg_add_push(dlg, 1000 + Int32(index), label, 30 + Int32(index * 24), y, 23, 48)
            dlg_add_tooltip(dlg, 1000 + Int32(index), overviewDayTooltip(day))
        }
    }

    private func overviewStackGlyph(_ day: UsageOverviewDay, models: [UsageOverviewRow]) -> String {
        let palette = ["🟦", "🟪", "🟧", "🟩", "🟥", "🟨", "🟫", "⬛"]
        let total = max(1, day.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead))
        var blocks: [String] = []
        for row in day.rows {
            let index = models.firstIndex(where: { $0.name == row.name }) ?? 0
            let count = max(1, Int((Double(row.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)) / Double(total) * 5).rounded()))
            blocks.append(contentsOf: Array(repeating: palette[index % palette.count], count: count))
        }
        return blocks.prefix(5).joined(separator: "\n")
    }

    private func overviewDayTooltip(_ day: UsageOverviewDay) -> String {
        var lines = ["\(day.dateKey) · \(TokenFormat.compact(day.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead))) tokens"]
        lines += day.rows.map {
            "\($0.emoji) \($0.name): \(TokenFormat.compact($0.metrics.displayedTokens(includingCacheRead: overviewIncludesCacheRead)))"
        }
        return lines.joined(separator: "\n")
    }

    private func overviewAxisLabel(_ key: String, previous: String?) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        let day = Int(parts[2]).map(String.init) ?? String(parts[2])
        guard let previous else { return day }
        let previousParts = previous.split(separator: "-")
        guard previousParts.count == 3, previousParts[1] != parts[1], let date = overviewDate(key) else { return day }
        let formatter = DateFormatter(); formatter.locale = Locale.current; formatter.dateFormat = "MMM"
        return "\(formatter.string(from: date))\n\(day)"
    }

    private func overviewDate(_ key: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    private func appendOverviewColumns(
        _ dlg: UnsafeMutableRawPointer, y: Int32,
        name: String, tokens: String, messages: String, cost: String, cache: String
    ) {
        dlg_add_static(dlg, name, 36, y, 294, 22)
        dlg_add_static(dlg, tokens, 340, y, 102, 22)
        dlg_add_static(dlg, messages, 452, y, 84, 22)
        dlg_add_static(dlg, cost, 548, y, 94, 22)
        dlg_add_static(dlg, cache, 654, y, 106, 22)
    }

    private var overviewDates: (Date, Date) {
        let end = Calendar.current.startOfDay(for: overviewPeriod == .custom ? overviewCustomEnd : Date())
        let start: Date
        switch overviewPeriod {
        case .week: start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
        case .month: start = Calendar.current.date(byAdding: .day, value: -29, to: end) ?? end
        case .custom: start = Calendar.current.startOfDay(for: overviewCustomStart)
        }
        return (min(start, end), max(start, end))
    }

    private func parseOverviewDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func overviewDisplayDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    private func overviewNumber(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func overviewBar(_ value: Int, maximum: Int) -> String {
        let filled = value > 0 ? max(1, Int((Double(value) / Double(maximum) * 42).rounded())) : 0
        return String(repeating: "━", count: filled)
    }

    /// The Windows settings surface follows macOS normal's disclosure-group model: every
    /// section expands in the same scrollable Mica window and edits one in-memory draft.
    /// Save commits the draft as a unit; Cancel discards it.
    private func openSettings() {
        let names = Self.providerNames
        settingsDraft = SettingsDraft(
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
        expandedSettingsSection = nil
        settingsDetectionStatus = nil
        loadSettingsPricingRows()

        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "TokenClock Settings" : "TokenClock 设置", 520, 620) else { return }
        settingsDlg = dlg
        renderSettingsAccordion(scrollToExpanded: false)
        let result = dlg_modal_cb(dlg, settingsCmdCb, nil)
        if result == 1 {
            captureExpandedSettings()
            if let draft = settingsDraft {
                commitSettingsPricingRows()
                commitSettings(draft)
            }
        }
        pricingDlg = nil
        settingsDlg = nil
        dlg_destroy(dlg)
        settingsDraft = nil
        expandedSettingsSection = nil
        settingsDetectionStatus = nil
        settingsPricingRows = []
    }

    private func settingsSectionHeight(_ section: SettingsSection) -> Int32 {
        switch section {
        case .autoDetect: return 94
        case .tools: return 304
        case .paths: return 378
        case .thresholds: return 180
        case .pricing: return 344
        case .customFace: return 126
        case .localAPI: return 104
        }
    }

    private func renderSettingsAccordion(scrollToExpanded: Bool) {
        guard let dlg = settingsDlg, let draft = settingsDraft else { return }
        let en = L10n.shared.language == .en
        let pricing = PricingService.shared.catalogSummary
        let pricingDesc = en ? "\(pricing.count) models · \(pricing.generatedAt.map { String($0.prefix(10)) } ?? "—")"
                             : "\(pricing.count) 个模型 · \(pricing.generatedAt.map { String($0.prefix(10)) } ?? "—")"
        let savedFaces = WindowsSavedCustomTheme.loadAll().count
        let rows: [(SettingsSection, Int32, String, String)] = [
            (.autoDetect, 700, en ? "Auto Detect" : "自动探测",
             settingsDetectionStatus ?? (en ? "Find readable Windows data sources" : "探测 Windows 中实际可读的数据源")),
            (.tools, 710, en ? "Tool Selection" : "工具选择",
             en ? "\(draft.enabled.count) of \(Self.providerNames.count) enabled" : "已启用 \(draft.enabled.count)/\(Self.providerNames.count)"),
            (.paths, 711, en ? "Data Source Paths" : "数据源路径",
             en ? "Review provider-specific Windows paths" : "检查各 provider 的 Windows 专用路径"),
            (.thresholds, 712, en ? "Heat Thresholds" : "热力阈值",
             en ? "\(draft.rateWindow) min rate window" : "\(draft.rateWindow) 分钟速率窗口"),
            (.pricing, 715, en ? "Cost Estimation" : "费用估算", pricingDesc),
            (.customFace, 713, en ? "Custom Clock Face" : "自定义表盘",
             en ? "\(savedFaces) saved · create and manage faces" : "已保存 \(savedFaces) 个 · 创建与管理表盘"),
            (.localAPI, 714, en ? "Local API" : "本地 API",
             draft.apiEnabled ? "localhost:\(draft.apiPort)" : (en ? "Disabled" : "已关闭")),
        ]

        let expandedHeight = expandedSettingsSection.map(settingsSectionHeight) ?? 0
        let contentHeight: Int32 = 76 + Int32(rows.count * 56) + expandedHeight + 72
        dlg_reset_content(dlg, contentHeight)
        dlg_add_title(dlg, en ? "TokenClock Settings" : "TokenClock 设置", 24, 14, 330, 30)
        dlg_add_subtitle(dlg, en ? "Expand a section to review and edit it." : "展开一个分组进行查看与编辑。", 24, 48, 450, 20)

        var y: Int32 = 76
        var expandedHeaderY: Int32 = 0
        for row in rows {
            let isExpanded = expandedSettingsSection == row.0
            dlg_add_disclosure(dlg, row.1, row.2, row.3, 22, y, 466, 48, isExpanded ? 1 : 0)
            if isExpanded {
                expandedHeaderY = y
                y += 56
                addSettingsSection(row.0, at: y, draft: draft)
                y += settingsSectionHeight(row.0)
            } else {
                y += 56
            }
        }
        dlg_add_sep(dlg, 20, y + 4, 470)
        dlg_add_push(dlg, 1, en ? "Save" : "保存", 288, y + 18, 92, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, y + 18, 92, 30)
        pricingDlg = expandedSettingsSection == .pricing ? dlg : nil
        if scrollToExpanded, expandedSettingsSection != nil {
            // Align the open disclosure at a clean row boundary. Showing half of
            // the preceding row looks accidental when the content is long.
            dlg_scroll_to(dlg, max(0, expandedHeaderY - 8))
        }
    }

    private func addSettingsSection(_ section: SettingsSection, at y: Int32, draft: SettingsDraft) {
        guard let dlg = settingsDlg else { return }
        let en = L10n.shared.language == .en
        switch section {
        case .autoDetect:
            dlg_add_card(dlg, 34, y, 440, 78)
            _ = dlg_add_static_id(dlg, 702,
                                  settingsDetectionStatus ?? (en ? "Ready to scan" : "可以开始探测"),
                                  48, y + 12, 270, 22)
            dlg_add_subtitle(dlg,
                             en ? "Checks only documented Windows locations and readable local endpoints."
                                : "仅检查 Windows 已知路径与可读的本机接口。",
                             48, y + 36, 284, 34)
            dlg_add_push(dlg, 701, en ? "Detect now" : "立即探测", 350, y + 24, 108, 30)

        case .tools:
            dlg_add_card(dlg, 34, y, 440, 238)
            for (i, name) in Self.providerNames.enumerated() {
                let col = i / 6, row = i % 6
                let entry = Self.providerEntries[i]
                let label = entry.statisticsSupport == .contractOnly
                    ? "\(name) · \(en ? "No stats" : "仅发现")"
                    : name
                dlg_add_check(dlg, 300 + Int32(i), label,
                              42 + Int32(col * 142), y + 10 + Int32(row * 36),
                              134, 28, draft.enabled.contains(name) ? 1 : 0)
            }
            dlg_add_card(dlg, 34, y + 248, 440, 48)
            dlg_add_check(dlg, 410,
                          en ? "Cursor cloud usage (contacts cursor.com)" : "Cursor 云端用量（会访问 cursor.com）",
                          46, y + 258, 410, 28, draft.cursorCloud ? 1 : 0)

        case .paths:
            dlg_add_card(dlg, 26, y, 462, 370)
            for (i, entry) in Self.providerEntries.enumerated() {
                let col = i / 8, row = i % 8
                let x = Int32(34 + col * 226), rowY = y + 8 + Int32(row * 44)
                let label = entry.statisticsSupport == .contractOnly
                    ? "\(entry.displayName) · \(en ? "discovery only" : "仅发现")"
                    : entry.displayName
                dlg_add_static(dlg, label, x, rowY, 214, 19)
                dlg_add_edit(dlg, 200 + Int32(i), draft.paths[entry.displayName] ?? "",
                             x, rowY + 18, entry.supportsFolderPicker ? 150 : 216, 23)
                if entry.supportsFolderPicker {
                    dlg_add_push(dlg, 600 + Int32(i), en ? "Browse" : "浏览", x + 154, rowY + 18, 62, 23)
                }
            }

        case .thresholds:
            dlg_add_card(dlg, 34, y, 440, 170)
            dlg_add_static(dlg, en ? "Rate window (minutes)" : "速率窗口（分钟）", 50, y + 16, 174, 22)
            dlg_add_edit(dlg, 400, "\(draft.rateWindow)", 232, y + 12, 92, 28)
            let labels = en ? ["Burst", "Hot", "Active", "Calm"] : ["爆发", "高热", "活跃", "平静"]
            for i in 0..<4 {
                let rowY = y + 48 + Int32(i * 27)
                dlg_add_static(dlg, labels[i], 50, rowY + 3, 112, 22)
                dlg_add_edit(dlg, 401 + Int32(i), "\(draft.thresholds[i])", 174, rowY, 150, 24)
            }

        case .pricing:
            addSettingsPricingSection(at: y)

        case .customFace:
            dlg_add_card(dlg, 34, y, 440, 116)
            dlg_add_section(dlg, en ? "Design and manage clock faces" : "设计与管理表盘", 50, y + 14, 270, 22)
            dlg_add_subtitle(dlg,
                             en ? "Colors, hand geometry, markings, saved faces, apply and delete."
                                : "编辑颜色、指针几何、刻度，并管理表盘的保存、应用与删除。",
                             50, y + 42, 280, 48)
            dlg_add_push(dlg, 716, en ? "Open editor" : "打开编辑器", 344, y + 42, 114, 30)

        case .localAPI:
            dlg_add_card(dlg, 34, y, 440, 94)
            dlg_add_check(dlg, 411, en ? "Enable Local API server" : "启用本地 API 服务",
                          50, y + 18, 246, 28, draft.apiEnabled ? 1 : 0)
            dlg_add_static(dlg, en ? "Port" : "端口", 302, y + 22, 48, 22)
            dlg_add_edit(dlg, 412, "\(draft.apiPort)", 350, y + 18, 106, 28)
            dlg_add_subtitle(dlg,
                             en ? "Loopback-only usage and history endpoints" : "仅本机可访问的 usage/history 接口",
                             50, y + 56, 390, 22)
        }
    }

    private func addSettingsPricingSection(at y: Int32) {
        guard let dlg = settingsDlg else { return }
        let L = L10n.shared, en = L.language == .en
        let summary = PricingService.shared.catalogSummary
        dlg_add_card(dlg, 34, y, 440, 82)
        _ = dlg_add_static_id(dlg, 760, pricingCatalogText(summary), 48, y + 10, 308, 20)
        dlg_add_push(dlg, 750, en ? "Refresh" : L.tr("pricing.refresh"), 370, y + 8, 90, 28)
        dlg_add_subtitle(dlg, L.tr("pricing.unit"), 48, y + 34, 180, 18)
        let unpriced = PricingService.shared.unpricedModels
        dlg_add_subtitle(dlg,
                         unpriced.isEmpty ? (en ? "Unpriced models: none" : "未能计价的模型：无")
                                          : (en ? "Unpriced: \(unpriced.joined(separator: ", "))"
                                                : "未能计价：\(unpriced.joined(separator: "、"))"),
                         48, y + 56, 404, 18)

        let tableY = y + 92
        dlg_add_card(dlg, 34, tableY, 440, 242)
        dlg_add_section(dlg, L.tr("pricing.customTitle"), 48, tableY + 10, 220, 20)
        dlg_add_push(dlg, 751, L.tr("pricing.addCustom"), 328, tableY + 6, 132, 28)
        let colX: [Int32] = [48, 194, 252, 310, 372]
        let colW: [Int32] = [142, 54, 54, 58, 58]
        let headers = [L.tr("pricing.modelName"), L.tr("pricing.input"), L.tr("pricing.output"),
                       en ? "C.Read" : L.tr("pricing.cacheRead"),
                       en ? "C.Write" : L.tr("pricing.cacheWrite")]
        for i in 0..<headers.count {
            dlg_add_subtitle(dlg, headers[i], colX[i], tableY + 34, colW[i], 16)
        }
        for i in 0..<5 {
            let row = i < settingsPricingRows.count ? settingsPricingRows[i]
                : SettingsPriceRow(model: "", input: "", output: "", cacheRead: "", cacheWrite: "")
            let rowY = tableY + 54 + Int32(i * 32)
            let values = [row.model, row.input, row.output, row.cacheRead, row.cacheWrite]
            for (column, base) in [Int32(800), 810, 820, 830, 840].enumerated() {
                dlg_add_edit(dlg, base + Int32(i), values[column], colX[column], rowY, colW[column], 24)
                if i >= pricingVisibleRows { dlg_show_control(dlg, base + Int32(i), 0) }
            }
        }
        dlg_show_control(dlg, 751, pricingVisibleRows < 5 ? 1 : 0)
    }

    private func settingsEditText(_ dlg: UnsafeMutableRawPointer, _ id: Int32) -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
        defer { buffer.deallocate() }
        dlg_edit_get(dlg, id, buffer, 2048)
        return String(cString: buffer)
    }

    private func captureExpandedSettings() {
        guard let dlg = settingsDlg, let section = expandedSettingsSection, var draft = settingsDraft else { return }
        switch section {
        case .autoDetect, .customFace:
            break
        case .tools:
            draft.enabled = Set(Self.providerNames.enumerated().compactMap {
                dlg_check_get(dlg, 300 + Int32($0.offset)) == 1 ? $0.element : nil
            })
            draft.cursorCloud = dlg_check_get(dlg, 410) == 1
        case .paths:
            for (i, name) in Self.providerNames.enumerated() {
                draft.paths[name] = settingsEditText(dlg, 200 + Int32(i))
            }
        case .thresholds:
            draft.rateWindow = max(1, Int(settingsEditText(dlg, 400)) ?? draft.rateWindow)
            for i in 0..<4 {
                draft.thresholds[i] = max(0, Int(settingsEditText(dlg, 401 + Int32(i))) ?? draft.thresholds[i])
            }
            normalizeThresholds(&draft.thresholds)
        case .pricing:
            settingsPricingRows = (0..<5).map { i in
                SettingsPriceRow(model: settingsEditText(dlg, 800 + Int32(i)),
                                 input: settingsEditText(dlg, 810 + Int32(i)),
                                 output: settingsEditText(dlg, 820 + Int32(i)),
                                 cacheRead: settingsEditText(dlg, 830 + Int32(i)),
                                 cacheWrite: settingsEditText(dlg, 840 + Int32(i)))
            }
        case .localAPI:
            draft.apiEnabled = dlg_check_get(dlg, 411) == 1
            let port = Int(settingsEditText(dlg, 412)) ?? draft.apiPort
            if (1024...65535).contains(port) { draft.apiPort = port }
        }
        settingsDraft = draft
    }

    private func loadSettingsPricingRows() {
        let models = PricingService.shared.customModels
        settingsPricingRows = (0..<5).map { index in
            guard index < models.count,
                  let price = PricingService.shared.customPrice(for: models[index]) else {
                return SettingsPriceRow(model: "", input: "", output: "", cacheRead: "", cacheWrite: "")
            }
            return SettingsPriceRow(model: models[index],
                                    input: String(format: "%.6g", price.input),
                                    output: String(format: "%.6g", price.output),
                                    cacheRead: price.cacheRead == 0 ? "" : String(format: "%.6g", price.cacheRead),
                                    cacheWrite: price.cacheWrite == 0 ? "" : String(format: "%.6g", price.cacheWrite))
        }
        pricingVisibleRows = min(5, max(1, models.count + 1))
    }

    private func commitSettingsPricingRows() {
        var seen = Set<String>()
        for row in settingsPricingRows {
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            seen.insert(model)
            PricingService.shared.setCustomPrice(
                model: model,
                price: ModelPrice(input: Double(row.input) ?? 0,
                                  output: Double(row.output) ?? 0,
                                  cacheRead: Double(row.cacheRead) ?? 0,
                                  cacheWrite: Double(row.cacheWrite) ?? 0)
            )
        }
        for old in PricingService.shared.customModels where !seen.contains(old) {
            PricingService.shared.setCustomPrice(model: old, price: nil)
        }
    }

    private func editToolSelection(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Tool Selection" : "工具选择", 520, 548) else { return }
        dlg_add_title(dlg, en ? "Tool Selection" : "工具选择", 24, 14, 360, 30)
        dlg_add_subtitle(dlg, en ? "Only enabled providers participate in scans." : "仅扫描已启用的 provider。", 24, 49, 460, 20)
        dlg_add_card(dlg, 20, 76, 468, 264)
        for (i, name) in Self.providerNames.enumerated() {
            let col = i / 6, row = i % 6
            let entry = Self.providerEntries[i]
            let label = entry.statisticsSupport == .contractOnly
                ? "\(name) · \(en ? "No stats" : "仅发现")"
                : name
            dlg_add_check(dlg, 300 + Int32(i), label, 24 + Int32(col * 160), 86 + Int32(row * 42), 144, 28, draft.enabled.contains(name) ? 1 : 0)
        }
        dlg_add_card(dlg, 20, 352, 468, 62)
        dlg_add_check(dlg, 410, en ? "Cursor cloud usage (contacts cursor.com)" : "Cursor 云端用量（会访问 cursor.com）", 36, 370, 430, 26, draft.cursorCloud ? 1 : 0)
        dlg_add_sep(dlg, 20, 444, 470)
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
        dlg_add_title(dlg, en ? "Data Source Paths" : "数据源路径", 24, 12, 350, 30)
        dlg_add_subtitle(dlg, en ? "Windows paths remain provider-specific." : "Windows 路径按 provider 独立维护。", 24, 46, 470, 20)
        dlg_add_card(dlg, 8, 70, 498, 386)
        let top: Int32 = 78
        for (i, entry) in Self.providerEntries.enumerated() {
            let col = i / 8, row = i % 8
            let x = Int32(14 + col * 246), y = top + Int32(row * 46)
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
        dlg_add_title(dlg, en ? "Heat Thresholds" : "热力阈值", 24, 14, 360, 30)
        dlg_add_subtitle(dlg, en ? "Tune activity levels for the dial status indicator." : "调整表盘状态指示器的活跃度分级。", 24, 49, 460, 20)
        dlg_add_card(dlg, 20, 78, 468, 158)
        dlg_add_static(dlg, en ? "Rate window (minutes)" : "速率窗口（分钟）", 36, 92, 180, 22); dlg_add_edit(dlg, 400, "\(draft.rateWindow)", 220, 88, 90, 28)
        let labels = en ? ["Burst", "Hot", "Active", "Calm"] : ["爆发", "高热", "活跃", "平静"]
        for i in 0..<4 {
            let y = 124 + Int32(i * 26)
            dlg_add_static(dlg, labels[i], 36, y + 4, 112, 22); dlg_add_edit(dlg, 401 + Int32(i), "\(draft.thresholds[i])", 160, y, 150, 24)
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

    /// 💰 费用估算分节：目录状态 + 手动刷新 + 未计价模型 + 自定义价格表（对齐 macOS Settings 同名分节）。
    private func editCostEstimation() {
        let L = L10n.shared
        let en = L.language == .en
        guard let dlg = dlg_create(en ? "Cost Estimation" : "费用估算", 520, 548) else { return }
        pricingDlg = dlg
        defer { pricingDlg = nil; dlg_destroy(dlg) }
        dlg_add_title(dlg, en ? "Cost Estimation" : "费用估算", 24, 14, 360, 30)
        // The English note wraps to two lines at the native Windows font size.
        // Reserve the full line height so the separator never cuts through it.
        dlg_add_subtitle(dlg, L.tr("pricing.note"), 24, 48, 464, 44)
        dlg_add_card(dlg, 20, 102, 468, 82)

        // 目录状态 + 手动刷新
        let summary = PricingService.shared.catalogSummary
        _ = dlg_add_static_id(dlg, 760, pricingCatalogText(summary), 34, 114, 276, 20)
        dlg_add_subtitle(dlg, L.tr("pricing.unit"), 34, 138, 200, 18)
        dlg_add_push(dlg, 750, L.tr("pricing.refresh"), 316, 114, 158, 28)

        // 未计价模型
        let unpriced = PricingService.shared.unpricedModels
        let unpricedText = unpriced.isEmpty
            ? (en ? "Unpriced models: none" : "未能计价的模型：无")
            : (en ? "Unpriced: \(unpriced.joined(separator: ", "))" : "未能计价：\(unpriced.joined(separator: "、"))")
        dlg_add_subtitle(dlg, unpricedText, 34, 158, 438, 20)

        // 自定义价格表：5 个可编辑槽位 [模型名 | 输入 | 输出 | 缓存读 | 缓存写]
        dlg_add_card(dlg, 20, 194, 468, 228)
        dlg_add_section(dlg, L.tr("pricing.customTitle"), 34, 206, 240, 20)
        dlg_add_push(dlg, 751, L.tr("pricing.addCustom"), 342, 202, 134, 28)
        let colX: [Int32] = [34, 190, 250, 310, 372]
        let colW: [Int32] = [152, 56, 56, 58, 58]
        let headers = [
            L.tr("pricing.modelName"), L.tr("pricing.input"), L.tr("pricing.output"),
            en ? "C.Read" : L.tr("pricing.cacheRead"),
            en ? "C.Write" : L.tr("pricing.cacheWrite"),
        ]
        for (c, text) in headers.enumerated() {
            dlg_add_subtitle(dlg, text, colX[c], 230, colW[c], 16)
        }
        let custom = PricingService.shared.customModels
        pricingVisibleRows = min(5, max(1, custom.count + 1))
        for i in 0..<5 {
            let y = Int32(250 + i * 32)
            let prefilled: ModelPrice? = i < custom.count
                ? PricingService.shared.customPrice(for: custom[i]) : nil
            let modelText = i < custom.count ? custom[i] : ""
            dlg_add_edit(dlg, 800 + Int32(i), modelText, colX[0], y, colW[0], 24)
            dlg_add_edit(dlg, 810 + Int32(i), prefilled.map { String(format: "%.6g", $0.input) } ?? "", colX[1], y, colW[1], 24)
            dlg_add_edit(dlg, 820 + Int32(i), prefilled.map { String(format: "%.6g", $0.output) } ?? "", colX[2], y, colW[2], 24)
            dlg_add_edit(dlg, 830 + Int32(i), prefilled.flatMap { $0.cacheRead == 0 ? nil : String(format: "%.6g", $0.cacheRead) } ?? "", colX[3], y, colW[3], 24)
            dlg_add_edit(dlg, 840 + Int32(i), prefilled.flatMap { $0.cacheWrite == 0 ? nil : String(format: "%.6g", $0.cacheWrite) } ?? "", colX[4], y, colW[4], 24)
            if i >= pricingVisibleRows {
                for base: Int32 in [800, 810, 820, 830, 840] {
                    dlg_show_control(dlg, base + Int32(i), 0)
                }
            }
        }
        dlg_show_control(dlg, 751, pricingVisibleRows < 5 ? 1 : 0)
        dlg_add_sep(dlg, 20, 446, 470)
        dlg_add_push(dlg, 1, en ? "Apply" : "应用", 288, 478, 92, 30)
        dlg_add_push(dlg, 2, en ? "Cancel" : "取消", 392, 478, 92, 30)
        if dlg_modal_cb(dlg, pricingCmdCb, nil) == 1 {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
            defer { buffer.deallocate() }
            var seenModels = Set<String>()
            for i in 0..<5 {
                dlg_edit_get(dlg, 800 + Int32(i), buffer, 512)
                let model = String(cString: buffer).trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else { continue }
                seenModels.insert(model)
                func field(_ base: Int32) -> Double {
                    dlg_edit_get(dlg, base + Int32(i), buffer, 512)
                    return Double(String(cString: buffer)) ?? 0
                }
                PricingService.shared.setCustomPrice(
                    model: model,
                    price: ModelPrice(input: field(810), output: field(820),
                                      cacheRead: field(830), cacheWrite: field(840))
                )
            }
            // 清空行 = 删除该自定义价（槽位被清空的旧条目移除）
            for old in PricingService.shared.customModels where !seenModels.contains(old) {
                PricingService.shared.setCustomPrice(model: old, price: nil)
            }
            scheduleScan(incremental: true)
        }
    }

    private func pricingCatalogText(_ summary: (count: Int, generatedAt: String?)) -> String {
        let L = L10n.shared
        return L.tr("pricing.catalog", summary.count, summary.generatedAt.map { String($0.prefix(10)) } ?? "—")
    }

    /// 刷新按钮：同步等待（带超时），结果直接改写目录状态行。额度恢复后 UI 会随下一轮扫描更新费用。
    func handlePricingCmd(id: Int32) {
        guard let dlg = pricingDlg else { return }
        if id == 751 {
            guard pricingVisibleRows < 5 else { return }
            let row = pricingVisibleRows
            pricingVisibleRows += 1
            for base: Int32 in [800, 810, 820, 830, 840] {
                dlg_show_control(dlg, base + Int32(row), 1)
            }
            dlg_show_control(dlg, 751, pricingVisibleRows < 5 ? 1 : 0)
            return
        }
        guard id == 750 else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = try? await PricingService.shared.refresh()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 12)
        let summary = PricingService.shared.catalogSummary
        dlg_set_text(dlg, 760, pricingCatalogText(summary))
    }

    private func editLocalAPI(_ draft: inout SettingsDraft) {
        let en = L10n.shared.language == .en
        guard let dlg = dlg_create(en ? "Local API" : "本地 API", 520, 245) else { return }
        dlg_add_title(dlg, en ? "Local API" : "本地 API", 24, 14, 360, 30)
        dlg_add_subtitle(dlg, en ? "Loopback-only usage and history endpoints" : "仅本机可访问的 usage/history 接口", 24, 49, 460, 20)
        dlg_add_card(dlg, 20, 76, 468, 82)
        dlg_add_check(dlg, 411, en ? "Enable Local API server" : "启用本地 API 服务", 36, 88, 250, 28, draft.apiEnabled ? 1 : 0)
        dlg_add_static(dlg, en ? "Port" : "端口", 306, 92, 50, 22); dlg_add_edit(dlg, 412, "\(draft.apiPort)", 358, 88, 108, 28)
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

    /// Accordion routing, provider folder browsing, and evidence-backed auto detection.
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
        if id == 701 {
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
            settingsDetectionStatus = L10n.shared.language == .en
                ? "Detected \(summary.foundCount)/\(summary.totalCount)"
                : "已探测 \(summary.foundCount)/\(summary.totalCount)"
            renderSettingsAccordion(scrollToExpanded: true)
            return
        }
        if id == 750 || id == 751 {
            handlePricingCmd(id: id)
            return
        }
        if id == 716 {
            captureExpandedSettings()
            openCustomThemeEditor()
            renderSettingsAccordion(scrollToExpanded: true)
            return
        }
        let section: SettingsSection
        switch id {
        case 700: section = .autoDetect
        case 710: section = .tools
        case 711: section = .paths
        case 712: section = .thresholds
        case 715: section = .pricing
        case 713: section = .customFace
        case 714: section = .localAPI
        default: return
        }
        captureExpandedSettings()
        expandedSettingsSection = expandedSettingsSection == section ? nil : section
        renderSettingsAccordion(scrollToExpanded: expandedSettingsSection != nil)
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
        // A saved custom face contains explicit dial/detail colors. It is the latest
        // user color decision and therefore supersedes any quick-contrast preset.
        UserDefaults.standard.remove(.quickContrastPreset)
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
        dlg_add_title(dlg, en ? "Custom Clock Face" : "自定义表盘", 24, 14, 360, 30)
        dlg_add_subtitle(dlg, en ? "Create a face that remains native to every dial size." : "创建适用于所有表盘尺寸的自定义样式。", 24, 49, 460, 20)
        dlg_add_card(dlg, 20, 78, 468, 52)
        dlg_add_static(dlg, en ? "Name" : "名称", 32, 94, 48, 22)
        dlg_add_edit(dlg, 540, name, 82, 90, 286, 28)
        dlg_add_push(dlg, 560, en ? "New" : "新建", 380, 90, 96, 28)

        dlg_add_nav(dlg, 570, en ? "Colors" : "颜色",
                    en ? "8 face · 8 overlay and detail colors" : "8 项表盘 · 8 项叠加层与详情颜色",
                    20, 142, 468, 52)
        let marks = en
            ? "\(handStyleLabel(customCfg.handStyle).replacingOccurrences(of: " ▾", with: "")) hands · \(customCfg.showTicks ? "ticks" : "no ticks")"
            : "\(handStyleLabel(customCfg.handStyle).replacingOccurrences(of: " ▾", with: ""))指针 · \(customCfg.showTicks ? "显示刻度" : "隐藏刻度")"
        dlg_add_nav(dlg, 571, en ? "Geometry and Markings" : "几何与刻度", marks,
                    20, 206, 468, 52)
        dlg_add_card(dlg, 20, 274, 468, 160)
        dlg_add_section(dlg, en ? "Saved faces" : "已保存表盘", 34, 290, 180, 20)
        dlg_add_subtitle(dlg,
                       en ? "\(savedCount) saved · manage apply/delete from My Clock Faces" : "已保存 \(savedCount) 个 · 在“我的表盘”中应用/删除",
                       34, 320, 430, 36)
        dlg_add_subtitle(dlg,
                       en ? "Changes remain a draft until Save and Apply." : "所有修改仅在“保存并应用”后写入。",
                       34, 382, 430, 28)
        dlg_add_sep(dlg, 20, 458, 470)
        dlg_add_push(dlg, 1, en ? "Save and Apply" : "保存并应用", 248, 478, 132, 30)
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
        dlg_add_title(dlg, en ? "Custom Colors" : "自定义颜色", 24, 14, 360, 30)
        dlg_add_subtitle(dlg, en ? "Tune dial and detail colors independently." : "分别调整表盘与详情面板的颜色。", 24, 49, 460, 20)
        dlg_add_card(dlg, 14, 76, 238, 358)
        dlg_add_card(dlg, 258, 76, 248, 358)
        dlg_add_section(dlg, en ? "Face colors" : "表盘颜色", 26, 88, 180, 20)
        dlg_add_section(dlg, en ? "Overlay and detail" : "叠加层与详情", 270, 88, 220, 20)
        let labels = en
            ? ["Dial", "Rim", "Hour", "Minute", "Second", "Cap outer", "Cap inner", "Numbers",
               "Ticks", "Major ticks", "Text", "Subtext", "Panel bg", "Panel text", "Panel subtext", "Panel border"]
            : ["表盘", "外环", "时针", "分针", "秒针", "中心帽外", "中心帽内", "数字",
               "刻度", "主刻度", "文字", "次文字", "面板背景", "面板文字", "面板次文字", "面板边框"]
        for i in 0..<WindowsCustomTheme.colorKeys.count {
            let column = i / 8, row = i % 8
            let x: Int32 = column == 0 ? 26 : 270
            let y = Int32(116 + row * 38)
            dlg_add_static(dlg, labels[i], x, y + 5, 92, 22)
            dlg_add_push(dlg, 500 + Int32(i), WindowsCustomTheme.hex(customCfg.colorField(i)), x + 96, y, 132, 28)
        }
        dlg_add_sep(dlg, 20, 442, 470)
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
        dlg_add_title(dlg, en ? "Geometry and Markings" : "几何与刻度", 24, 14, 390, 30)
        dlg_add_subtitle(dlg, en ? "Match hand proportions and dial markings." : "调整指针比例与表盘标记。", 24, 49, 460, 20)
        dlg_add_card(dlg, 20, 78, 468, 178)
        dlg_add_section(dlg, en ? "Hands and dial" : "指针与表盘", 34, 90, 160, 20)
        dlg_add_static(dlg, en ? "Hand style" : "指针样式", 34, 122, 100, 22); dlg_add_push(dlg, 520, handStyleLabel(customCfg.handStyle), 142, 116, 138, 28)
        dlg_add_static(dlg, en ? "Numerals" : "数字样式", 294, 122, 92, 22); dlg_add_push(dlg, 553, numberStyleLabel(), 392, 116, 92, 28)
        dlg_add_static(dlg, en ? "Rim width" : "外环宽度", 34, 158, 100, 22); dlg_add_edit(dlg, 530, formatNumber(customCfg.rimWidth), 142, 152, 82, 28)
        dlg_add_static(dlg, en ? "Hand widths · H / M / S" : "指针宽度 · 时 / 分 / 秒", 34, 194, 190, 22)
        dlg_add_edit(dlg, 531, formatNumber(customCfg.hourWidth), 230, 188, 66, 26); dlg_add_edit(dlg, 532, formatNumber(customCfg.minuteWidth), 306, 188, 66, 26); dlg_add_edit(dlg, 533, formatNumber(customCfg.secondWidth), 382, 188, 66, 26)
        dlg_add_static(dlg, en ? "Hand lengths · H / M / S" : "指针长度 · 时 / 分 / 秒", 34, 226, 190, 22)
        dlg_add_edit(dlg, 534, formatNumber(customCfg.hourLength), 230, 220, 66, 26); dlg_add_edit(dlg, 535, formatNumber(customCfg.minuteLength), 306, 220, 66, 26); dlg_add_edit(dlg, 536, formatNumber(customCfg.secondLength), 382, 220, 66, 26)
        dlg_add_card(dlg, 20, 266, 468, 46)
        dlg_add_check(dlg, 550, en ? "Show numbers" : "显示数字", 34, 276, 138, 26, customCfg.showNumbers ? 1 : 0)
        dlg_add_check(dlg, 551, en ? "Tick marks" : "显示刻度", 178, 276, 128, 26, customCfg.showTicks ? 1 : 0)
        dlg_add_check(dlg, 552, en ? "Sky decoration" : "天空装饰", 316, 276, 160, 26, customCfg.hasDecoration ? 1 : 0)
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
private let overviewCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleOverviewCmd(id)
}
private let quotaCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleQuotaCmd(id)
}
private let pricingCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handlePricingCmd(id: id)
}
private let aboutCmdCb: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, id in
    WindowsApp.shared.handleAboutCmd(id)
}
