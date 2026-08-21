import Foundation
import CGtk

/// GTK 原生用量总览。数据口径与 macOS/Windows 共用 UsageOverviewBuilder。
final class LinuxUsageOverviewWindow: @unchecked Sendable {
    private enum Period { case week, month, custom }

    private let model: LinuxUsageModel
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var root: UnsafeMutablePointer<GtkWidget>?
    private var period: Period = .week
    private var grouping: UsageOverviewGrouping = .tool
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
        """)
    }

    func show() {
        model.persistCurrentUsage()
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
        case "overview:period:week": period = .week
        case "overview:period:month": period = .month
        case "overview:period:custom": period = .custom
        case "overview:group:tool": grouping = .tool
        case "overview:group:model": grouping = .model
        case "overview:apply":
            if let startEntry, let parsed = parseDate(String(cString: gtk_entry_get_text(tc_gtk_entry(startEntry)))) {
                customStart = parsed
            }
            if let endEntry, let parsed = parseDate(String(cString: gtk_entry_get_text(tc_gtk_entry(endEntry)))) {
                customEnd = min(Date(), parsed)
            }
        default: return
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
            startDate: dates.0, endDate: dates.1, grouping: grouping
        )
        appendHeader(data, to: root)
        if period == .custom { appendCustomRange(to: root) }
        appendMetricCards(data.summary, to: root)
        appendDaily(data.days, to: root)
        appendBreakdown(data.rows, to: root)
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
        appendButton(grouping == .tool ? "✓  \(L10n.shared.tr("overview.byTool"))" : L10n.shared.tr("overview.byTool"), name: "overview:group:tool", to: top)
        appendButton(grouping == .model ? "✓  \(L10n.shared.tr("overview.byModel"))" : L10n.shared.tr("overview.byModel"), name: "overview:group:model", to: top)
        gtk_box_pack_start(tc_gtk_box(root), top, 0, 0, 0)
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
        appendCard("🔢", L10n.shared.tr("overview.tokens"), TokenFormat.compact(metrics.tokens), to: row)
        appendCard("💬", L10n.shared.tr("overview.messages"), number(metrics.messages), to: row)
        appendCard("💵", L10n.shared.tr("overview.cost"), CostFormat.estimate(metrics.cost), to: row)
        appendCard("⚡", L10n.shared.tr("overview.averageCache"), String(format: "%@%.1f%%", metrics.cacheIsExact ? "" : "≈", metrics.averageCacheRate * 100), to: row)
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

    private func appendDaily(_ days: [UsageOverviewDay], to root: UnsafeMutablePointer<GtkWidget>) {
        appendSection(L10n.shared.tr("overview.daily"), to: root)
        let maxTokens = max(1, days.map(\.metrics.tokens).max() ?? 1)
        let chart = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        tc_gtk_add_class(chart, "tc-overview-card")
        for day in days.suffix(30) {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            let date = gtk_label_new(String(day.dateKey.suffix(5)))
            gtk_widget_set_size_request(date, 50, -1)
            gtk_label_set_xalign(tc_gtk_label(date), 0)
            let bar = gtk_progress_bar_new()
            gtk_progress_bar_set_fraction(tc_gtk_progress_bar(bar), Double(day.metrics.tokens) / Double(maxTokens))
            gtk_widget_set_hexpand(bar, 1)
            let value = gtk_label_new(TokenFormat.compact(day.metrics.tokens))
            gtk_widget_set_size_request(value, 68, -1)
            gtk_label_set_xalign(tc_gtk_label(value), 1)
            gtk_box_pack_start(tc_gtk_box(row), date, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), bar, 1, 1, 0)
            gtk_box_pack_start(tc_gtk_box(row), value, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(chart), row, 0, 0, 0)
        }
        gtk_box_pack_start(tc_gtk_box(root), chart, 0, 0, 0)
    }

    private func appendBreakdown(_ rows: [UsageOverviewRow], to root: UnsafeMutablePointer<GtkWidget>) {
        appendSection(L10n.shared.tr("overview.breakdown"), to: root)
        let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        tc_gtk_add_class(list, "tc-overview-card")
        appendDataRow(name: L10n.shared.tr("overview.name"), tokens: L10n.shared.tr("overview.tokens"), messages: L10n.shared.tr("overview.messages"), cost: L10n.shared.tr("overview.cost"), cache: L10n.shared.tr("overview.averageCache"), header: true, to: list)
        if rows.isEmpty {
            let empty = gtk_label_new(L10n.shared.tr("overview.noData"))
            gtk_widget_set_margin_top(empty, 18)
            gtk_widget_set_margin_bottom(empty, 18)
            tc_gtk_add_class(empty, "tc-overview-subtitle")
            gtk_box_pack_start(tc_gtk_box(list), empty, 0, 0, 0)
        }
        for row in rows {
            let name = row.name == "Unknown" ? L10n.shared.tr("detail.unknownModel") : row.name
            appendDataRow(name: "\(row.emoji)  \(name)", tokens: TokenFormat.compact(row.metrics.tokens), messages: number(row.metrics.messages), cost: CostFormat.estimate(row.metrics.cost), cache: String(format: "%@%.1f%%", row.metrics.cacheIsExact ? "" : "≈", row.metrics.averageCacheRate * 100), header: false, to: list)
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
}

private func overviewWindow(from data: gpointer?) -> LinuxUsageOverviewWindow? {
    guard let data else { return nil }
    return Unmanaged<LinuxUsageOverviewWindow>.fromOpaque(data).takeUnretainedValue()
}

private func linuxOverviewAction(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    guard let widget else { return }
    overviewWindow(from: data)?.handleAction(widget: widget)
}
