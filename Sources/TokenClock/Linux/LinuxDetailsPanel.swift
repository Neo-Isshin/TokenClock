import Foundation
import CGtk

private enum LinuxGroupingMode: Int {
    case session = 0
    case model = 1
}

/// Theme-aware Linux counterpart of macOS `DetailDropdownView`.
final class LinuxDetailsPanel: @unchecked Sendable {
    private static let panelWidth = 320
    private static let panelHeight = 547

    private(set) var window: UnsafeMutablePointer<GtkWidget>?
    private var card: UnsafeMutablePointer<GtkWidget>?
    private var parent: UnsafeMutablePointer<GtkWidget>?
    private var quotaWindow: UnsafeMutablePointer<GtkWidget>?
    private var quotaContent: UnsafeMutablePointer<GtkWidget>?
    private let onHistoryUsage: () -> Void
    private let onQuickContrast: () -> Void
    private let onUsageIncludesCache: (Bool) -> Void

    private var tools: [ToolUsage] = []
    private var weather = WeatherInfo()
    private var useFahrenheit = false
    private var theme: LinuxClockTheme = .classic
    private var size: LinuxClockSize = .medium
    private var grouping = LinuxGroupingMode(
        rawValue: UserDefaults.standard.int(for: .dropdownGrouping, default: 0)
    ) ?? .session
    private var valueMode: DetailValueMode = {
        if let raw = UserDefaults.standard.object(forKey: SettingsKey.dropdownValueMode.rawValue) as? Int,
           let mode = DetailValueMode(rawValue: raw) { return mode }
        return UserDefaults.standard.bool(for: .dropdownShowPercentage) ? .costPercent : .tokens
    }()
    private var expandedTools: Set<String> = []
    private var expandedModels: Set<String> = []
    private var appliedTheme: LinuxClockTheme?
    private var codexQuota = CodexQuotaSnapshot.idle
    private var claudeQuota = ClaudeQuotaSnapshot.idle
    private var antigravityQuota = ProviderQuotaSnapshot.idle(source: "Antigravity local service")
    private var cursorQuota = ProviderQuotaSnapshot.idle(source: "Cursor dashboard")
    private let quotaService = CodexQuotaService()
    private let claudeQuotaService = ClaudeQuotaService()
    private let antigravityQuotaService = AntigravityQuotaService()
    private let cursorQuotaService = CursorQuotaService()
    private let quotaLock = NSLock()
    private var pendingQuota: CodexQuotaSnapshot?
    private var pendingClaudeQuota: ClaudeQuotaSnapshot?
    private var pendingAntigravityQuota: ProviderQuotaSnapshot?
    private var pendingCursorQuota: ProviderQuotaSnapshot?
    private var quotaFetchInFlight = false
    private var claudeQuotaFetchInFlight = false
    private var antigravityQuotaFetchInFlight = false
    private var cursorQuotaFetchInFlight = false
    private var rebuildScheduled = false

    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(
        parent: UnsafeMutablePointer<GtkWidget>,
        onHistoryUsage: @escaping () -> Void,
        onQuickContrast: @escaping () -> Void,
        onUsageIncludesCache: @escaping (Bool) -> Void
    ) {
        self.parent = parent
        self.onHistoryUsage = onHistoryUsage
        self.onQuickContrast = onQuickContrast
        self.onUsageIncludesCache = onUsageIncludesCache
        buildWindow(parent: parent)
    }

    var isVisible: Bool {
        guard let window else { return false }
        return gtk_widget_get_visible(window) != 0
    }

    func update(
        tools: [ToolUsage],
        weather: WeatherInfo,
        useFahrenheit: Bool,
        theme: LinuxClockTheme,
        size: LinuxClockSize
    ) {
        self.tools = tools
        self.weather = weather
        self.useFahrenheit = useFahrenheit
        self.theme = theme
        self.size = size
        if isVisible {
            scheduleRebuild()
        } else {
            rebuild()
            applyThemeIfNeeded(force: theme == .custom)
        }
    }

    func toggle() {
        guard let window else { return }
        if isVisible {
            gtk_widget_hide(window)
        } else {
            rebuild()
            applyThemeIfNeeded()
            resizeAndPosition()
            gtk_widget_show_all(window)
        }
    }

    func hide() {
        if let window { gtk_widget_hide(window) }
    }

    func reposition() {
        guard isVisible else { return }
        resizeAndPosition()
    }

    func setKeepAbove(_ enabled: Bool) {
        guard let window else { return }
        gtk_window_set_keep_above(tc_gtk_window(window), enabled ? 1 : 0)
    }

    func setOpacity(_ opacity: Double) {
        guard let window else { return }
        gtk_widget_set_opacity(window, opacity)
    }

    fileprivate func handleAction(widget: UnsafeMutablePointer<GtkWidget>) {
        let name = String(cString: tc_gtk_widget_name(widget))
        switch name {
        case "details:session":
            grouping = .session
            UserDefaults.standard.setInt(grouping.rawValue, for: .dropdownGrouping)
        case "details:model":
            grouping = .model
            UserDefaults.standard.setInt(grouping.rawValue, for: .dropdownGrouping)
        case "details:value-mode":
            valueMode = valueMode.next
            UserDefaults.standard.setInt(valueMode.rawValue, for: .dropdownValueMode)
        case "details:cache":
            onUsageIncludesCache(!UserDefaults.standard.bool(for: .usageIncludesCacheRead))
        case "details:quota":
            showQuotaWindow()
        case "details:text-color":
            cycleQuickContrast()
            onQuickContrast()
            applyThemeIfNeeded(force: true)
        case "details:history":
            onHistoryUsage()
        case "details:quota-refresh", "details:quota-retry":
            refreshQuota(force: true)
        default:
            if name.hasPrefix("details:tool:") {
                let value = String(name.dropFirst("details:tool:".count))
                if expandedTools.contains(value) { expandedTools.remove(value) } else { expandedTools.insert(value) }
            } else if name.hasPrefix("details:model-row:") {
                let value = String(name.dropFirst("details:model-row:".count))
                if expandedModels.contains(value) { expandedModels.remove(value) } else { expandedModels.insert(value) }
            }
        }
        UserDefaults.standard.synchronize()
        scheduleRebuild()
    }

