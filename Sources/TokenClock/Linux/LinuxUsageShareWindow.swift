import Foundation
import CGtk

/// Native GTK share flow. The preview and exported PNG use the same Cairo renderer,
/// so the image the user sees is the image they save or copy.
final class LinuxUsageShareWindow: @unchecked Sendable {
    private enum Mode: Hashable { case recent, month, week }
    private let model: LinuxUsageModel
    private let renderer = LinuxUsageShareRenderer()
    private var selectedDate = Date()
    private var mode: Mode = .recent
    private var recentDays = 7
    private var weekIndex = 1
    private var style: UsageShareStyle = .ink
    private var data = UsageShareBuilder.load(period: .recent(days: 7, ending: Date()))
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var preview: UnsafeMutablePointer<GtkWidget>?
    private var dateButton: UnsafeMutablePointer<GtkWidget>?
    private var titleLabel: UnsafeMutablePointer<GtkWidget>?
    private var copyButton: UnsafeMutablePointer<GtkWidget>?
    private var saveButton: UnsafeMutablePointer<GtkWidget>?
    private var rangeLabel: UnsafeMutablePointer<GtkWidget>?
    private var dayControl: UnsafeMutablePointer<GtkWidget>?
    private var weekControl: UnsafeMutablePointer<GtkWidget>?
    private var modeButtons: [Mode: UnsafeMutablePointer<GtkWidget>] = [:]
    private var styleButtons: [UsageShareStyle: UnsafeMutablePointer<GtkWidget>] = [:]
    private var nextButton: UnsafeMutablePointer<GtkWidget>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    private var period: UsageSharePeriod {
        switch mode {
        case .recent: return .recent(days: recentDays, ending: selectedDate)
        case .month: return .month(containing: selectedDate)
        case .week: return .weekOfMonth(containing: selectedDate, index: weekIndex)
        }
    }

