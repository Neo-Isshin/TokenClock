import Foundation
import CGtk

/// Native GTK share flow. The preview and exported PNG use the same Cairo renderer,
/// so the image the user sees is the image they save or copy.
final class LinuxUsageShareWindow: @unchecked Sendable {
    private let model: LinuxUsageModel
    private let renderer = LinuxUsageShareRenderer()
    private var selectedDate = Date()
    private var data = UsageShareBuilder.load(date: Date())
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var preview: UnsafeMutablePointer<GtkWidget>?
    private var dateButton: UnsafeMutablePointer<GtkWidget>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, model: LinuxUsageModel) {
        self.model = model
        guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12),
              let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8),
              let drawing = gtk_drawing_area_new(),
              let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8) else { return }
        window = created
        preview = drawing
        gtk_window_set_title(tc_gtk_window(created), L10n.shared.tr("share.title"))
        gtk_window_set_default_size(tc_gtk_window(created), 430, 570)
        gtk_window_set_resizable(tc_gtk_window(created), 0)
        gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent))
        gtk_window_set_position(tc_gtk_window(created), GTK_WIN_POS_CENTER_ON_PARENT)
        gtk_window_set_keep_above(tc_gtk_window(created), 1)
        _ = tc_gtk_hide_on_delete(created)
        gtk_container_set_border_width(tc_gtk_container(root), 16)

        let title = gtk_label_new(L10n.shared.tr("share.title"))
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        gtk_widget_set_hexpand(title, 1)
        tc_gtk_add_class(title, "tc-share-title")
        gtk_box_pack_start(tc_gtk_box(header), title, 1, 1, 0)
        let date = gtk_button_new_with_label(shareDateLabel())
        dateButton = date
        gtk_widget_set_name(date, "share:date")
        _ = tc_gtk_on_clicked(date, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(header), date, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(root), header, 0, 0, 0)

        gtk_widget_set_size_request(drawing, 354, 443)
        _ = tc_gtk_on_draw(drawing, linuxUsageShareDraw, opaque)
        gtk_box_pack_start(tc_gtk_box(root), drawing, 0, 0, 0)

        let copy = gtk_button_new_with_label("⧉  \(L10n.shared.tr("share.copyImage"))")
        gtk_widget_set_name(copy, "share:copy")
        _ = tc_gtk_on_clicked(copy, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(actions), copy, 0, 0, 0)
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(actions), spacer, 1, 1, 0)
        let save = gtk_button_new_with_label("⇧  \(L10n.shared.tr("share.savePNG"))")
        gtk_widget_set_name(save, "share:save")
        tc_gtk_add_class(save, "tc-share-primary")
        _ = tc_gtk_on_clicked(save, linuxUsageShareAction, opaque)
        gtk_box_pack_start(tc_gtk_box(actions), save, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(root), actions, 0, 0, 0)

        gtk_container_add(tc_gtk_container(created), root)
        tc_gtk_apply_css("""
        .tc-share-title { font-size: 18px; font-weight: 700; }
        .tc-share-primary { background: #1683f3; color: white; border-radius: 7px; }
        """)
    }

    func show(initialDate: Date = Date()) {
        model.persistCurrentUsage()
        selectedDate = min(initialDate, Date())
        refresh()
        guard let window else { return }
        gtk_widget_show_all(window)
        gtk_window_present(tc_gtk_window(window))
    }

    func refreshLanguage() {
        if let window { gtk_window_set_title(tc_gtk_window(window), L10n.shared.tr("share.title")) }
        refresh()
    }

    fileprivate func draw(_ context: OpaquePointer) {
        guard let preview else { return }
        renderer.draw(
            context,
            width: Double(gtk_widget_get_allocated_width(preview)),
            height: Double(gtk_widget_get_allocated_height(preview)),
            data: data
        )
    }

    fileprivate func handleAction(_ widget: UnsafeMutablePointer<GtkWidget>) {
        switch String(cString: tc_gtk_widget_name(widget)) {
        case "share:date": chooseDate()
        case "share:copy": copyImage()
        case "share:save": saveImage()
        default: break
        }
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
        guard renderer.writePNG(data: data, to: path) else { return }
        path.withCString { _ = tc_gtk_clipboard_set_png($0) }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func saveImage() {
        guard let window else { return }
        let suggested = "TokenClock-\(data.dateKey).png"
        let selected = L10n.shared.tr("share.savePNG").withCString { title in
            suggested.withCString { name in tc_gtk_choose_save_file(window, title, name) }
        }
        guard let selected else { return }
        defer { tc_g_free(selected) }
        var path = String(cString: selected)
        if !path.lowercased().hasSuffix(".png") { path += ".png" }
        _ = renderer.writePNG(data: data, to: path)
    }

    private func refresh() {
        data = UsageShareBuilder.load(date: selectedDate)
        if let dateButton { gtk_button_set_label(tc_gtk_button(dateButton), shareDateLabel()) }
        if let preview { gtk_widget_queue_draw(preview) }
    }

    private func shareDateLabel() -> String {
        DateFormatter.localizedString(from: selectedDate, dateStyle: .medium, timeStyle: .none)
    }
}

