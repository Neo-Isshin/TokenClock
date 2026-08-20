import Foundation
import CGtk

/// GTK visual counterpart of macOS's clock-face picker popover.
final class LinuxThemePicker: @unchecked Sendable {
    private let renderer = LinuxClockRenderer()
    private weak var parentOwner: LinuxApp?
    private var parent: UnsafeMutablePointer<GtkWidget>?
    private var selected: LinuxClockTheme = .classic
    private var buttons: [LinuxClockTheme: UnsafeMutablePointer<GtkWidget>] = [:]
    private var labels: [LinuxClockTheme: UnsafeMutablePointer<GtkWidget>] = [:]
    private var previewAreas: [LinuxClockTheme: UnsafeMutablePointer<GtkWidget>] = [:]
    private var titleLabel: UnsafeMutablePointer<GtkWidget>?

    private(set) var window: UnsafeMutablePointer<GtkWidget>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, owner: LinuxApp) {
        self.parent = parent
        parentOwner = owner
        buildWindow(parent: parent)
    }

    func show(selected: LinuxClockTheme) {
        self.selected = selected
        updateSelection()
        guard let window else { return }
        gtk_window_set_position(tc_gtk_window(window), GTK_WIN_POS_CENTER_ON_PARENT)
        gtk_widget_show_all(window)
        gtk_window_present(tc_gtk_window(window))
    }

    func hide() {
        if let window { gtk_widget_hide(window) }
    }

    func refreshLanguage() {
        if let window { gtk_window_set_title(tc_gtk_window(window), L10n.shared.tr("menu.clockFace")) }
        if let titleLabel { gtk_label_set_text(tc_gtk_label(titleLabel), L10n.shared.tr("menu.clockFace")) }
        updateSelection()
    }

    fileprivate func draw(widget: UnsafeMutablePointer<GtkWidget>, context: OpaquePointer) {
        let name = String(cString: tc_gtk_widget_name(widget))
        guard name.hasPrefix("theme-preview:"),
              let theme = LinuxClockTheme(rawValue: String(name.dropFirst("theme-preview:".count))) else {
            return
        }
        renderer.drawPreview(
            context,
            width: Double(gtk_widget_get_allocated_width(widget)),
            height: Double(gtk_widget_get_allocated_height(widget)),
            theme: theme
        )
    }

    fileprivate func activate(widget: UnsafeMutablePointer<GtkWidget>) {
        let name = String(cString: tc_gtk_widget_name(widget))
        guard name.hasPrefix("theme-select:"),
              let theme = LinuxClockTheme(rawValue: String(name.dropFirst("theme-select:".count))) else {
            return
        }
        selected = theme
        updateSelection()
        parentOwner?.chooseThemeFromPicker(theme)
        hide()
    }

    private func buildWindow(parent: UnsafeMutablePointer<GtkWidget>) {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10) else { return }
        window = createdWindow
        gtk_window_set_title(tc_gtk_window(createdWindow), L10n.shared.tr("menu.clockFace"))
        gtk_window_set_default_size(tc_gtk_window(createdWindow), 440, 280)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_transient_for(tc_gtk_window(createdWindow), tc_gtk_window(parent))
        gtk_window_set_skip_taskbar_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_skip_pager_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_keep_above(tc_gtk_window(createdWindow), 1)
        gtk_container_set_border_width(tc_gtk_container(root), 14)
        gtk_container_add(tc_gtk_container(createdWindow), root)

        let title = gtk_label_new(L10n.shared.tr("menu.clockFace"))
        titleLabel = title
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        tc_gtk_add_class(title, "tokenclock-picker-title")
        gtk_box_pack_start(tc_gtk_box(root), title, 0, 0, 0)

        for rowIndex in 0..<2 {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
            gtk_box_pack_start(tc_gtk_box(root), row, 1, 1, 0)
            for column in 0..<4 {
                let index = rowIndex * 4 + column
                let theme = LinuxClockTheme.builtInCases[index]
                appendTheme(theme, to: row)
            }
        }

        tc_gtk_apply_css("""
        .tokenclock-theme-tile {
            background: rgba(120, 120, 120, 0.06);
            border: 1px solid rgba(120, 120, 120, 0.20);
            border-radius: 12px;
            padding: 6px;
        }
        .tokenclock-theme-tile:hover {
            background: rgba(73, 132, 255, 0.12);
            border-color: rgba(73, 132, 255, 0.55);
        }
        .tokenclock-theme-selected {
            background: rgba(73, 132, 255, 0.20);
            border: 2px solid rgba(73, 132, 255, 0.95);
        }
        .tokenclock-picker-title { font-size: 16px; font-weight: 700; }
        """)
        _ = tc_gtk_on_destroy(createdWindow, linuxThemePickerDestroyed, opaque)
    }

    private func appendTheme(
        _ theme: LinuxClockTheme,
        to row: UnsafeMutablePointer<GtkWidget>?
    ) {
        guard let button = gtk_button_new(),
              let stack = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4),
              let preview = gtk_drawing_area_new(),
              let label = gtk_label_new(theme.displayName) else { return }
        gtk_widget_set_name(button, "theme-select:\(theme.rawValue)")
        gtk_widget_set_name(preview, "theme-preview:\(theme.rawValue)")
        tc_gtk_add_class(button, "tokenclock-theme-tile")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        gtk_widget_set_size_request(button, 94, 105)
        gtk_widget_set_size_request(preview, 76, 76)
        gtk_container_add(tc_gtk_container(button), stack)
        gtk_box_pack_start(tc_gtk_box(stack), preview, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(stack), label, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(row), button, 1, 1, 0)
        _ = tc_gtk_on_draw(preview, linuxThemePreviewDraw, opaque)
        _ = tc_gtk_on_clicked(button, linuxThemePickerAction, opaque)
        buttons[theme] = button
        labels[theme] = label
        previewAreas[theme] = preview
    }

    private func updateSelection() {
        for theme in LinuxClockTheme.builtInCases {
            guard let button = buttons[theme], let label = labels[theme] else { continue }
            if theme == selected {
                tc_gtk_add_class(button, "tokenclock-theme-selected")
                gtk_label_set_text(tc_gtk_label(label), "✓ \(theme.displayName)")
            } else {
                tc_gtk_remove_class(button, "tokenclock-theme-selected")
                gtk_label_set_text(tc_gtk_label(label), theme.displayName)
            }
            if let preview = previewAreas[theme] { gtk_widget_queue_draw(preview) }
        }
    }
}

private func picker(from data: gpointer?) -> LinuxThemePicker? {
    guard let data else { return nil }
    return Unmanaged<LinuxThemePicker>.fromOpaque(data).takeUnretainedValue()
}

private func linuxThemePreviewDraw(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ context: OpaquePointer?,
    _ data: gpointer?
) -> gboolean {
    guard let widget, let context else { return 0 }
    picker(from: data)?.draw(widget: widget, context: context)
    return 0
}

private func linuxThemePickerAction(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ data: gpointer?
) {
    guard let widget else { return }
    picker(from: data)?.activate(widget: widget)
}

private func linuxThemePickerDestroyed(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ data: gpointer?
) {
    picker(from: data)?.hide()
}