    init(parent: UnsafeMutablePointer<GtkWidget>, model: LinuxUsageModel) {
        self.model = model
        guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12),
              let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8),
              let modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6),
              let navigation = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6),
              let styles = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6),
              let drawing = gtk_drawing_area_new(),
              let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8) else { return }
        window = created
        preview = drawing
        gtk_window_set_title(tc_gtk_window(created), L10n.shared.tr("share.title"))
        gtk_window_set_default_size(tc_gtk_window(created), 470, 680)
        gtk_window_set_resizable(tc_gtk_window(created), 0)
        gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent))
        gtk_window_set_position(tc_gtk_window(created), GTK_WIN_POS_CENTER_ON_PARENT)
        gtk_window_set_keep_above(tc_gtk_window(created), 1)
        _ = tc_gtk_hide_on_delete(created)
        gtk_container_set_border_width(tc_gtk_container(root), 16)

        let title = gtk_label_new(L10n.shared.tr("share.title"))
        titleLabel = title
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        gtk_widget_set_hexpand(title, 1)
        tc_gtk_add_class(title, "tc-share-title")
        gtk_box_pack_start(tc_gtk_box(header), title, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(root), header, 0, 0, 0)

        for (choice, name, key) in [
            (Mode.recent, "share:recent", "share.period.recent"),
            (.month, "share:month", "share.period.month"),
            (.week, "share:week", "share.period.week"),
        ] {
            let button = gtk_button_new_with_label(L10n.shared.tr(key))
            gtk_widget_set_name(button, name)
            gtk_widget_set_hexpand(button, 1)
            _ = tc_gtk_on_clicked(button, linuxUsageShareAction, opaque)
            gtk_box_pack_start(tc_gtk_box(modes), button, 1, 1, 0)
            modeButtons[choice] = button
        }
        gtk_box_pack_start(tc_gtk_box(root), modes, 0, 0, 0)

        _ = appendButton("‹", name: "share:prev", to: navigation)
        let date = gtk_button_new_with_label(shareDateLabel())
        dateButton = date
        gtk_widget_set_name(date, "share:date")
        _ = tc_gtk_on_clicked(date, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(navigation), date, 0, 0, 0)
        nextButton = appendButton("›", name: "share:next", to: navigation)
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(navigation), spacer, 1, 1, 0)
        dayControl = appendButton("", name: "share:days", to: navigation)
        weekControl = appendButton("", name: "share:week-number", to: navigation)
        gtk_box_pack_start(tc_gtk_box(root), navigation, 0, 0, 0)
        let range = gtk_label_new("")
        rangeLabel = range
        gtk_label_set_xalign(tc_gtk_label(range), 0)
        gtk_box_pack_start(tc_gtk_box(root), range, 0, 0, 0)

        gtk_widget_set_size_request(drawing, 354, 443)
        _ = tc_gtk_on_draw(drawing, linuxUsageShareDraw, opaque)
        gtk_box_pack_start(tc_gtk_box(root), drawing, 0, 0, 0)

        gtk_box_pack_start(tc_gtk_box(styles), gtk_label_new(L10n.shared.tr("share.style")), 0, 0, 0)
        for choice in UsageShareStyle.allCases {
            let button = gtk_button_new_with_label(L10n.shared.tr(choice.titleKey))
            gtk_widget_set_name(button, "share:style:\(choice.rawValue)")
            _ = tc_gtk_on_clicked(button, linuxUsageShareAction, opaque)
            gtk_box_pack_start(tc_gtk_box(styles), button, 0, 0, 0)
            styleButtons[choice] = button
        }
        gtk_box_pack_start(tc_gtk_box(root), styles, 0, 0, 0)

        let copy = gtk_button_new_with_label("⧉  \(L10n.shared.tr("share.copyImage"))")
        copyButton = copy
        gtk_widget_set_name(copy, "share:copy")
        _ = tc_gtk_on_clicked(copy, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(actions), copy, 0, 0, 0)
        let actionSpacer = gtk_label_new("")
        gtk_widget_set_hexpand(actionSpacer, 1)
        gtk_box_pack_start(tc_gtk_box(actions), actionSpacer, 1, 1, 0)
        let save = gtk_button_new_with_label("⇧  \(L10n.shared.tr("share.savePNG"))")
        saveButton = save
        gtk_widget_set_name(save, "share:save")
        tc_gtk_add_class(save, "tc-share-primary")
        _ = tc_gtk_on_clicked(save, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(actions), save, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(root), actions, 0, 0, 0)

        gtk_container_add(tc_gtk_container(created), root)
        tc_gtk_apply_css("""
        .tc-share-title { font-size: 18px; font-weight: 700; }
        .tc-share-primary { background: #1683f3; color: white; border-radius: 7px; }
        .tc-share-selected { background: #1683f3; color: white; border-radius: 7px; }
        """)
    }

    func show(initialDate: Date = Date()) {
        model.persistCurrentUsage()
        selectedDate = min(initialDate, Date())
        mode = .recent
        recentDays = Calendar.current.isDateInToday(selectedDate) ? 7 : 1
        refresh()
        if let output = ProcessInfo.processInfo.environment["TC_SHARE_OUTPUT"] {
            _ = renderer.writePNG(data: data, style: style, to: output)
        }
        guard let window else { return }
        gtk_widget_show_all(window)
        refresh()
        gtk_window_present(tc_gtk_window(window))
    }

    func refreshLanguage() {
        if let window { gtk_window_set_title(tc_gtk_window(window), L10n.shared.tr("share.title")) }
        if let titleLabel { gtk_label_set_text(tc_gtk_label(titleLabel), L10n.shared.tr("share.title")) }
        if let copyButton { gtk_button_set_label(tc_gtk_button(copyButton), "⧉  \(L10n.shared.tr("share.copyImage"))") }
        if let saveButton { gtk_button_set_label(tc_gtk_button(saveButton), "⇧  \(L10n.shared.tr("share.savePNG"))") }
        for (mode, button) in modeButtons {
            let key = mode == .recent ? "share.period.recent" : mode == .month ? "share.period.month" : "share.period.week"
            gtk_button_set_label(tc_gtk_button(button), L10n.shared.tr(key))
        }
        for (choice, button) in styleButtons {
            gtk_button_set_label(tc_gtk_button(button), L10n.shared.tr(choice.titleKey))
        }
        refresh()
    }

    fileprivate func draw(_ context: OpaquePointer) {
        guard let preview else { return }
        renderer.draw(
            context,
            width: Double(gtk_widget_get_allocated_width(preview)),
            height: Double(gtk_widget_get_allocated_height(preview)),
            data: data, style: style
        )
    }

    fileprivate func handleAction(_ widget: UnsafeMutablePointer<GtkWidget>) {
        switch String(cString: tc_gtk_widget_name(widget)) {
        case "share:date": chooseDate()
        case "share:prev": moveDate(-1)
        case "share:next": moveDate(1)
        case "share:recent": mode = .recent; refresh()
        case "share:month": mode = .month; refresh()
        case "share:week":
            mode = .week
            let day = Calendar.current.startOfDay(for: selectedDate)
            weekIndex = (1...availableWeekCount).first {
                let bounds = UsageSharePeriod.weekOfMonth(containing: selectedDate, index: $0).bounds
                return bounds.start <= day && day <= bounds.end
            } ?? 1
            refresh()
        case "share:days":
            if let window {
                let value = L10n.shared.tr("share.period.recent").withCString {
                    tc_gtk_choose_integer(window, $0, gint(recentDays), 1, 90)
                }
                if value > 0 { recentDays = Int(value); refresh() }
            }
        case "share:week-number":
            if let window {
                let value = L10n.shared.tr("share.period.week").withCString {
                    tc_gtk_choose_integer(window, $0, gint(weekIndex), 1, gint(availableWeekCount))
                }
                if value > 0 { weekIndex = Int(value); refresh() }
            }
        case "share:copy": copyImage()
        case "share:save": saveImage()
        default:
            let name = String(cString: tc_gtk_widget_name(widget))
            if name.hasPrefix("share:style:"), let choice = UsageShareStyle(rawValue: String(name.dropFirst(12))) {
                style = choice; refresh()
            }
        }
    }

    private func appendButton(
        _ title: String, name: String, to row: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let button = gtk_button_new_with_label(title) else { return nil }
        gtk_widget_set_name(button, name)
        _ = tc_gtk_on_clicked(button, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(row), button, 0, 0, 0)
        return button
    }

    private var availableWeekCount: Int {
        let count = UsageSharePeriod.month(containing: selectedDate).weekCount
        guard Calendar.current.isDate(selectedDate, equalTo: Date(), toGranularity: .month) else { return count }
        let today = Calendar.current.startOfDay(for: Date())
        return (1...count).last {
            UsageSharePeriod.weekOfMonth(containing: selectedDate, index: $0).bounds.start <= today
        } ?? 1
    }

    private func moveDate(_ direction: Int) {
        let component: Calendar.Component = mode == .recent ? .day : .month
        guard let next = Calendar.current.date(byAdding: component, value: direction, to: selectedDate) else { return }
        selectedDate = min(next, Date())
        weekIndex = min(weekIndex, availableWeekCount)
        refresh()
    }

    private func chooseDate() {
        guard let window else { return }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        var year = gint(components.year ?? 2000)
        var month = gint(components.month ?? 1)
        var day = gint(components.day ?? 1)
        let accepted = L10n.shared.tr("share.chooseDate").withCString { title in
            tc_gtk_choose_date(window, title, year, month, day, &year, &month, &day)
        }
        guard accepted != 0,
              let date = Calendar.current.date(from: DateComponents(
                year: Int(year), month: Int(month), day: Int(day)
              )) else { return }
        selectedDate = min(date, Date())
        refresh()
    }

    private func copyImage() {
        let path = NSTemporaryDirectory() + "TokenClock-\(data.dateKey).png"
        guard renderer.writePNG(data: data, style: style, to: path) else { return }
        path.withCString { _ = tc_gtk_clipboard_set_png($0) }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func saveImage() {
        guard let window else { return }
        let suggested = "TokenClock-\(data.dateKey)-\(data.endDateKey).png"
        let selected = L10n.shared.tr("share.savePNG").withCString { title in
            suggested.withCString { name in tc_gtk_choose_save_file(window, title, name) }
        }
        guard let selected else { return }
        defer { tc_g_free(selected) }
        var path = String(cString: selected)
        if !path.lowercased().hasSuffix(".png") { path += ".png" }
        _ = renderer.writePNG(data: data, style: style, to: path)
    }

    private func refresh() {
        data = UsageShareBuilder.load(period: period)
        if let dateButton { gtk_button_set_label(tc_gtk_button(dateButton), shareDateLabel()) }
        if let rangeLabel {
            gtk_label_set_text(tc_gtk_label(rangeLabel), "\(data.dateKey) — \(data.endDateKey)")
        }
        if let dayControl {
            gtk_button_set_label(tc_gtk_button(dayControl), recentDays == 1 ? L10n.shared.tr("share.oneDay") : L10n.shared.tr("share.daysCount", recentDays))
            gtk_widget_set_visible(dayControl, mode == .recent ? 1 : 0)
        }
        if let weekControl {
            gtk_button_set_label(tc_gtk_button(weekControl), L10n.shared.tr("share.weekNumber", weekIndex))
            gtk_widget_set_visible(weekControl, mode == .week ? 1 : 0)
        }
        if let nextButton {
            let forward = mode == .recent
                ? !Calendar.current.isDateInToday(selectedDate)
                : !Calendar.current.isDate(selectedDate, equalTo: Date(), toGranularity: .month)
            gtk_widget_set_sensitive(nextButton, forward ? 1 : 0)
        }
        for (choice, button) in modeButtons {
            tc_gtk_add_class(button, choice == mode ? "tc-share-selected" : "tc-share-unselected")
            tc_gtk_remove_class(button, choice == mode ? "tc-share-unselected" : "tc-share-selected")
        }
        for (choice, button) in styleButtons {
            tc_gtk_add_class(button, choice == style ? "tc-share-selected" : "tc-share-unselected")
            tc_gtk_remove_class(button, choice == style ? "tc-share-unselected" : "tc-share-selected")
        }
        if let preview { gtk_widget_queue_draw(preview) }
    }

    private func shareDateLabel() -> String {
        DateFormatter.localizedString(from: selectedDate, dateStyle: .medium, timeStyle: .none)
    }
}

