import Foundation
import CGtk

private enum LinuxGroupingMode: Int {
    case session = 0
    case model = 1
}

/// Theme-aware Linux counterpart of macOS `DetailDropdownView`.
final class LinuxDetailsPanel: @unchecked Sendable {
    private(set) var window: UnsafeMutablePointer<GtkWidget>?
    private var card: UnsafeMutablePointer<GtkWidget>?
    private var parent: UnsafeMutablePointer<GtkWidget>?

    private var tools: [ToolUsage] = []
    private var weather = WeatherInfo()
    private var useFahrenheit = false
    private var theme: LinuxClockTheme = .classic
    private var size: LinuxClockSize = .medium
    private var grouping = LinuxGroupingMode(
        rawValue: UserDefaults.standard.int(for: .dropdownGrouping, default: 0)
    ) ?? .session
    private var showPercentage = UserDefaults.standard.bool(
        for: .dropdownShowPercentage, default: false
    )
    private var expandedTools: Set<String> = []
    private var expandedModels: Set<String> = []
    private var appliedTheme: LinuxClockTheme?

    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>) {
        self.parent = parent
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
        rebuild()
        applyThemeIfNeeded(force: theme == .custom)
        if isVisible { resizeAndPosition() }
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
        case "details:percentage":
            showPercentage.toggle()
            UserDefaults.standard.setBool(showPercentage, for: .dropdownShowPercentage)
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
        rebuild()
        applyThemeIfNeeded(force: true)
        resizeAndPosition()
        if let window { gtk_widget_show_all(window) }
    }

    private func buildWindow(parent: UnsafeMutablePointer<GtkWidget>) {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let createdCard = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return }
        window = createdWindow
        card = createdCard
        gtk_window_set_title(tc_gtk_window(createdWindow), "TokenClock Details")
        gtk_window_set_decorated(tc_gtk_window(createdWindow), 0)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 1)
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

        let controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_container_set_border_width(tc_gtk_container(controls), 10)
        gtk_box_pack_start(tc_gtk_box(card), controls, 0, 0, 0)
        appendControl(
            grouping == .session ? "✓  \(tr("detail.groupBySession"))" : tr("detail.groupBySession"),
            name: "details:session", to: controls
        )
        appendControl(
            grouping == .model ? "✓  \(tr("detail.groupByModel"))" : tr("detail.groupByModel"),
            name: "details:model", to: controls
        )
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(controls), spacer, 1, 1, 0)
        appendControl(
            showPercentage ? "✓  \(tr("detail.percent"))" : "%  \(tr("detail.percent"))",
            name: "details:percentage", to: controls
        )

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

    private func buildWeatherBar(in card: UnsafeMutablePointer<GtkWidget>) {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)
        gtk_container_set_border_width(tc_gtk_container(box), 10)
        let temperature = displayTemperature(weather.temperature)
        let current = gtk_label_new("\(weather.emoji)  \(weather.cityName)  \(temperature)")
        gtk_label_set_xalign(tc_gtk_label(current), 0)
        tc_gtk_add_class(current, "tokenclock-detail-text")
        gtk_box_pack_start(tc_gtk_box(box), current, 0, 0, 0)

        let slots = selectedForecastSlots()
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
        to box: UnsafeMutablePointer<GtkWidget>?
    ) {
        guard let button = gtk_button_new_with_label(title) else { return }
        gtk_widget_set_name(button, name)
        tc_gtk_add_class(button, "tokenclock-detail-chip")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        _ = tc_gtk_on_clicked(button, linuxDetailsAction, opaque)
        gtk_box_pack_start(tc_gtk_box(box), button, 0, 0, 0)
    }

    private func headerRow() -> UnsafeMutablePointer<GtkWidget>? {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_container_set_border_width(tc_gtk_container(row), 8)
        let first = grouping == .session ? tr("detail.instance") : tr("detail.model")
        appendLabel(first, width: 130, expands: true, alignment: 0, style: "tokenclock-detail-header", to: row)
        appendLabel(showPercentage ? tr("detail.share") : tr("detail.todayUsage"), width: 60, alignment: 1, style: "tokenclock-detail-header", to: row)
        appendLabel(tr("detail.messages"), width: 40, alignment: 1, style: "tokenclock-detail-header", to: row)
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
        let total = max(1, UsageAggregator.totalTokens(tools))
        for (index, tool) in active.enumerated() {
            if index > 0 { gtk_box_pack_start(tc_gtk_box(list), separator(), 0, 0, 0) }
            let expanded = expandedTools.contains(tool.name)
            let prefix = tool.sessions.isEmpty ? "  " : (expanded ? "▾" : "▸")
            let title = "\(prefix) \(tool.emoji) \(tool.name)"
            appendDataRow(
                title: title,
                tokens: usageText(tool.todayTokens, total: total),
                messages: "\(tool.todayMessages)",
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
                        tokens: usageText(session.todayTokens, total: total),
                        messages: "\(session.todayMessages)",
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
        let total = max(1, UsageAggregator.totalTokens(tools))
        for (index, group) in groups.enumerated() {
            if index > 0 { gtk_box_pack_start(tc_gtk_box(list), separator(), 0, 0, 0) }
            let expanded = expandedModels.contains(group.name)
            let prefix = group.contributions.isEmpty ? "  " : (expanded ? "▾" : "▸")
            appendDataRow(
                title: "\(prefix) \(group.emoji) \(group.name)",
                tokens: usageText(group.totalTokens, total: total),
                messages: "\(group.totalMessages)",
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
                        tokens: usageText(contribution.tokens, total: total),
                        messages: "\(contribution.messages)",
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

    private func separator() -> UnsafeMutablePointer<GtkWidget>? {
        let separator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        tc_gtk_add_class(separator, "tokenclock-detail-separator")
        return separator
    }

    private func usageText(_ tokens: Int, total: Int) -> String {
        guard showPercentage else { return TokenFormat.compact(tokens) }
        guard tokens > 0, total > 0 else { return "–" }
        let percent = Double(tokens) / Double(total) * 100
        return percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
    }

    private func cacheText(_ rate: Double) -> String {
        guard rate > 0 else { return "–" }
        let percent = rate <= 1 ? rate * 100 : rate
        return percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
    }

    private func resizeAndPosition() {
        guard let parent, let window else { return }
        let width = size.diameter + 80
        let rowCount: Int
        switch grouping {
        case .session:
            rowCount = tools.filter { $0.todayTokens > 0 || $0.todayMessages > 0 }.reduce(0) {
                $0 + 1 + (expandedTools.contains($1.name) ? $1.sessions.count : 0)
            }
        case .model:
            rowCount = UsageAggregator.groupedByModel(
                tools, unknownLabel: tr("detail.unknownModel")
            ).reduce(0) { $0 + 1 + (expandedModels.contains($1.name) ? $1.contributions.count : 0) }
        }
        let height = min(430, max(170, 100 + rowCount * 34))
        gtk_window_resize(tc_gtk_window(window), gint(width), gint(height))
        tc_gtk_position_adjacent_panel(
            parent, window, gint(width), gint(height), 8
        )
    }

    private func applyThemeIfNeeded(force: Bool = false) {
        guard force || appliedTheme != theme else { return }
        appliedTheme = theme
        let background = css(theme.dropdownBackgroundColor)
        let text = css(theme.dropdownTextColor)
        let subtext = css(theme.dropdownSubtextColor)
        let header = css(theme.dropdownHeaderColor)
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
            .tokenclock-detail-row-button { background: transparent; border: 0; padding: 0; }
            .tokenclock-detail-row-button:hover { background: alpha(\(text), 0.07); }
            .tokenclock-detail-child-row { background: alpha(\(text), 0.025); }
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

    private func tr(_ key: String) -> String { L10n.shared.tr(key) }

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
