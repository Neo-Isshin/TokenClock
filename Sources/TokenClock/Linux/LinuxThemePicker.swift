import Foundation
import CGtk

/// Compact 3-column clock-face picker matching macOS normal's visual model.
final class LinuxThemePicker: @unchecked Sendable {
    private let renderer = LinuxClockRenderer()
    private weak var parentOwner: LinuxApp?
    private var selected: LinuxClockTheme = .classic
    private var root: UnsafeMutablePointer<GtkWidget>?
    private var buttons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var labels: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var displayNames: [String: String] = [:]
    private var savedPreviewConfigs: [UUID: LinuxCustomThemeConfig] = [:]

    private(set) var window: UnsafeMutablePointer<GtkWidget>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, owner: LinuxApp) {
        parentOwner = owner
        buildWindow(parent: parent)
    }

    func show(selected: LinuxClockTheme) {
        self.selected = selected
        rebuildContents()
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
        rebuildContents()
    }

    fileprivate func draw(widget: UnsafeMutablePointer<GtkWidget>, context: OpaquePointer) {
        let name = String(cString: tc_gtk_widget_name(widget))
        let theme: LinuxClockTheme
        if name.hasPrefix("theme-preview:"),
           let value = LinuxClockTheme(rawValue: String(name.dropFirst("theme-preview:".count))) {
            theme = value
        } else if name.hasPrefix("saved-preview:"),
                  let id = UUID(uuidString: String(name.dropFirst("saved-preview:".count))),
                  let config = savedPreviewConfigs[id] {
            renderer.drawPreview(
                context,
                width: Double(gtk_widget_get_allocated_width(widget)),
                height: Double(gtk_widget_get_allocated_height(widget)),
                customConfig: config
            )
            return
        } else {
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
        if name.hasPrefix("theme-select:"),
           let theme = LinuxClockTheme(rawValue: String(name.dropFirst("theme-select:".count))) {
            selected = theme
            parentOwner?.chooseThemeFromPicker(theme)
            hide()
            return
        }
        if name.hasPrefix("saved-select:"),
           let id = UUID(uuidString: String(name.dropFirst("saved-select:".count))) {
            selected = .custom
            parentOwner?.applyCustomTheme(id: id)
            hide()
        }
    }

    private func buildWindow(parent: UnsafeMutablePointer<GtkWidget>) {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let createdRoot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10) else { return }
        window = createdWindow
        root = createdRoot
        gtk_window_set_title(tc_gtk_window(createdWindow), L10n.shared.tr("menu.clockFace"))
        gtk_window_set_default_size(tc_gtk_window(createdWindow), 300, 434)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_transient_for(tc_gtk_window(createdWindow), tc_gtk_window(parent))
        gtk_window_set_skip_taskbar_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_skip_pager_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_keep_above(tc_gtk_window(createdWindow), 1)
        gtk_container_set_border_width(tc_gtk_container(createdRoot), 12)
        gtk_container_add(tc_gtk_container(createdWindow), createdRoot)
        _ = tc_gtk_hide_on_delete(createdWindow)

        tc_gtk_apply_css("""
        .tokenclock-theme-tile {
            background: rgba(120, 120, 120, 0.06);
            border: 1px solid rgba(120, 120, 120, 0.20);
            border-radius: 12px;
            padding: 4px;
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
        rebuildContents()
    }

    private func rebuildContents() {
        guard let root else { return }
        tc_gtk_remove_all_children(root)
        buttons.removeAll()
        labels.removeAll()
        displayNames.removeAll()
        savedPreviewConfigs.removeAll()

        let title = gtk_label_new(L10n.shared.tr("menu.clockFace"))
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        tc_gtk_add_class(title, "tokenclock-picker-title")
        gtk_box_pack_start(tc_gtk_box(root), title, 0, 0, 0)

        guard let scroll = gtk_scrolled_window_new(nil, nil),
              let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8) else { return }
        gtk_scrolled_window_set_policy(
            tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC
        )
        gtk_container_add(tc_gtk_container(scroll), list)
        gtk_box_pack_start(tc_gtk_box(root), scroll, 1, 1, 0)

        var tiles: [(key: String, title: String, theme: LinuxClockTheme, savedID: UUID?)] =
            LinuxClockTheme.allCases.map {
                ("theme:\($0.rawValue)", $0.displayName, $0, nil)
            }
        let savedThemes = LinuxCustomThemeStore.shared.themes
        tiles += savedThemes.map {
            savedPreviewConfigs[$0.id] = $0.config
            return ("saved:\($0.id.uuidString)", $0.name, .custom, $0.id)
        }

        for rowStart in stride(from: 0, to: tiles.count, by: 3) {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 7)
            gtk_box_pack_start(tc_gtk_box(list), row, 0, 0, 0)
            for column in 0..<3 {
                let index = rowStart + column
                if index < tiles.count {
                    appendTile(tiles[index], to: row)
                } else {
                    let spacer = gtk_label_new("")
                    gtk_widget_set_size_request(spacer, 84, 1)
                    gtk_box_pack_start(tc_gtk_box(row), spacer, 1, 1, 0)
                }
            }
        }
    }

    private func appendTile(
        _ tile: (key: String, title: String, theme: LinuxClockTheme, savedID: UUID?),
        to row: UnsafeMutablePointer<GtkWidget>?
    ) {
        guard let button = gtk_button_new(),
              let stack = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3),
              let preview = gtk_drawing_area_new(),
              let label = gtk_label_new(tile.title) else { return }
        if let savedID = tile.savedID {
            gtk_widget_set_name(button, "saved-select:\(savedID.uuidString)")
            gtk_widget_set_name(preview, "saved-preview:\(savedID.uuidString)")
        } else {
            gtk_widget_set_name(button, "theme-select:\(tile.theme.rawValue)")
            gtk_widget_set_name(preview, "theme-preview:\(tile.theme.rawValue)")
        }
        tc_gtk_add_class(button, "tokenclock-theme-tile")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        gtk_widget_set_size_request(button, 84, 103)
        gtk_widget_set_size_request(preview, 66, 66)
        gtk_label_set_ellipsize(tc_gtk_label(label), PANGO_ELLIPSIZE_END)
        gtk_container_add(tc_gtk_container(button), stack)
        gtk_box_pack_start(tc_gtk_box(stack), preview, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(stack), label, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(row), button, 1, 1, 0)
        _ = tc_gtk_on_draw(preview, linuxThemePreviewDraw, opaque)
        _ = tc_gtk_on_clicked(button, linuxThemePickerAction, opaque)
        buttons[tile.key] = button
        labels[tile.key] = label
        displayNames[tile.key] = tile.title
    }

    private func updateSelection() {
        let activeID = UserDefaults.standard.string(for: .activeCustomThemeId)
        let selectedKey: String
        if selected == .custom, let activeID {
            selectedKey = "saved:\(activeID)"
        } else {
            selectedKey = "theme:\(selected.rawValue)"
        }
        for (key, button) in buttons {
            guard let label = labels[key], let title = displayNames[key] else { continue }
            if key == selectedKey {
                tc_gtk_add_class(button, "tokenclock-theme-selected")
                gtk_label_set_text(tc_gtk_label(label), "✓ \(title)")
            } else {
                tc_gtk_remove_class(button, "tokenclock-theme-selected")
                gtk_label_set_text(tc_gtk_label(label), title)
            }
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