    private func buildWindow(parent: UnsafeMutablePointer<GtkWidget>) {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let createdCard = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return }
        window = createdWindow
        card = createdCard
        gtk_window_set_title(tc_gtk_window(createdWindow), "TokenClock Details")
        gtk_window_set_decorated(tc_gtk_window(createdWindow), 0)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_skip_taskbar_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_skip_pager_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_transient_for(tc_gtk_window(createdWindow), tc_gtk_window(parent))
        gtk_window_set_keep_above(
            tc_gtk_window(createdWindow),
            UserDefaults.standard.bool(for: .alwaysOnTop) ? 1 : 0
        )
        tc_gtk_prepare_transparent_window(createdWindow)
        gtk_widget_set_name(createdWindow, "tokenclock-details-window")
        gtk_widget_set_name(createdCard, "tokenclock-details-card")
        gtk_container_add(tc_gtk_container(createdWindow), createdCard)
        rebuild()
        applyThemeIfNeeded(force: true)
    }

    private func rebuild() {
        guard let card else { return }
        tc_gtk_remove_all_children(card)

        if !weather.cityName.isEmpty {
            buildWeatherBar(in: card)
            gtk_box_pack_start(tc_gtk_box(card), separator(), 0, 0, 0)
        }

        let controls = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        gtk_container_set_border_width(tc_gtk_container(controls), 10)
        gtk_box_pack_start(tc_gtk_box(card), controls, 0, 0, 0)
        let launcherRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 7)
        gtk_box_pack_start(tc_gtk_box(controls), launcherRow, 0, 0, 0)
        let detect = appendControl(
            "◉  \(tr("detail.modelDetectLine1"))\n   \(tr("detail.modelDetectLine2"))",
            name: "details:model-detect", expands: true, prominent: true, to: launcherRow
        )
        if let detect { gtk_widget_set_sensitive(detect, 0) }
        _ = appendControl(
            "◔  \(tr("detail.subscriptionQuotaLine1"))\n   \(tr("detail.subscriptionQuotaLine2"))",
            name: "details:quota", expands: true, prominent: true, to: launcherRow
        )

        let groupingRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_box_pack_start(tc_gtk_box(controls), groupingRow, 0, 0, 0)
        _ = appendControl(
            grouping == .session ? "✓  \(tr("detail.groupBySession"))" : tr("detail.groupBySession"),
            name: "details:session", expands: true, to: groupingRow
        )
        _ = appendControl(
            grouping == .model ? "✓  \(tr("detail.groupByModel"))" : tr("detail.groupByModel"),
            name: "details:model", expands: true, to: groupingRow
        )
        let displayRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
        gtk_box_pack_start(tc_gtk_box(controls), displayRow, 0, 0, 0)
        let includesCache = UserDefaults.standard.bool(for: .usageIncludesCacheRead)
        let cacheControl = appendControl(
            "\(includesCache ? "✓" : "○")  \(tr("detail.cacheDataLine1"))\n   \(tr("detail.cacheDataLine2"))",
            name: "details:cache", prominent: true, to: displayRow
        )
        if let cacheControl {
            gtk_widget_set_size_request(cacheControl, 64, -1)
            tc_gtk_add_class(cacheControl, "tokenclock-detail-third-chip")
        }
        _ = appendTextColorControl(
            "\(tr("detail.textColorLine1"))\n\(tr("detail.textColorLine2"))",
            width: 58,
            to: displayRow
        )
        _ = appendHistoryControl(
            "\(tr("detail.historyUsageLine1"))\n\(tr("detail.historyUsageLine2"))",
            width: 80,
            to: displayRow
        )
        let valueControl = appendControl(
            valueMode == .costPercent
                ? "✓  \(tr("detail.byPercent"))\n   \(tr("detail.todayUsage"))"
                : "$  \(tr("detail.byCost"))\n   \(tr("detail.byPercent"))",
            name: "details:value-mode", prominent: true, to: displayRow
        )
        if let valueControl {
            gtk_widget_set_size_request(valueControl, 86, -1)
            tc_gtk_add_class(valueControl, "tokenclock-detail-third-chip")
        }

        gtk_box_pack_start(tc_gtk_box(card), separator(), 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(card), headerRow(), 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(card), separator(), 0, 0, 0)

        guard let scroll = gtk_scrolled_window_new(nil, nil),
              let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return }
        gtk_scrolled_window_set_policy(
            tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC
        )
        gtk_container_add(tc_gtk_container(scroll), list)
        gtk_box_pack_start(tc_gtk_box(card), scroll, 1, 1, 0)

        switch grouping {
        case .session: buildSessionRows(in: list)
        case .model: buildModelRows(in: list)
        }
    }

    private func appendTextColorControl(
        _ title: String,
        width: gint,
        to box: UnsafeMutablePointer<GtkWidget>?
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let button = gtk_button_new(),
              let content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4) else { return nil }
        gtk_widget_set_name(button, "details:text-color")
        tc_gtk_add_class(button, "tokenclock-detail-chip")
        tc_gtk_add_class(button, "tokenclock-detail-action-chip")
        tc_gtk_add_class(button, "tokenclock-detail-third-chip")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        _ = tc_gtk_on_clicked(button, linuxDetailsAction, opaque)
        gtk_widget_set_size_request(button, width, -1)

        let leading = gtk_label_new("●")
        let titleLabel = gtk_label_new(title)
        gtk_widget_set_name(leading, "tokenclock-current-color-dot")
        gtk_label_set_justify(tc_gtk_label(titleLabel), GTK_JUSTIFY_CENTER)
        gtk_widget_set_hexpand(titleLabel, 1)
        gtk_box_pack_start(tc_gtk_box(content), leading, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(content), titleLabel, 1, 1, 0)
        gtk_container_add(tc_gtk_container(button), content)
        gtk_box_pack_start(tc_gtk_box(box), button, 0, 0, 0)
        return button
    }

    private func buildWeatherBar(in card: UnsafeMutablePointer<GtkWidget>) {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)
        gtk_container_set_border_width(tc_gtk_container(box), 10)
        let temperature = displayTemperature(weather.temperature)
        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
        let current = gtk_label_new("\(weather.emoji)  \(weather.cityName)  \(temperature)")
        gtk_label_set_xalign(tc_gtk_label(current), 0)
        gtk_widget_set_hexpand(current, 1)
        tc_gtk_add_class(current, "tokenclock-detail-text")
        gtk_box_pack_start(tc_gtk_box(header), current, 1, 1, 0)

        let slots = selectedForecastSlots()
        if !slots.isEmpty {
            let forecastLabel = gtk_label_new(tr("detail.forecast"))
            gtk_label_set_xalign(tc_gtk_label(forecastLabel), 1)
            tc_gtk_add_class(forecastLabel, "tokenclock-detail-subtext")
            gtk_box_pack_end(tc_gtk_box(header), forecastLabel, 0, 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(box), header, 0, 0, 0)

        if !slots.isEmpty {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
            for slot in slots {
                let hour = forecastHour(slot.time)
                let label = gtk_label_new("\(String(format: "%02d", hour)):00\n\(slot.emoji)  \(displayTemperature(slot.tempC))")
                gtk_label_set_justify(tc_gtk_label(label), GTK_JUSTIFY_CENTER)
                gtk_widget_set_hexpand(label, 1)
                tc_gtk_add_class(label, "tokenclock-detail-subtext")
                gtk_box_pack_start(tc_gtk_box(row), label, 1, 1, 0)
            }
            gtk_box_pack_start(tc_gtk_box(box), row, 0, 0, 2)
        }
        gtk_box_pack_start(tc_gtk_box(card), box, 0, 0, 0)
    }

    private func selectedForecastSlots() -> [HourlyForecast] {
        guard !weather.forecast.isEmpty else { return [] }
        let currentHour = Calendar.current.component(.hour, from: Date())
        var index = 0
        var previous = -1
        for (candidate, slot) in weather.forecast.enumerated() {
            let hour = forecastHour(slot.time)
            if previous > hour { break }
            if hour <= currentHour { index = candidate } else { break }
            previous = hour
        }
        return Array(weather.forecast.dropFirst(index).prefix(4))
    }

    private func forecastHour(_ value: String) -> Int {
        if value.count <= 2 { return Int(value) ?? 0 }
        if value.count == 3 { return Int(value.prefix(1)) ?? 0 }
        return Int(value.prefix(2)) ?? 0
    }

    private func displayTemperature(_ celsius: Int) -> String {
        if useFahrenheit { return "\(Int(Double(celsius) * 9 / 5 + 32))°F" }
        return "\(celsius)°C"
    }

    private func appendControl(
        _ title: String,
        name: String,
        expands: Bool = false,
        prominent: Bool = false,
        to box: UnsafeMutablePointer<GtkWidget>?
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let button = gtk_button_new_with_label(title) else { return nil }
        gtk_widget_set_name(button, name)
        tc_gtk_add_class(button, "tokenclock-detail-chip")
        if prominent { tc_gtk_add_class(button, "tokenclock-detail-action-chip") }
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        _ = tc_gtk_on_clicked(button, linuxDetailsAction, opaque)
        if expands { gtk_widget_set_hexpand(button, 1) }
        gtk_box_pack_start(tc_gtk_box(box), button, expands ? 1 : 0, expands ? 1 : 0, 0)
        return button
    }

    private func appendHistoryControl(
        _ title: String,
        width: gint,
        to box: UnsafeMutablePointer<GtkWidget>?
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let button = gtk_button_new(),
              let content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5) else { return nil }
        gtk_widget_set_name(button, "details:history")
        tc_gtk_add_class(button, "tokenclock-detail-chip")
        tc_gtk_add_class(button, "tokenclock-detail-action-chip")
        tc_gtk_add_class(button, "tokenclock-detail-third-chip")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        _ = tc_gtk_on_clicked(button, linuxDetailsAction, opaque)
        gtk_widget_set_size_request(button, width, -1)

        let leading = gtk_label_new("◷")
        let titleLabel = gtk_label_new(title)
        gtk_label_set_justify(tc_gtk_label(titleLabel), GTK_JUSTIFY_CENTER)
        gtk_widget_set_hexpand(titleLabel, 1)
        gtk_box_pack_start(tc_gtk_box(content), leading, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(content), titleLabel, 1, 1, 0)
        gtk_container_add(tc_gtk_container(button), content)
        gtk_box_pack_start(tc_gtk_box(box), button, 0, 0, 0)
        return button
    }

    private func headerRow() -> UnsafeMutablePointer<GtkWidget>? {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_container_set_border_width(tc_gtk_container(row), 8)
        let first = grouping == .session ? tr("detail.instance") : tr("detail.model")
        appendLabel(first, width: 130, expands: true, alignment: 0, style: "tokenclock-detail-header", to: row)
        appendLabel(tr(valueMode == .tokens ? "detail.todayUsage" : "detail.cost"), width: 60, alignment: 1, style: "tokenclock-detail-header", to: row)
        appendLabel(tr(valueMode == .tokens ? "detail.messages" : "detail.share"), width: 40, alignment: 1, style: "tokenclock-detail-header", to: row)
        if grouping == .session {
            appendLabel(tr("detail.cacheRate"), width: 44, alignment: 1, style: "tokenclock-detail-header", to: row)
        }
        appendLabel(tr("detail.cost"), width: 56, alignment: 1, style: "tokenclock-detail-header", to: row)
        return row
    }

    private func buildSessionRows(in list: UnsafeMutablePointer<GtkWidget>) {
        let active = tools.filter { $0.todayTokens > 0 || $0.todayMessages > 0 }
        guard !active.isEmpty else {
            appendEmptyState(to: list)
            return
        }
        let includeCache = UserDefaults.standard.bool(for: .usageIncludesCacheRead)
        let total = max(1, UsageAggregator.totalTokens(tools, includingCacheRead: includeCache))
        for (index, tool) in active.enumerated() {
            if index > 0 { gtk_box_pack_start(tc_gtk_box(list), separator(), 0, 0, 0) }
            let expanded = expandedTools.contains(tool.name)
            let prefix = tool.sessions.isEmpty ? "  " : (expanded ? "▾" : "▸")
            let title = "\(prefix) \(tool.emoji) \(tool.name)"
            appendDataRow(
                title: title,
                tokens: primaryValue(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, cost: tool.todayCost, includeCacheRead: includeCache),
                messages: secondaryValue(tokens: tool.todayTokens, cacheRead: tool.todayCacheReadTokens, messages: tool.todayMessages, total: total, includeCacheRead: includeCache),
                trailing: cacheText(tool.cacheRate),
                cost: tool.formattedCost,
                actionName: tool.sessions.isEmpty ? nil : "details:tool:\(tool.name)",
                child: false,
                to: list
            )
            if expanded {
                for session in tool.sessions {
                    let activeMarker = session.isActive ? "●" : "○"
                    var name = "    \(activeMarker) \(session.displayName)"
                    if let source = session.source, !source.isEmpty { name += " · \(source)" }
                    appendDataRow(
                        title: name,
                        tokens: primaryValue(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, cost: session.todayCost, includeCacheRead: includeCache),
                        messages: secondaryValue(tokens: session.todayTokens, cacheRead: session.cacheReadTokens, messages: session.todayMessages, total: total, includeCacheRead: includeCache),
                        trailing: "–",
                        cost: session.formattedCost,
                        actionName: nil,
                        child: true,
                        to: list
                    )
                }
            }
        }
    }

    private func buildModelRows(in list: UnsafeMutablePointer<GtkWidget>) {
        let groups = UsageAggregator.groupedByModel(
            tools, unknownLabel: tr("detail.unknownModel")
        )
        guard !groups.isEmpty else {
            appendEmptyState(to: list)
            return
        }
        let includeCache = UserDefaults.standard.bool(for: .usageIncludesCacheRead)
        let total = max(1, UsageAggregator.totalTokens(tools, includingCacheRead: includeCache))
        for (index, group) in groups.enumerated() {
            if index > 0 { gtk_box_pack_start(tc_gtk_box(list), separator(), 0, 0, 0) }
            let expanded = expandedModels.contains(group.name)
            let prefix = group.contributions.isEmpty ? "  " : (expanded ? "▾" : "▸")
            appendDataRow(
                title: "\(prefix) \(group.emoji) \(group.name)",
                tokens: primaryValue(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, cost: group.totalCost, includeCacheRead: includeCache),
                messages: secondaryValue(tokens: group.totalTokens, cacheRead: group.totalCacheReadTokens, messages: group.totalMessages, total: total, includeCacheRead: includeCache),
                trailing: nil,
                cost: group.formattedCost,
                actionName: group.contributions.isEmpty ? nil : "details:model-row:\(group.name)",
                child: false,
                to: list
            )
            if expanded {
                for contribution in group.contributions {
                    appendDataRow(
                        title: "    \(contribution.emoji) \(contribution.tool)",
                        tokens: primaryValue(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, cost: contribution.cost, includeCacheRead: includeCache),
                        messages: secondaryValue(tokens: contribution.tokens, cacheRead: contribution.cacheReadTokens, messages: contribution.messages, total: total, includeCacheRead: includeCache),
                        trailing: nil,
                        cost: contribution.formattedCost,
                        actionName: nil,
                        child: true,
                        to: list
                    )
                }
            }
        }
    }

    private func appendDataRow(
        title: String,
        tokens: String,
        messages: String,
        trailing: String?,
        cost: String? = nil,
        actionName: String?,
        child: Bool,
        to list: UnsafeMutablePointer<GtkWidget>
    ) {
        guard let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0) else { return }
        gtk_container_set_border_width(tc_gtk_container(row), child ? 5 : 7)
        tc_gtk_add_class(row, child ? "tokenclock-detail-child-row" : "tokenclock-detail-row")
        appendLabel(title, width: 130, expands: true, alignment: 0, style: child ? "tokenclock-detail-subtext" : "tokenclock-detail-text", to: row)
        appendLabel(tokens, width: 60, alignment: 1, style: "tokenclock-detail-text", to: row)
        appendLabel(messages, width: 40, alignment: 1, style: "tokenclock-detail-subtext", to: row)
        if let trailing {
            appendLabel(trailing, width: 44, alignment: 1, style: "tokenclock-detail-subtext", to: row)
        }
        if let cost {
            appendLabel(cost, width: 56, alignment: 1, style: "tokenclock-detail-subtext", to: row)
        }

        if let actionName, let button = gtk_button_new() {
            gtk_widget_set_name(button, actionName)
            tc_gtk_add_class(button, "tokenclock-detail-row-button")
            gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
            gtk_container_add(tc_gtk_container(button), row)
            _ = tc_gtk_on_clicked(button, linuxDetailsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(list), button, 0, 0, 0)
        } else {
            gtk_box_pack_start(tc_gtk_box(list), row, 0, 0, 0)
        }
    }

    private func appendLabel(
        _ text: String,
        width: Int,
        expands: Bool = false,
        alignment: Float,
        style: String,
        to box: UnsafeMutablePointer<GtkWidget>?
    ) {
        guard let label = gtk_label_new(text) else { return }
        gtk_label_set_xalign(tc_gtk_label(label), alignment)
        gtk_label_set_ellipsize(tc_gtk_label(label), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(label, gint(width), -1)
        tc_gtk_add_class(label, style)
        gtk_box_pack_start(tc_gtk_box(box), label, expands ? 1 : 0, expands ? 1 : 0, 0)
    }

    private func appendEmptyState(to list: UnsafeMutablePointer<GtkWidget>) {
        guard let label = gtk_label_new(
            localized(zh: "今天尚未发现本地 AI 用量", en: "No local AI usage found today")
        ) else { return }
        tc_gtk_add_class(label, "tokenclock-detail-subtext")
        gtk_widget_set_vexpand(label, 1)
        gtk_box_pack_start(tc_gtk_box(list), label, 1, 1, 24)
    }

    private func showQuotaWindow() {
        if quotaWindow == nil {
            guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
                  let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return }
            quotaWindow = created
            quotaContent = content
            gtk_window_set_title(tc_gtk_window(created), tr("quota.windowTitle"))
            gtk_window_set_default_size(tc_gtk_window(created), 430, 650)
            gtk_window_set_resizable(tc_gtk_window(created), 1)
            if let parent { gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent)) }
            gtk_window_set_keep_above(tc_gtk_window(created), 1)
            gtk_container_add(tc_gtk_container(created), content)
            _ = tc_gtk_hide_on_delete(created)
        }
        refreshQuota()
        rebuildQuotaWindow()
        if let quotaWindow {
            gtk_widget_show_all(quotaWindow)
            gtk_window_present(tc_gtk_window(quotaWindow))
        }
    }

    private func rebuildQuotaWindow() {
        guard let quotaContent else { return }
        tc_gtk_remove_all_children(quotaContent)
        buildQuotaContent(in: quotaContent)
        if let quotaWindow, gtk_widget_get_visible(quotaWindow) != 0 { gtk_widget_show_all(quotaWindow) }
    }

    private func buildQuotaContent(in card: UnsafeMutablePointer<GtkWidget>) {
        guard let scroll = gtk_scrolled_window_new(nil, nil),
              let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10) else { return }
        gtk_scrolled_window_set_policy(
            tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC
        )
        gtk_container_set_border_width(tc_gtk_container(content), 12)
        gtk_container_add(tc_gtk_container(scroll), content)
        gtk_box_pack_start(tc_gtk_box(card), scroll, 1, 1, 0)

        let heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        let title = gtk_label_new(tr("quota.subscriptions"))
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        tc_gtk_add_class(title, "tokenclock-quota-title")
        gtk_box_pack_start(tc_gtk_box(heading), title, 1, 1, 0)
        _ = appendControl("↻", name: "details:quota-refresh", to: heading)
        gtk_box_pack_start(tc_gtk_box(content), heading, 0, 0, 0)

        appendQuotaProviderHeading(
            "🤖 Codex", plan: codexQuota.planType,
            loading: codexQuota.status == .loading, to: content
        )

        if codexQuota.buckets.isEmpty {
            appendQuotaUnavailable(
                tr(codexQuota.status == .loading ? "quota.loadingCodex" : "quota.codexUnavailable"),
                to: content
            )
        } else {
            for bucket in codexQuota.buckets { appendQuotaCard(bucket, to: content) }
        }

        let metadata = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5)
        if codexQuota.hasUnlimitedCredits {
            appendQuotaChip(tr("quota.unlimited"), to: metadata)
        } else if let balance = codexQuota.creditBalance, balance != "0" {
            appendQuotaChip(tr("quota.creditBalance", balance), to: metadata)
        }
        if codexQuota.resetCreditCount > 0 {
            appendQuotaChip(tr("quota.resetCredits", codexQuota.resetCreditCount), to: metadata)
        }
        let hasCodexMetadata = codexQuota.hasUnlimitedCredits
            || (codexQuota.creditBalance.map { $0 != "0" } ?? false)
            || codexQuota.resetCreditCount > 0
        if !codexQuota.buckets.isEmpty, hasCodexMetadata {
            gtk_box_pack_start(tc_gtk_box(content), metadata, 0, 0, 0)
        }

        var source = tr(codexQuota.source == .appServer ? "quota.liveSource" : "quota.logSource")
        if let refreshedAt = codexQuota.refreshedAt {
            source += "  ·  " + tr("quota.updated", quotaUpdatedLabel(refreshedAt))
        }
        if !codexQuota.buckets.isEmpty {
            let sourceLabel = gtk_label_new("●  \(source)")
            gtk_label_set_xalign(tc_gtk_label(sourceLabel), 0)
            tc_gtk_add_class(sourceLabel, "tokenclock-quota-source")
            gtk_box_pack_start(tc_gtk_box(content), sourceLabel, 0, 0, 2)
        }

        gtk_box_pack_start(tc_gtk_box(content), separator(), 0, 0, 4)
        appendQuotaProviderHeading(
            "✳️ Claude Code", plan: claudeQuota.planType,
            loading: claudeQuota.status == .loading, to: content
        )
        if claudeQuota.buckets.isEmpty {
            appendQuotaUnavailable(
                tr(claudeQuota.status == .loading ? "quota.loadingClaude" : "quota.claudeUnavailable"),
                to: content
            )
        } else {
            for bucket in claudeQuota.buckets { appendQuotaCard(bucket, to: content) }
            var claudeSource = tr("quota.claudeSource")
            if let refreshedAt = claudeQuota.refreshedAt {
                claudeSource += "  ·  " + tr("quota.updated", quotaUpdatedLabel(refreshedAt))
            }
            let label = gtk_label_new("●  \(claudeSource)")
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            tc_gtk_add_class(label, "tokenclock-quota-source")
            gtk_box_pack_start(tc_gtk_box(content), label, 0, 0, 2)
        }

        appendProviderQuotaSection("🛸 Antigravity", snapshot: antigravityQuota,
            unavailable: tr("quota.antigravityUnavailable"), to: content)
        appendProviderQuotaSection("🖱️ Cursor", snapshot: cursorQuota,
            unavailable: tr("quota.cursorUnavailable"), to: content)
    }

    private func appendProviderQuotaSection(
        _ title: String, snapshot: ProviderQuotaSnapshot, unavailable: String,
        to content: UnsafeMutablePointer<GtkWidget>
    ) {
        gtk_box_pack_start(tc_gtk_box(content), separator(), 0, 0, 4)
        appendQuotaProviderHeading(title, plan: snapshot.planType,
            loading: snapshot.status == .loading, to: content)
        if snapshot.groups.isEmpty {
            appendQuotaUnavailable(snapshot.status == .loading
                ? tr("quota.loadingProvider", title) : unavailable, to: content)
            return
        }
        for group in snapshot.groups {
            if snapshot.groups.count > 1 || group.name != "Subscription" {
                let label = gtk_label_new(group.name)
                gtk_label_set_xalign(tc_gtk_label(label), 0)
                tc_gtk_add_class(label, "tokenclock-quota-source")
                gtk_box_pack_start(tc_gtk_box(content), label, 0, 0, 1)
            }
            for bucket in group.buckets { appendQuotaCard(bucket, to: content) }
        }
        var source = snapshot.source
        if let refreshedAt = snapshot.refreshedAt {
            source += "  ·  " + tr("quota.updated", quotaUpdatedLabel(refreshedAt))
        }
        let label = gtk_label_new("●  \(source)")
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        tc_gtk_add_class(label, "tokenclock-quota-source")
        gtk_box_pack_start(tc_gtk_box(content), label, 0, 0, 2)
    }

    private func appendQuotaProviderHeading(
        _ title: String, plan: String?, loading: Bool,
        to content: UnsafeMutablePointer<GtkWidget>
    ) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        let label = gtk_label_new(loading ? "◌  \(title)" : title)
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        tc_gtk_add_class(label, "tokenclock-quota-provider")
        gtk_box_pack_start(tc_gtk_box(row), label, 1, 1, 0)
        if let plan, !plan.isEmpty {
            appendQuotaChip(tr("quota.plan", displayPlan(plan)), to: row)
        }
        gtk_box_pack_start(tc_gtk_box(content), row, 0, 0, 0)
    }

    private func appendQuotaUnavailable(_ text: String, to content: UnsafeMutablePointer<GtkWidget>) {
        let label = gtk_label_new("◔  \(text)")
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        gtk_label_set_line_wrap(tc_gtk_label(label), 1)
        tc_gtk_add_class(label, "tokenclock-detail-subtext")
        gtk_box_pack_start(tc_gtk_box(content), label, 0, 0, 10)
    }

    private func appendQuotaCard(
        _ bucket: CodexQuotaBucket,
        to content: UnsafeMutablePointer<GtkWidget>
    ) {
        let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 9)
        gtk_container_set_border_width(tc_gtk_container(card), 12)
        tc_gtk_add_class(card, "tokenclock-quota-card")

        let heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let window = gtk_label_new(
            bucket.name.isEmpty ? quotaWindowLabel(minutes: bucket.windowMinutes) : bucket.name
        )
        gtk_label_set_xalign(tc_gtk_label(window), 0)
        tc_gtk_add_class(window, "tokenclock-quota-window")
        gtk_box_pack_start(tc_gtk_box(heading), window, 1, 1, 0)
        let percentBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        let percent = gtk_label_new(String(format: "%.0f%%", bucket.remainingPercent))
        gtk_label_set_xalign(tc_gtk_label(percent), 1)
        tc_gtk_add_class(percent, "tokenclock-quota-percent")
        gtk_box_pack_start(tc_gtk_box(percentBox), percent, 0, 0, 0)
        let remaining = gtk_label_new(tr("quota.remainingLabel"))
        gtk_label_set_xalign(tc_gtk_label(remaining), 1)
        tc_gtk_add_class(remaining, "tokenclock-quota-remaining-caption")
        gtk_box_pack_start(tc_gtk_box(percentBox), remaining, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(heading), percentBox, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(card), heading, 0, 0, 0)

        let progress = gtk_progress_bar_new()
        gtk_progress_bar_set_fraction(
            tc_gtk_progress_bar(progress), min(1, max(0, bucket.remainingPercent / 100))
        )
        tc_gtk_add_class(progress, quotaAccentClass(bucket.remainingPercent))
        gtk_box_pack_start(tc_gtk_box(card), progress, 0, 0, 0)

        if let resetsAt = bucket.resetsAt {
            let labels = quotaResetLabels(resetsAt)
            let resetRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5)
            let relative = gtk_label_new("↻  \(labels.relative)")
            gtk_label_set_xalign(tc_gtk_label(relative), 0)
            tc_gtk_add_class(relative, "tokenclock-quota-reset-relative")
            gtk_box_pack_start(tc_gtk_box(resetRow), relative, 1, 1, 0)
            let absolute = gtk_label_new(labels.absolute)
            gtk_label_set_xalign(tc_gtk_label(absolute), 1)
            gtk_label_set_ellipsize(tc_gtk_label(absolute), PANGO_ELLIPSIZE_END)
            tc_gtk_add_class(absolute, "tokenclock-quota-reset-absolute")
            gtk_box_pack_start(tc_gtk_box(resetRow), absolute, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(card), resetRow, 0, 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(content), card, 0, 0, 0)
    }

    private func appendQuotaChip(_ text: String, to row: UnsafeMutablePointer<GtkWidget>?) {
        let label = gtk_label_new(text)
        tc_gtk_add_class(label, "tokenclock-quota-chip")
        gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
    }

    private func quotaAccentClass(_ remaining: Double) -> String {
        if remaining <= 15 { return "tokenclock-quota-danger" }
        if remaining <= 35 { return "tokenclock-quota-warning" }
        return "tokenclock-quota-good"
    }

    private func quotaWindowLabel(minutes: Int) -> String {
        if minutes == 10_080 { return tr("quota.weekly") }
        if minutes >= 1_440, minutes.isMultiple(of: 1_440) {
            return tr("quota.days", minutes / 1_440)
        }
        if minutes >= 60, minutes.isMultiple(of: 60) {
            return tr("quota.hours", minutes / 60)
        }
        return tr("quota.minutes", minutes)
    }

    private func quotaResetLabels(_ date: Date) -> (relative: String, absolute: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateFormat = L10n.shared.language == .en ? "MMM d · h:mm a" : "M月d日 · HH:mm"
        let seconds = max(0, date.timeIntervalSinceNow)
        let relative: String
        if seconds >= 86_400 {
            relative = localized(zh: "\(Int(ceil(seconds / 86_400))) 天后", en: "in \(Int(ceil(seconds / 86_400)))d")
        } else if seconds >= 3_600 {
            relative = localized(zh: "\(Int(ceil(seconds / 3_600))) 小时后", en: "in \(Int(ceil(seconds / 3_600)))h")
        } else {
            relative = localized(zh: "\(Int(ceil(seconds / 60))) 分钟后", en: "in \(Int(ceil(seconds / 60)))m")
        }
        return (tr("quota.resetsRelative", relative), formatter.string(from: date))
    }

    private func displayPlan(_ raw: String) -> String {
        if raw.lowercased() == "prolite" { return "Pro" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var quickContrastPreset: Int {
        UserDefaults.standard.int(for: .quickContrastPreset, default: 0)
    }

    private func cycleQuickContrast() {
        let next = quickContrastPreset >= 3 ? 1 : quickContrastPreset + 1
        UserDefaults.standard.setInt(next, for: .quickContrastPreset)
    }

    private func quotaUpdatedLabel(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return localized(zh: "刚刚", en: "just now") }
        if seconds < 3_600 {
            return localized(zh: "\(Int(seconds / 60)) 分钟前", en: "\(Int(seconds / 60))m ago")
        }
        return localized(zh: "\(Int(seconds / 3_600)) 小时前", en: "\(Int(seconds / 3_600))h ago")
    }

    private func refreshQuota(force: Bool = false) {
        if !quotaFetchInFlight && (force || codexQuota.status != .available || codexQuota.isStale) {
            quotaFetchInFlight = true
            codexQuota = .loading(previous: codexQuota)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let snapshot = self.quotaService.fetch()
                self.quotaLock.lock(); self.pendingQuota = snapshot; self.quotaLock.unlock()
                _ = tc_gtk_idle_add(linuxDetailsQuotaReady, self.opaque)
            }
        }
        if !claudeQuotaFetchInFlight && (force || claudeQuota.status != .available || claudeQuota.isStale) {
            claudeQuotaFetchInFlight = true
            claudeQuota = .loading(previous: claudeQuota)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let snapshot = self.claudeQuotaService.fetch()
                self.quotaLock.lock(); self.pendingClaudeQuota = snapshot; self.quotaLock.unlock()
                _ = tc_gtk_idle_add(linuxDetailsClaudeQuotaReady, self.opaque)
            }
        }
        if !antigravityQuotaFetchInFlight && (force || antigravityQuota.status != .available || antigravityQuota.isStale) {
            antigravityQuotaFetchInFlight = true
            antigravityQuota = .loading(previous: antigravityQuota)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let snapshot = self.antigravityQuotaService.fetch()
                self.quotaLock.lock(); self.pendingAntigravityQuota = snapshot; self.quotaLock.unlock()
                _ = tc_gtk_idle_add(linuxDetailsAntigravityQuotaReady, self.opaque)
            }
        }
        if !cursorQuotaFetchInFlight && (force || cursorQuota.status != .available || cursorQuota.isStale) {
            cursorQuotaFetchInFlight = true
            cursorQuota = .loading(previous: cursorQuota)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let snapshot = self.cursorQuotaService.fetch()
                self.quotaLock.lock(); self.pendingCursorQuota = snapshot; self.quotaLock.unlock()
                _ = tc_gtk_idle_add(linuxDetailsCursorQuotaReady, self.opaque)
            }
        }
        rebuildQuotaWindow()
    }

    fileprivate func applyPendingQuota() {
        quotaLock.lock()
        let snapshot = pendingQuota
        pendingQuota = nil
        quotaLock.unlock()
        quotaFetchInFlight = false
        if let snapshot { codexQuota = snapshot }
        rebuildQuotaWindow()
    }

    fileprivate func applyPendingClaudeQuota() {
        quotaLock.lock()
        let snapshot = pendingClaudeQuota
        pendingClaudeQuota = nil
        quotaLock.unlock()
        claudeQuotaFetchInFlight = false
        if let snapshot { claudeQuota = snapshot }
        rebuildQuotaWindow()
    }

    fileprivate func applyPendingAntigravityQuota() {
        quotaLock.lock(); let snapshot = pendingAntigravityQuota; pendingAntigravityQuota = nil; quotaLock.unlock()
        antigravityQuotaFetchInFlight = false
        if let snapshot { antigravityQuota = snapshot }
        rebuildQuotaWindow()
    }

    fileprivate func applyPendingCursorQuota() {
        quotaLock.lock(); let snapshot = pendingCursorQuota; pendingCursorQuota = nil; quotaLock.unlock()
        cursorQuotaFetchInFlight = false
        if let snapshot { cursorQuota = snapshot }
        rebuildQuotaWindow()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        _ = tc_gtk_idle_add(linuxDetailsRebuildIdle, opaque)
    }

    fileprivate func performScheduledRebuild() {
        rebuildScheduled = false
        let visible = isVisible
        if visible, let window { gtk_widget_hide(window) }
        rebuild()
        applyThemeIfNeeded(force: true)
        if visible {
            resizeAndPosition()
            if let window { gtk_widget_show_all(window) }
        }
    }

    private func separator() -> UnsafeMutablePointer<GtkWidget>? {
        let separator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        tc_gtk_add_class(separator, "tokenclock-detail-separator")
        return separator
    }

    private func primaryValue(tokens: Int, cacheRead: Int, cost: CostEstimate, includeCacheRead: Bool) -> String {
        if valueMode == .costPercent { return CostFormat.estimate(cost) }
        return TokenFormat.compact(tokens + (includeCacheRead ? cacheRead : 0))
    }

    private func secondaryValue(tokens: Int, cacheRead: Int, messages: Int, total: Int, includeCacheRead: Bool) -> String {
        if valueMode == .tokens { return "\(messages)" }
        let shown = tokens + (includeCacheRead ? cacheRead : 0)
        guard shown > 0, total > 0 else { return "–" }
        let percent = Double(shown) / Double(total) * 100
        return percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
    }

    private func cacheText(_ rate: Double) -> String {
        guard rate > 0 else { return "–" }
        let percent = rate <= 1 ? rate * 100 : rate
        return percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
    }

    private func resizeAndPosition() {
        guard let parent, let window else { return }
        let width = Self.panelWidth
        let height = Self.panelHeight
        gtk_widget_set_size_request(window, gint(width), gint(height))
        gtk_window_resize(tc_gtk_window(window), gint(width), gint(height))
        tc_gtk_position_adjacent_panel(
            parent, window, gint(width), gint(height), 8
        )
    }

    private func applyThemeIfNeeded(force: Bool = false) {
        guard force || appliedTheme != theme else { return }
        appliedTheme = theme
        let background = css(theme.dropdownBackgroundColor)
        let quick = quickContrastColor
        let text = css(quick ?? theme.dropdownTextColor)
        let subtext = css(quick.map { LinuxColor($0.red, $0.green, $0.blue, 0.68) } ?? theme.dropdownSubtextColor)
        let header = css(quick.map { LinuxColor($0.red, $0.green, $0.blue, 0.72) } ?? theme.dropdownHeaderColor)
        let border = css(theme.dropdownBorderColor)
        let divider = css(theme.dropdownDividerColor)
        tc_gtk_apply_css(
            """
            #tokenclock-details-window { background: transparent; }
            #tokenclock-details-card {
              background: \(background);
              border: 1px solid \(border);
              border-radius: 14px;
            }
            .tokenclock-detail-text { color: \(text); font: 12px Sans; }
            .tokenclock-detail-subtext { color: \(subtext); font: 11px Sans; }
            .tokenclock-detail-header { color: \(header); font: 600 10px Sans; }
            .tokenclock-detail-separator { background: \(divider); min-height: 1px; }
            .tokenclock-detail-chip {
              color: \(text); background: alpha(\(text), 0.07);
              border: 1px solid alpha(\(text), 0.15); border-radius: 10px;
              padding: 3px 8px; font: 600 10px Sans;
            }
            .tokenclock-detail-chip:hover { background: alpha(\(text), 0.14); }
            .tokenclock-detail-action-chip { padding: 5px 10px; font: 600 11px Sans; }
            .tokenclock-detail-third-chip { padding: 5px 5px; font: 600 10px Sans; }
            #tokenclock-current-color-dot { color: \(text); font: 700 13px Sans; }
            .tokenclock-detail-row-button { background: transparent; border: 0; padding: 0; }
            .tokenclock-detail-row-button:hover { background: alpha(\(text), 0.07); }
            .tokenclock-detail-child-row { background: alpha(\(text), 0.025); }
            .tokenclock-quota-title { color: \(text); font: 600 12px Sans; letter-spacing: 0.2px; }
            .tokenclock-quota-provider { color: \(text); font: 700 12px Sans; }
            .tokenclock-quota-window { color: \(text); font: 600 12px Sans; }
            .tokenclock-quota-card {
              background: alpha(\(text), 0.075); border: 1px solid alpha(\(text), 0.14);
              border-radius: 11px;
            }
            .tokenclock-quota-chip {
              color: \(subtext); background: alpha(\(text), 0.10);
              border-radius: 9px; padding: 3px 7px; font: 600 9px Sans;
            }
            .tokenclock-quota-source { color: \(subtext); font: 500 10px Sans; }
            .tokenclock-quota-remaining-caption { color: \(subtext); font: 600 9px Sans; }
            .tokenclock-quota-percent { color: #ffffff; font: 700 16px Sans; }
            .tokenclock-quota-reset-relative { color: \(subtext); font: 600 10px Sans; }
            .tokenclock-quota-reset-absolute { color: \(subtext); font: 9px Sans; }
            .tokenclock-quota-good { color: #3ac56c; font: 700 16px Sans; }
            .tokenclock-quota-warning { color: #f0a32f; font: 700 16px Sans; }
            .tokenclock-quota-danger { color: #ef4b4b; font: 700 16px Sans; }
            progressbar trough { background: alpha(\(text), 0.09); min-height: 8px; border-radius: 4px; }
            progressbar.tokenclock-quota-good progress { background: #3ac56c; min-height: 8px; border-radius: 4px; }
            progressbar.tokenclock-quota-warning progress { background: #f0a32f; min-height: 8px; border-radius: 4px; }
            progressbar.tokenclock-quota-danger progress { background: #ef4b4b; min-height: 8px; border-radius: 4px; }
            scrollbar slider { background: alpha(\(text), 0.25); min-width: 6px; border-radius: 3px; }
            """
        )
    }

    private func css(_ color: LinuxColor) -> String {
        let r = Int((min(1, max(0, color.red)) * 255).rounded())
        let g = Int((min(1, max(0, color.green)) * 255).rounded())
        let b = Int((min(1, max(0, color.blue)) * 255).rounded())
        return String(format: "rgba(%d,%d,%d,%.3f)", r, g, b, color.alpha)
    }

    private var quickContrastColor: LinuxColor? {
        switch quickContrastPreset {
        case 1: return LinuxColor(1, 1, 1)
        case 2: return LinuxColor(0, 0, 0)
        case 3: return LinuxColor(1, 214.0 / 255.0, 10.0 / 255.0)
        default: return nil
        }
    }

    private func tr(_ key: String) -> String { L10n.shared.tr(key) }

    private func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = L10n.shared.tr(key)
        return String(format: format, arguments: args)
    }

    private func localized(zh: String, en: String) -> String {
        L10n.shared.language == .en ? en : zh
    }
}

private func detailsPanel(from data: gpointer?) -> LinuxDetailsPanel? {
    guard let data else { return nil }
    return Unmanaged<LinuxDetailsPanel>.fromOpaque(data).takeUnretainedValue()
}

private func linuxDetailsAction(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ data: gpointer?
) {
    guard let widget else { return }
    detailsPanel(from: data)?.handleAction(widget: widget)
}

private func linuxDetailsRebuildIdle(_ data: gpointer?) -> gboolean {
    detailsPanel(from: data)?.performScheduledRebuild()
    return 0
}

private func linuxDetailsQuotaReady(_ data: gpointer?) -> gboolean {
    detailsPanel(from: data)?.applyPendingQuota()
    return 0
}

private func linuxDetailsClaudeQuotaReady(_ data: gpointer?) -> gboolean {
    detailsPanel(from: data)?.applyPendingClaudeQuota()
    return 0
}

private func linuxDetailsAntigravityQuotaReady(_ data: gpointer?) -> gboolean {
    detailsPanel(from: data)?.applyPendingAntigravityQuota()
    return 0
}

private func linuxDetailsCursorQuotaReady(_ data: gpointer?) -> gboolean {
    detailsPanel(from: data)?.applyPendingCursorQuota()
    return 0
}