private final class LinuxUsageShareRenderer {
    private let palette: [(Double, Double, Double)] = [
        (0.34, 0.80, 0.98), (0.56, 0.45, 0.98), (0.98, 0.53, 0.62),
        (0.31, 0.86, 0.65), (1.00, 0.72, 0.32), (0.42, 0.64, 0.98),
        (0.72, 0.76, 0.86),
    ]

    func writePNG(data: UsageShareData, to path: String) -> Bool {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1_200, 1_500) else { return false }
        defer { cairo_surface_destroy(surface) }
        guard let context = cairo_create(surface) else { return false }
        defer { cairo_destroy(context) }
        draw(context, width: 1_200, height: 1_500, data: data)
        cairo_surface_flush(surface)
        return path.withCString { cairo_surface_write_to_png(surface, $0) == CAIRO_STATUS_SUCCESS }
    }

    func draw(_ context: OpaquePointer, width: Double, height: Double, data: UsageShareData) {
        let scale = min(width / 600, height / 750)
        cairo_save(context)
        cairo_scale(context, scale, scale)
        let gradient = cairo_pattern_create_linear(0, 0, 600, 750)
        cairo_pattern_add_color_stop_rgb(gradient, 0, 0.035, 0.055, 0.12)
        cairo_pattern_add_color_stop_rgb(gradient, 0.55, 0.055, 0.11, 0.22)
        cairo_pattern_add_color_stop_rgb(gradient, 1, 0.10, 0.08, 0.22)
        cairo_set_source(context, gradient)
        cairo_rectangle(context, 0, 0, 600, 750)
        cairo_fill(context)
        cairo_pattern_destroy(gradient)

        circle(context, 515, 70, 180, color: (0.05, 0.42, 0.58, 0.23))
        circle(context, -45, 700, 190, color: (0.38, 0.14, 0.59, 0.25))
        circle(context, 57, 57, 19, color: (1, 1, 1, 0.08), stroke: (1, 1, 1, 0.25))
        text(context, "◷", size: 19, weight: 700, x: 57, y: 57, align: 1, alpha: 0.95)
        text(context, "TokenClock", size: 17, weight: 700, x: 86, y: 48, alpha: 1)
        text(context, L10n.shared.tr("share.dailyUsage"), size: 9, weight: 700, x: 86, y: 68, alpha: 0.52)
        text(context, displayDate(data.date), size: 13, weight: 600, x: 562, y: 50, align: 2, alpha: 0.72)

        text(context, TokenFormat.compact(data.totalTokens), size: 58, weight: 800, x: 38, y: 145, alpha: 1)
        text(context, L10n.shared.tr("share.tokens"), size: 10, weight: 700, x: 39, y: 188, alpha: 0.52)
        summaryCard(context, x: 38, title: L10n.shared.tr("share.messages"), value: number(data.messages), glyph: "●", tint: (0.75, 0.20, 0.86))
        summaryCard(context, x: 306, title: L10n.shared.tr("share.cache"), value: String(format: "%.2f%%", data.averageCacheRate * 100), glyph: "◆", tint: (1.0, 0.46, 0.12))

        text(context, L10n.shared.tr("share.toolBreakdown"), size: 10, weight: 700, x: 38, y: 320, alpha: 0.50)
        if data.rows.isEmpty {
            text(context, L10n.shared.tr("share.noUsage"), size: 13, weight: 500, x: 300, y: 450, align: 1, alpha: 0.58)
        } else {
            for (index, row) in data.rows.enumerated() {
                let y = 354.0 + Double(index) * 37
                text(context, "\(row.emoji)  \(row.name)", size: 12, weight: 600, x: 38, y: y, alpha: 0.86)
                text(context, TokenFormat.compact(row.tokens), size: 12, weight: 700, x: 562, y: y, align: 2, alpha: 1)
                roundedRect(context, x: 38, y: y + 14, width: 524, height: 5, radius: 2.5, fill: (1, 1, 1, 0.08))
                let color = palette[index % palette.count]
                roundedRect(context, x: 38, y: y + 14, width: max(3, 524 * row.fraction), height: 5, radius: 2.5, fill: (color.0, color.1, color.2, 1))
            }
        }

        roundedRect(context, x: 38, y: 618, width: 524, height: 72, radius: 16, fill: (1, 1, 1, 0.055), stroke: (1, 1, 1, 0.08))
        text(context, "“", size: 34, weight: 800, x: 54, y: 642, alpha: 0.80, color: (0.15, 0.72, 0.88))
        text(context, L10n.shared.tr(data.quoteKey), size: 13, weight: 500, x: 84, y: 654, alpha: 0.74)
        text(context, L10n.shared.tr("share.generatedBy"), size: 9, weight: 500, x: 38, y: 722, alpha: 0.40)
        text(context, "tokenclock", size: 9, weight: 600, x: 562, y: 722, align: 2, alpha: 0.40)
        cairo_restore(context)
    }

    private func summaryCard(
        _ context: OpaquePointer, x: Double, title: String, value: String,
        glyph: String, tint: (Double, Double, Double)
    ) {
        roundedRect(context, x: x, y: 216, width: 256, height: 64, radius: 15, fill: (1, 1, 1, 0.065), stroke: (1, 1, 1, 0.11))
        circle(context, x + 28, 248, 14, color: (tint.0, tint.1, tint.2, 0.18))
        text(context, glyph, size: 13, weight: 700, x: x + 28, y: 248, align: 1, alpha: 1, color: tint)
        text(context, value, size: 17, weight: 700, x: x + 52, y: 239, alpha: 1)
        text(context, title, size: 8, weight: 700, x: x + 52, y: 259, alpha: 0.45)
    }

    private func displayDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)
    }

    private func number(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func text(
        _ context: OpaquePointer, _ value: String, size: Double, weight: Int,
        x: Double, y: Double, align: Int = 0, alpha: Double,
        color: (Double, Double, Double) = (1, 1, 1)
    ) {
        value.withCString { valuePtr in
            "Sans".withCString { familyPtr in
                tc_cairo_draw_text(context, valuePtr, familyPtr, size, gint(weight), x, y, gint(align), color.0, color.1, color.2, alpha)
            }
        }
    }

    private func circle(
        _ context: OpaquePointer, _ x: Double, _ y: Double, _ radius: Double,
        color: (Double, Double, Double, Double),
        stroke: (Double, Double, Double, Double)? = nil
    ) {
        cairo_arc(context, x, y, radius, 0, Double.pi * 2)
        cairo_set_source_rgba(context, color.0, color.1, color.2, color.3)
        cairo_fill_preserve(context)
        if let stroke {
            cairo_set_source_rgba(context, stroke.0, stroke.1, stroke.2, stroke.3)
            cairo_set_line_width(context, 1)
            cairo_stroke(context)
        } else { cairo_new_path(context) }
    }

    private func roundedRect(
        _ context: OpaquePointer, x: Double, y: Double, width: Double, height: Double,
        radius: Double, fill: (Double, Double, Double, Double),
        stroke: (Double, Double, Double, Double)? = nil
    ) {
        let r = min(radius, min(width, height) / 2)
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - r, y + r, r, -.pi / 2, 0)
        cairo_arc(context, x + width - r, y + height - r, r, 0, .pi / 2)
        cairo_arc(context, x + r, y + height - r, r, .pi / 2, .pi)
        cairo_arc(context, x + r, y + r, r, .pi, .pi * 1.5)
        cairo_close_path(context)
        cairo_set_source_rgba(context, fill.0, fill.1, fill.2, fill.3)
        cairo_fill_preserve(context)
        if let stroke {
            cairo_set_source_rgba(context, stroke.0, stroke.1, stroke.2, stroke.3)
            cairo_set_line_width(context, 1)
            cairo_stroke(context)
        } else { cairo_new_path(context) }
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
