import Foundation
import CGtk

/// GTK 原生用量总览。数据口径与 macOS/Windows 共用 UsageOverviewBuilder。
final class LinuxUsageOverviewWindow: @unchecked Sendable {
    private enum Period { case week, month, custom }
    private enum ChartStyle { case automatic, line, stacked }

    private let model: LinuxUsageModel
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var root: UnsafeMutablePointer<GtkWidget>?
    private var period: Period = .week
    private var grouping: UsageOverviewGrouping = .tool
    private var includesCacheRead = false
    private var chartStyle: ChartStyle = .automatic
    private var selectedDayKey: String?
    private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    private var customEnd = Date()
    private var startEntry: UnsafeMutablePointer<GtkWidget>?
    private var endEntry: UnsafeMutablePointer<GtkWidget>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, model: LinuxUsageModel) {
        self.model = model
        guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let scroll = gtk_scrolled_window_new(nil, nil),
              let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14) else { return }
        window = created
        root = content
        gtk_window_set_title(tc_gtk_window(created), L10n.shared.tr("overview.title"))
        gtk_window_set_default_size(tc_gtk_window(created), 820, 640)
        gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent))
        gtk_window_set_position(tc_gtk_window(created), GTK_WIN_POS_CENTER_ON_PARENT)
        gtk_window_set_keep_above(tc_gtk_window(created), 1)
        _ = tc_gtk_hide_on_delete(created)
        gtk_scrolled_window_set_policy(tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_container_set_border_width(tc_gtk_container(content), 18)
        gtk_container_add(tc_gtk_container(scroll), content)
        gtk_container_add(tc_gtk_container(created), scroll)
        tc_gtk_apply_css("""
        .tc-overview-title { font-size: 22px; font-weight: 700; }
        .tc-overview-subtitle { color: alpha(currentColor, .62); }
        .tc-overview-card { background: alpha(currentColor, .055); border: 1px solid alpha(currentColor, .10); border-radius: 12px; padding: 12px; }
        .tc-overview-value { font-size: 19px; font-weight: 700; }
        .tc-overview-section { font-size: 15px; font-weight: 700; margin-top: 5px; }
        .tc-overview-header { color: alpha(currentColor, .62); font-size: 11px; font-weight: 600; }
        .tc-overview-row { padding: 6px 8px; border-bottom: 1px solid alpha(currentColor, .07); }
        .tc-overview-note { color: alpha(currentColor, .62); font-size: 11px; }
        .tc-overview-sparkline { color: #1683f3; font: 700 26px Monospace; letter-spacing: 4px; }
        .tc-overview-axis { color: alpha(currentColor, .62); font-size: 9px; }
        .tc-day-selected { border: 2px solid #1683f3; }
        .tc-heat-0 { background: alpha(currentColor, .06); }
        .tc-heat-1 { background: #d9ebff; }
        .tc-heat-2 { background: #9dccff; }
        .tc-heat-3 { background: #56a8ff; }
        .tc-heat-4 { background: #1683f3; }
        .tc-model-0 { background: #1683f3; } .tc-model-text-0 { color: #1683f3; }
        .tc-model-1 { background: #8b5cf6; } .tc-model-text-1 { color: #8b5cf6; }
        .tc-model-2 { background: #f59e0b; } .tc-model-text-2 { color: #f59e0b; }
        .tc-model-3 { background: #22c55e; } .tc-model-text-3 { color: #22c55e; }
        .tc-model-4 { background: #ec4899; } .tc-model-text-4 { color: #ec4899; }
        .tc-model-5 { background: #06b6d4; } .tc-model-text-5 { color: #06b6d4; }
        .tc-model-6 { background: #6366f1; } .tc-model-text-6 { color: #6366f1; }
        .tc-model-7 { background: #ef4444; } .tc-model-text-7 { color: #ef4444; }
        """)
    }

    func show(route: UsageOverviewRoute? = nil) {
        model.persistCurrentUsage()
        if let route {
            switch route {
            case .last30Days(let selectedDateKey):
                period = .month
                selectedDayKey = selectedDateKey
            case .custom(let startDateKey, let endDateKey):
                period = .custom
                customStart = parseDate(startDateKey) ?? customStart
                customEnd = min(Date(), parseDate(endDateKey) ?? customEnd)
                selectedDayKey = nil
            }
        }
        render()
        guard let window else { return }
        gtk_widget_show_all(window)
        gtk_window_present(tc_gtk_window(window))
    }

    func hide() {
        if let window { gtk_widget_hide(window) }
    }

    func refreshLanguage() {
        if let window { gtk_window_set_title(tc_gtk_window(window), L10n.shared.tr("overview.title")) }
        render()
    }

    fileprivate func handleAction(widget: UnsafeMutablePointer<GtkWidget>) {
        let name = String(cString: tc_gtk_widget_name(widget))
        switch name {
        case "overview:period:week": period = .week; selectedDayKey = nil
        case "overview:period:month": period = .month; selectedDayKey = nil
        case "overview:period:custom": period = .custom; selectedDayKey = nil
        case "overview:group:tool": grouping = .tool
        case "overview:group:model": grouping = .model
        case "overview:include-cache": includesCacheRead.toggle()
        case "overview:chart:default": chartStyle = .automatic
        case "overview:chart:line": chartStyle = .line
        case "overview:chart:bars": chartStyle = .stacked
        case "overview:overview": selectedDayKey = nil
        case "overview:apply":
            if let startEntry, let parsed = parseDate(String(cString: gtk_entry_get_text(tc_gtk_entry(startEntry)))) {
                customStart = parsed
            }
            if let endEntry, let parsed = parseDate(String(cString: gtk_entry_get_text(tc_gtk_entry(endEntry)))) {
                customEnd = min(Date(), parsed)
            }
        default:
            if name.hasPrefix("overview:day:") {
                selectedDayKey = String(name.dropFirst("overview:day:".count))
            } else { return }
        }
        render()
    }

    private func render() {
        guard let root else { return }
        tc_gtk_remove_all_children(root)
        startEntry = nil
        endEntry = nil
        let dates = selectedDates
        let data = UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: grouping,
            includingCacheRead: includesCacheRead
        )
        let modelData = grouping == .model ? data : UsageOverviewBuilder.load(
            startDate: dates.0, endDate: dates.1, grouping: .model,
            includingCacheRead: includesCacheRead
        )
        appendHeader(data, to: root)
        if period == .custom { appendCustomRange(to: root) }
        appendMetricCards(data.summary, to: root)
        appendDaily(data, modelData: modelData, to: root)
        let selected = selectedDayKey.flatMap { key in data.days.first { $0.dateKey == key } }
        appendBreakdown(
            selected?.rows ?? data.rows,
            title: selected?.dateKey ?? L10n.shared.tr("overview.overview"),
            to: root
        )
        appendNotes(data, to: root)
        gtk_widget_show_all(root)
    }

    private func appendHeader(_ data: UsageOverviewData, to root: UnsafeMutablePointer<GtkWidget>) {
        let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
        let titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
        let title = gtk_label_new(L10n.shared.tr("overview.title"))
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        tc_gtk_add_class(title, "tc-overview-title")
        let subtitle = gtk_label_new("\(displayDate(data.startDate)) – \(displayDate(data.endDate))")
        gtk_label_set_xalign(tc_gtk_label(subtitle), 0)
        tc_gtk_add_class(subtitle, "tc-overview-subtitle")
        gtk_box_pack_start(tc_gtk_box(titles), title, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(titles), subtitle, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(top), titles, 1, 1, 0)
        appendButton(period == .week ? "✓  \(L10n.shared.tr("overview.last7Days"))" : L10n.shared.tr("overview.last7Days"), name: "overview:period:week", to: top)
        appendButton(period == .month ? "✓  \(L10n.shared.tr("overview.last30Days"))" : L10n.shared.tr("overview.last30Days"), name: "overview:period:month", to: top)
        appendButton(period == .custom ? "✓  \(L10n.shared.tr("overview.custom"))" : L10n.shared.tr("overview.custom"), name: "overview:period:custom", to: top)
        gtk_box_pack_start(tc_gtk_box(root), top, 0, 0, 0)

        let controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(controls), spacer, 1, 1, 0)
        appendButton(grouping == .tool ? "✓  \(L10n.shared.tr("overview.byTool"))" : L10n.shared.tr("overview.byTool"), name: "overview:group:tool", to: controls)
        appendButton(grouping == .model ? "✓  \(L10n.shared.tr("overview.byModel"))" : L10n.shared.tr("overview.byModel"), name: "overview:group:model", to: controls)
        appendButton(includesCacheRead ? "✓  \(L10n.shared.tr("overview.includeCache"))" : L10n.shared.tr("overview.includeCache"), name: "overview:include-cache", to: controls)
        gtk_box_pack_start(tc_gtk_box(root), controls, 0, 0, 0)

        let chartControls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        let chartSpacer = gtk_label_new("")
        gtk_widget_set_hexpand(chartSpacer, 1)
        gtk_box_pack_start(tc_gtk_box(chartControls), chartSpacer, 1, 1, 0)
        appendButton(chartStyle == .automatic ? "✓  ▦" : "▦", name: "overview:chart:default", to: chartControls)
        appendButton(chartStyle == .line ? "✓  📈" : "📈", name: "overview:chart:line", to: chartControls)
        appendButton(chartStyle == .stacked ? "✓  📊" : "📊", name: "overview:chart:bars", to: chartControls)
        gtk_box_pack_start(tc_gtk_box(root), chartControls, 0, 0, 0)
    }

    private func appendCustomRange(to root: UnsafeMutablePointer<GtkWidget>) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(row), spacer, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(row), gtk_label_new(L10n.shared.tr("overview.from")), 0, 0, 0)
        let start = gtk_entry_new()
        gtk_entry_set_width_chars(tc_gtk_entry(start), 11)
        gtk_entry_set_text(tc_gtk_entry(start), dateKey(customStart))
        gtk_box_pack_start(tc_gtk_box(row), start, 0, 0, 0)
        startEntry = start
        gtk_box_pack_start(tc_gtk_box(row), gtk_label_new(L10n.shared.tr("overview.to")), 0, 0, 0)
        let end = gtk_entry_new()
        gtk_entry_set_width_chars(tc_gtk_entry(end), 11)
        gtk_entry_set_text(tc_gtk_entry(end), dateKey(customEnd))
        gtk_box_pack_start(tc_gtk_box(row), end, 0, 0, 0)
        endEntry = end
        appendButton(L10n.shared.tr("settings.done"), name: "overview:apply", to: row)
        gtk_box_pack_start(tc_gtk_box(root), row, 0, 0, 0)
    }

    private func appendMetricCards(_ metrics: UsageOverviewMetrics, to root: UnsafeMutablePointer<GtkWidget>) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
        appendCard("🔢", tokenColumnTitle, TokenFormat.compact(displayedTokens(metrics)), to: row)
        appendCard("💬", L10n.shared.tr("overview.messages"), number(metrics.messages), to: row)
        appendCard("💵", L10n.shared.tr("overview.cost"), CostFormat.estimate(metrics.cost), to: row)
        appendCard("⚡", L10n.shared.tr("overview.averageCache"), String(format: "%@%.2f%%", metrics.cacheIsExact ? "" : "≈", metrics.averageCacheRate * 100), to: row)
        gtk_box_pack_start(tc_gtk_box(root), row, 0, 0, 0)
    }

    private func appendCard(_ emoji: String, _ title: String, _ value: String, to row: UnsafeMutablePointer<GtkWidget>?) {
        let card = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 9)
        tc_gtk_add_class(card, "tc-overview-card")
        gtk_widget_set_hexpand(card, 1)
        let icon = gtk_label_new(emoji)
        let labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
        let titleLabel = gtk_label_new(title)
        gtk_label_set_xalign(tc_gtk_label(titleLabel), 0)
        tc_gtk_add_class(titleLabel, "tc-overview-subtitle")
        let valueLabel = gtk_label_new(value)
        gtk_label_set_xalign(tc_gtk_label(valueLabel), 0)
        tc_gtk_add_class(valueLabel, "tc-overview-value")
        gtk_box_pack_start(tc_gtk_box(labels), titleLabel, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(labels), valueLabel, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(card), icon, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(card), labels, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(row), card, 1, 1, 0)
    }

    private func appendDaily(
        _ data: UsageOverviewData,
        modelData: UsageOverviewData,
        to root: UnsafeMutablePointer<GtkWidget>
    ) {
        appendSection(L10n.shared.tr("overview.daily"), to: root)
        switch chartStyle {
        case .automatic where period == .month:
            appendHeatmap(data.days, to: root)
            return
        case .line:
            appendLineChart(data.days, to: root)
            return
        case .stacked:
            appendStackedChart(modelData, to: root)
            return
        default: break
        }
        let days = data.days
        let maxTokens = max(1, days.map { displayedTokens($0.metrics) }.max() ?? 1)
        let chart = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        tc_gtk_add_class(chart, "tc-overview-card")
        for day in days.suffix(30) {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            let date = gtk_label_new(String(day.dateKey.suffix(5)))
            gtk_widget_set_size_request(date, 50, -1)
            gtk_label_set_xalign(tc_gtk_label(date), 0)
            let bar = gtk_progress_bar_new()
            let tokens = displayedTokens(day.metrics)
            gtk_progress_bar_set_fraction(tc_gtk_progress_bar(bar), Double(tokens) / Double(maxTokens))
            gtk_widget_set_hexpand(bar, 1)
            let value = gtk_label_new(TokenFormat.compact(tokens))
            gtk_widget_set_size_request(value, 68, -1)
            gtk_label_set_xalign(tc_gtk_label(value), 1)
            gtk_box_pack_start(tc_gtk_box(row), date, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), bar, 1, 1, 0)
            gtk_box_pack_start(tc_gtk_box(row), value, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(chart), row, 0, 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(root), chart, 0, 0, 0)
    }

    private func appendHeatmap(_ days: [UsageOverviewDay], to root: UnsafeMutablePointer<GtkWidget>) {
        let chart = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14)
        tc_gtk_add_class(chart, "tc-overview-card")
        let grid = gtk_grid_new()
        gtk_grid_set_row_spacing(tc_gtk_grid(grid), 5)
        gtk_grid_set_column_spacing(tc_gtk_grid(grid), 5)
        let maxTokens = max(1, days.map { displayedTokens($0.metrics) }.max() ?? 1)
        let leading: Int
        if let first = days.first, let date = parseDate(first.dateKey) {
            let weekday = Calendar.current.component(.weekday, from: date)
            leading = (weekday - Calendar.current.firstWeekday + 7) % 7
        } else { leading = 0 }
        for (index, day) in days.enumerated() {
            let slot = leading + index
            let button = dayButton(day, label: " ")
            let value = displayedTokens(day.metrics)
            let ratio = value > 0 ? log(Double(value) + 1) / log(Double(maxTokens) + 1) : 0
            tc_gtk_add_class(button, "tc-heat-\(min(4, Int((ratio * 4).rounded())))")
            gtk_widget_set_size_request(button, 25, 25)
            gtk_grid_attach(tc_gtk_grid(grid), button, gint(slot / 7), gint(slot % 7), 1, 1)
        }
        gtk_box_pack_start(tc_gtk_box(chart), grid, 0, 0, 0)
        let hint = gtk_label_new(L10n.shared.tr("overview.hoverDay"))
        gtk_label_set_xalign(tc_gtk_label(hint), 0)
        tc_gtk_add_class(hint, "tc-overview-subtitle")
        gtk_box_pack_start(tc_gtk_box(chart), hint, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(root), chart, 0, 0, 0)
    }

    private func appendLineChart(_ days: [UsageOverviewDay], to root: UnsafeMutablePointer<GtkWidget>) {
        guard let chart = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6) else { return }
        tc_gtk_add_class(chart, "tc-overview-card")
        let maxTokens = max(1, days.map { displayedTokens($0.metrics) }.max() ?? 1)
        let glyphs = Array("▁▂▃▄▅▆▇█")
        let sparkline = days.map { day -> Character in
            let ratio = Double(displayedTokens(day.metrics)) / Double(maxTokens)
            return glyphs[min(glyphs.count - 1, Int((ratio * Double(glyphs.count - 1)).rounded()))]
        }
        let line = gtk_label_new(String(sparkline))
        tc_gtk_add_class(line, "tc-overview-sparkline")
        gtk_box_pack_start(tc_gtk_box(chart), line, 0, 0, 0)
        appendDaySelector(days, to: chart)
        gtk_box_pack_start(tc_gtk_box(root), chart, 0, 0, 0)
    }

    private func appendStackedChart(_ data: UsageOverviewData, to root: UnsafeMutablePointer<GtkWidget>) {
        guard let chart = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6) else { return }
        tc_gtk_add_class(chart, "tc-overview-card")
        let legend = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        for (index, row) in data.rows.prefix(6).enumerated() {
            let label = gtk_label_new("■ \(row.name)")
            tc_gtk_add_class(label, "tc-model-text-\(index % 8)")
            gtk_box_pack_start(tc_gtk_box(legend), label, 0, 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(chart), legend, 0, 0, 0)
        let bars = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, data.days.count > 20 ? 2 : 5)
        gtk_box_set_homogeneous(tc_gtk_box(bars), 1)
        let maxTokens = max(1, data.days.map { displayedTokens($0.metrics) }.max() ?? 1)
        for day in data.days {
            let button = dayButton(day, label: nil)
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
            let total = displayedTokens(day.metrics)
            let totalHeight = max(total > 0 ? 2 : 0, Int(Double(total) / Double(maxTokens) * 72))
            let spacer = gtk_label_new("")
            gtk_widget_set_vexpand(spacer, 1)
            gtk_box_pack_start(tc_gtk_box(column), spacer, 1, 1, 0)
            for row in day.rows {
                let segment = gtk_label_new("")
                let globalIndex = data.rows.firstIndex(where: { $0.name == row.name }) ?? 0
                tc_gtk_add_class(segment, "tc-model-\(globalIndex % 8)")
                let height = max(1, Int(Double(displayedTokens(row.metrics)) / Double(max(1, total)) * Double(totalHeight)))
                gtk_widget_set_size_request(segment, 12, gint(height))
                gtk_box_pack_start(tc_gtk_box(column), segment, 0, 0, 0)
            }
            let dayLabel = gtk_label_new(axisDayLabel(day.dateKey, previous: previousDay(before: day, in: data.days)))
            tc_gtk_add_class(dayLabel, "tc-overview-axis")
            gtk_box_pack_start(tc_gtk_box(column), dayLabel, 0, 0, 0)
            gtk_container_add(tc_gtk_container(button), column)
            gtk_box_pack_start(tc_gtk_box(bars), button, 1, 1, 0)
        }
        gtk_box_pack_start(tc_gtk_box(chart), bars, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(root), chart, 0, 0, 0)
    }

    private func appendDaySelector(_ days: [UsageOverviewDay], to chart: UnsafeMutablePointer<GtkWidget>) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
        gtk_box_set_homogeneous(tc_gtk_box(row), 1)
        for (index, day) in days.enumerated() {
            let previous = index > 0 ? days[index - 1] : nil
            let button = dayButton(day, label: axisDayLabel(day.dateKey, previous: previous))
            gtk_box_pack_start(tc_gtk_box(row), button, 1, 1, 0)
        }
        gtk_box_pack_start(tc_gtk_box(chart), row, 0, 0, 0)
    }

    private func dayButton(_ day: UsageOverviewDay, label: String?) -> UnsafeMutablePointer<GtkWidget>? {
        let button = label != nil ? gtk_button_new_with_label(label!) : gtk_button_new()
        gtk_widget_set_name(button, "overview:day:\(day.dateKey)")
        gtk_widget_set_tooltip_text(button, dayTooltip(day))
        if selectedDayKey == day.dateKey { tc_gtk_add_class(button, "tc-day-selected") }
        _ = tc_gtk_on_clicked(button, linuxOverviewAction, opaque)
        return button
    }

    private func previousDay(
        before day: UsageOverviewDay,
        in days: [UsageOverviewDay]
    ) -> UsageOverviewDay? {
        guard let index = days.firstIndex(where: { $0.dateKey == day.dateKey }), index > 0 else { return nil }
        return days[index - 1]
    }

    private func axisDayLabel(_ dateKey: String, previous: UsageOverviewDay?) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3 else { return dateKey }
        let day = Int(parts[2]).map(String.init) ?? String(parts[2])
        guard let previous else { return day }
        let previousParts = previous.dateKey.split(separator: "-")
        guard previousParts.count == 3, previousParts[1] != parts[1], let date = parseDate(dateKey) else {
            return day
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM"
        return "\(formatter.string(from: date))\n\(day)"
    }

    private func dayTooltip(_ day: UsageOverviewDay) -> String {
        var lines = ["\(day.dateKey) · \(TokenFormat.compact(displayedTokens(day.metrics))) tokens"]
        lines += day.rows.map { "\($0.emoji) \($0.name): \(TokenFormat.compact(displayedTokens($0.metrics)))" }
        return lines.joined(separator: "\n")
    }

    private func appendBreakdown(
        _ rows: [UsageOverviewRow], title: String,
        to root: UnsafeMutablePointer<GtkWidget>
    ) {
        let heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let section = gtk_label_new(L10n.shared.tr("overview.breakdown"))
        gtk_label_set_xalign(tc_gtk_label(section), 0)
        tc_gtk_add_class(section, "tc-overview-section")
        gtk_box_pack_start(tc_gtk_box(heading), section, 0, 0, 0)
        appendButton(selectedDayKey == nil ? "✓  \(L10n.shared.tr("overview.overview"))" : L10n.shared.tr("overview.overview"), name: "overview:overview", to: heading)
        gtk_box_pack_start(tc_gtk_box(root), heading, 0, 0, 0)
        let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        tc_gtk_add_class(list, "tc-overview-card")
        let selectedTitle = gtk_label_new(title)
        gtk_label_set_xalign(tc_gtk_label(selectedTitle), 0)
        tc_gtk_add_class(selectedTitle, "tc-overview-value")
        gtk_box_pack_start(tc_gtk_box(list), selectedTitle, 0, 0, 4)
        appendDataRow(name: L10n.shared.tr("overview.name"), tokens: tokenColumnHeader, messages: L10n.shared.tr("overview.messages"), cost: L10n.shared.tr("overview.cost"), cache: L10n.shared.tr("overview.averageCache"), header: true, to: list)
        if rows.isEmpty {
            let empty = gtk_label_new(L10n.shared.tr("overview.noData"))
            gtk_widget_set_margin_top(empty, 18)
            gtk_widget_set_margin_bottom(empty, 18)
            tc_gtk_add_class(empty, "tc-overview-subtitle")
            gtk_box_pack_start(tc_gtk_box(list), empty, 0, 0, 0)
        }
        for row in rows {
            let name = row.name == "Unknown" ? L10n.shared.tr("detail.unknownModel") : row.name
            appendDataRow(name: "\(row.emoji)  \(name)", tokens: TokenFormat.compact(displayedTokens(row.metrics)), messages: number(row.metrics.messages), cost: CostFormat.estimate(row.metrics.cost), cache: String(format: "%@%.2f%%", row.metrics.cacheIsExact ? "" : "≈", row.metrics.averageCacheRate * 100), header: false, to: list)
        }
        gtk_box_pack_start(tc_gtk_box(root), list, 0, 0, 0)
    }

    private func appendDataRow(name: String, tokens: String, messages: String, cost: String, cache: String, header: Bool, to list: UnsafeMutablePointer<GtkWidget>?) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        tc_gtk_add_class(row, header ? "tc-overview-header" : "tc-overview-row")
        let labels = [name, tokens, messages, cost, cache]
        for (index, value) in labels.enumerated() {
            let label = gtk_label_new(value)
            gtk_label_set_xalign(tc_gtk_label(label), index == 0 ? 0 : 1)
            if index == 0 { gtk_widget_set_hexpand(label, 1) }
            else { gtk_widget_set_size_request(label, 92, -1) }
            gtk_box_pack_start(tc_gtk_box(row), label, index == 0 ? 1 : 0, index == 0 ? 1 : 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(list), row, 0, 0, 0)
    }

    private func appendNotes(_ data: UsageOverviewData, to root: UnsafeMutablePointer<GtkWidget>) {
        let notes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
        if data.containsLegacyCacheEstimate { appendNote(L10n.shared.tr("overview.estimatedCache"), to: notes) }
        if data.containsUnavailableCost { appendNote(L10n.shared.tr("overview.partialCost"), to: notes) }
        if data.containsUnknownModel { appendNote(L10n.shared.tr("overview.unknownModel"), to: notes) }
        gtk_box_pack_start(tc_gtk_box(root), notes, 0, 0, 0)
    }

    private func appendNote(_ text: String, to row: UnsafeMutablePointer<GtkWidget>?) {
        let label = gtk_label_new("ⓘ  \(text)")
        tc_gtk_add_class(label, "tc-overview-note")
        gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
    }

    private func appendSection(_ text: String, to root: UnsafeMutablePointer<GtkWidget>) {
        let label = gtk_label_new(text)
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        tc_gtk_add_class(label, "tc-overview-section")
        gtk_box_pack_start(tc_gtk_box(root), label, 0, 0, 0)
    }

    private func appendButton(_ title: String, name: String, to row: UnsafeMutablePointer<GtkWidget>?) {
        let button = gtk_button_new_with_label(title)
        gtk_widget_set_name(button, name)
        _ = tc_gtk_on_clicked(button, linuxOverviewAction, opaque)
        gtk_box_pack_start(tc_gtk_box(row), button, 0, 0, 0)
    }

    private var selectedDates: (Date, Date) {
        let end = Calendar.current.startOfDay(for: period == .custom ? customEnd : Date())
        let start: Date
        switch period {
        case .week: start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
        case .month: start = Calendar.current.date(byAdding: .day, value: -29, to: end) ?? end
        case .custom: start = Calendar.current.startOfDay(for: customStart)
        }
        return (min(start, end), max(start, end))
    }

    private func dateKey(_ date: Date) -> String { DateHelper.dateKey(from: date) }
    private func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
    private func displayDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
    private func number(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var tokenColumnTitle: String {
        L10n.shared.tr(includesCacheRead ? "overview.tokensWithCache" : "overview.tokens")
    }

    private var tokenColumnHeader: String {
        L10n.shared.tr(includesCacheRead ? "overview.tokensWithCacheShort" : "overview.tokens")
    }

    private func displayedTokens(_ metrics: UsageOverviewMetrics) -> Int {
        metrics.displayedTokens(includingCacheRead: includesCacheRead)
    }
}

private func overviewWindow(from data: gpointer?) -> LinuxUsageOverviewWindow? {
    guard let data else { return nil }
    return Unmanaged<LinuxUsageOverviewWindow>.fromOpaque(data).takeUnretainedValue()
}

private func linuxOverviewAction(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    guard let widget else { return }
    overviewWindow(from: data)?.handleAction(widget: widget)
}