private final class LinuxUsageShareRenderer {
    private typealias RGB = (Double, Double, Double)
    private let palette: [RGB] = [
        (0.31, 0.78, 0.98), (0.87, 0.51, 0.95), (1.0, 0.63, 0.39),
        (0.38, 0.84, 0.69), (0.98, 0.77, 0.31), (0.57, 0.68, 1.0),
        (0.94, 0.51, 0.60), (0.65, 0.68, 0.70),
    ]

    func writePNG(data: UsageShareData, style: UsageShareStyle = .ink, to path: String) -> Bool {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1_200, 1_500) else { return false }
        defer { cairo_surface_destroy(surface) }
        guard let context = cairo_create(surface) else { return false }
        defer { cairo_destroy(context) }
        draw(context, width: 1_200, height: 1_500, data: data, style: style)
        cairo_surface_flush(surface)
        return path.withCString { cairo_surface_write_to_png(surface, $0) == CAIRO_STATUS_SUCCESS }
    }

    func draw(
        _ context: OpaquePointer, width: Double, height: Double,
        data: UsageShareData, style: UsageShareStyle
    ) {
        let scale = min(width / 600, height / 750)
        let paper = style == .paper
        let background: RGB = style == .ink ? (0.065, 0.085, 0.11)
            : paper ? (0.96, 0.95, 0.92) : (0.035, 0.16, 0.33)
        let fg: RGB = paper ? (0.10, 0.15, 0.18) : (1, 1, 1)
        let accent: RGB = style == .ink ? (0.83, 0.97, 0.32)
            : paper ? (0.90, 0.26, 0.20) : (0.45, 0.97, 0.82)
        cairo_save(context)
        cairo_scale(context, scale, scale)
        rectangle(context, 0, 0, 600, 750, color: background)
        for x in stride(from: 0.0, through: 600, by: 48) {
            line(context, x, 0, x, 750, width: 0.3, color: fg, alpha: paper ? 0.055 : 0.035)
        }
        for y in stride(from: 0.0, through: 750, by: 48) {
            line(context, 0, y, 600, y, width: 0.3, color: fg, alpha: paper ? 0.055 : 0.035)
        }
        line(context, 38, 66, 562, 66, color: fg, alpha: 0.19)
        line(context, 38, 347, 562, 347, color: fg, alpha: 0.19)
        line(context, 38, 726, 562, 726, color: fg, alpha: 0.19)

        cairo_arc(context, 57, 38, 19, 0, .pi * 2)
        source(context, accent)
        cairo_set_line_width(context, 2.5)
        cairo_stroke(context)
        text(context, "◷", 19, 700, 57, 38, align: 1, color: accent)
        text(context, "TokenClock", 17, 700, 88, 28, color: fg)
        text(context, L10n.shared.tr("share.report"), 9, 600, 88, 51, color: fg, alpha: 0.48)
        text(context, periodTitle(data.period), 12, 700, 562, 24, align: 2, color: fg)
        text(context, "\(data.dateKey) — \(data.endDateKey)", 9, 600, 562, 49, align: 2, color: fg, alpha: 0.56)

        text(context, L10n.shared.tr("share.totalUsage"), 10, 700, 38, 129, color: accent)
        text(context, TokenFormat.compact(data.totalTokens), 62, 800, 38, 182, color: fg)
        text(context, L10n.shared.tr("share.tokens"), 10, 600, 38, 223, color: fg, alpha: 0.48)

        cairo_new_path(context)
        cairo_arc(context, 490, 174, 70, 0, .pi * 2)
        source(context, fg, alpha: 0.11)
        cairo_set_line_width(context, 12)
        cairo_stroke(context)
        var angle = -Double.pi / 2
        for (index, row) in data.rows.enumerated() {
            let amount = max(0, min(1, row.fraction))
            if amount > 0 {
                cairo_arc(context, 490, 174, 70, angle + 0.015, angle + max(0.02, amount * .pi * 2 - 0.015))
                source(context, palette[index % palette.count])
                cairo_set_line_width(context, 12)
                cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
                cairo_stroke(context)
            }
            angle += amount * .pi * 2
        }
        text(context, "\(data.rows.count)", 29, 700, 490, 169, align: 1, color: fg)
        text(context, L10n.shared.tr("share.tools"), 8, 600, 490, 190, align: 1, color: fg, alpha: 0.52)

        text(context, L10n.shared.tr("share.messages").uppercased(), 9, 600, 38, 285, color: fg, alpha: 0.47)
        text(context, number(data.messages), 21, 700, 38, 313, color: fg)
        line(context, 108, 282, 108, 325, color: fg, alpha: 0.17)
        text(context, L10n.shared.tr("share.cache").uppercased(), 9, 600, 134, 285, color: fg, alpha: 0.47)
        text(context, String(format: "%.2f%%", data.averageCacheRate * 100), 21, 700, 134, 313, color: fg)
        text(context, L10n.shared.tr("share.toolBreakdown"), 10, 700, 38, 368, color: fg, alpha: 0.55)
        text(context, String(format: "%02d", data.rows.count), 10, 700, 562, 368, align: 2, color: fg, alpha: 0.55)

        if data.rows.isEmpty {
            text(context, L10n.shared.tr("share.noUsage"), 14, 500, 300, 465, align: 1, color: fg, alpha: 0.58)
        } else {
            for (index, row) in data.rows.enumerated() {
                let y = 405.0 + Double(index) * 36
                text(context, String(format: "%02d", index + 1), 9, 500, 38, y, color: fg, alpha: 0.46)
                rectangle(context, 67, y - 13, 3, 27, color: palette[index % palette.count])
                text(context, row.emoji, 13, 500, 88, y, align: 1, color: fg)
                text(context, row.name, 12, 600, 101, y, color: fg)
                text(context, TokenFormat.compact(row.tokens), 12, 700, 518, y, align: 2, color: fg)
                text(context, String(format: "%.0f%%", row.fraction * 100), 9, 500, 562, y, align: 2, color: fg, alpha: 0.53)
            }
        }
        line(context, 38, 635, 38, 710, width: 3, color: accent)
        text(context, "“", 36, 800, 53, 653, color: accent)
        text(context, L10n.shared.tr(data.quoteKey), 17, 500, 53, 683, color: fg, alpha: 0.84)
        text(context, L10n.shared.tr("share.generatedBy"), 8, 600, 38, 739, color: fg, alpha: 0.44)
        text(context, "TOKENCLOCK", 8, 600, 562, 739, align: 2, color: fg, alpha: 0.44)
        cairo_restore(context)
    }

    private func periodTitle(_ period: UsageSharePeriod) -> String {
        switch period {
        case .recent(let days, _):
            return days == 1 ? L10n.shared.tr("share.oneDay") : L10n.shared.tr("share.daysCount", days)
        case .month: return L10n.shared.tr("share.period.month")
        case .weekOfMonth(_, let index): return L10n.shared.tr("share.weekNumber", index)
        }
    }
    private func number(_ value: Int) -> String {
        let format = NumberFormatter(); format.numberStyle = .decimal
        return format.string(from: NSNumber(value: value)) ?? "\(value)"
    }
    private func source(_ context: OpaquePointer, _ color: RGB, alpha: Double = 1) {
        cairo_set_source_rgba(context, color.0, color.1, color.2, alpha)
    }
    private func rectangle(
        _ context: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
        color: RGB
    ) {
        cairo_rectangle(context, x, y, w, h)
        source(context, color)
        cairo_fill(context)
    }
    private func line(
        _ context: OpaquePointer, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
        width: Double = 0.7, color: RGB, alpha: Double = 1
    ) {
        cairo_move_to(context, x1, y1)
        cairo_line_to(context, x2, y2)
        source(context, color, alpha: alpha)
        cairo_set_line_width(context, width)
        cairo_stroke(context)
    }
    private func text(
        _ context: OpaquePointer, _ value: String, _ size: Double, _ weight: Int,
        _ x: Double, _ y: Double, align: Int = 0, color: RGB, alpha: Double = 1
    ) {
        value.withCString { valuePointer in
            "Sans".withCString { familyPointer in
                tc_cairo_draw_text(
                    context, valuePointer, familyPointer, size, gint(weight), x, y, gint(align),
                    color.0, color.1, color.2, alpha
                )
            }
        }
    }
}
private func linuxUsageShareDraw(
    _ widget: UnsafeMutablePointer<GtkWidget>?, _ context: OpaquePointer?, _ data: gpointer?
) -> gboolean {
    guard let context, let data else { return 0 }
    Unmanaged<LinuxUsageShareWindow>.fromOpaque(data).takeUnretainedValue().draw(context)
    return 1
}

private func linuxUsageShareAction(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    guard let widget, let data else { return }
    Unmanaged<LinuxUsageShareWindow>.fromOpaque(data).takeUnretainedValue().handleAction(widget)
}
