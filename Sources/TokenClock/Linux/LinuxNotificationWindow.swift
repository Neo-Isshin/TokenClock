import Foundation
import CGtk

/// Small native GTK notification list used by the Linux shell. Report rows carry the
/// same UsageOverviewRoute as macOS, so opening a report preserves its exact date range.
final class LinuxNotificationWindow: @unchecked Sendable {
    private let parent: UnsafeMutablePointer<GtkWidget>
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var root: UnsafeMutablePointer<GtkWidget>?
    private var routes: [String: UsageOverviewRoute] = [:]
    private let onOpen: (UsageOverviewRoute) -> Void
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, onOpen: @escaping (UsageOverviewRoute) -> Void) {
        self.parent = parent
        self.onOpen = onOpen
        buildWindow()
    }

    func show(_ notifications: [TokenClockNotification]) {
        guard let window, let root else { return }
        routes.removeAll()
        tc_gtk_remove_all_children(root)
        let actionable = notifications.filter { $0.route != nil }
        if actionable.isEmpty {
            let empty = gtk_label_new(L10n.shared.tr("notification.empty"))
            gtk_widget_set_margin_top(empty, 20)
            gtk_widget_set_margin_bottom(empty, 20)
            gtk_box_pack_start(tc_gtk_box(root), empty, 0, 0, 0)
        } else {
            for notification in actionable {
                guard let route = notification.route,
                      let button = gtk_button_new_with_label(rowText(notification)) else { continue }
                let id = notification.id.uuidString
                routes[id] = route
                gtk_widget_set_name(button, "notification:\(id)")
                gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
                gtk_widget_set_tooltip_text(button, notification.message)
                _ = tc_gtk_on_clicked(button, linuxNotificationAction, opaque)
                gtk_box_pack_start(tc_gtk_box(root), button, 0, 0, 4)
            }
        }
        gtk_widget_show_all(window)
        gtk_window_present(tc_gtk_window(window))
    }

    func hide() {
        if let window { gtk_widget_hide(window) }
    }

    fileprivate func handleAction(widget: UnsafeMutablePointer<GtkWidget>) {
        let name = String(cString: tc_gtk_widget_name(widget))
        guard name.hasPrefix("notification:"),
              let route = routes[String(name.dropFirst("notification:".count))] else { return }
        onOpen(route)
    }

    private func buildWindow() {
        guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8) else { return }
        window = created
        root = box
        gtk_window_set_title(tc_gtk_window(created), L10n.shared.tr("notification.title"))
        gtk_window_set_default_size(tc_gtk_window(created), 360, 280)
        gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent))
        gtk_window_set_keep_above(tc_gtk_window(created), 1)
        gtk_container_set_border_width(tc_gtk_container(box), 14)
        gtk_container_add(tc_gtk_container(created), box)
        _ = tc_gtk_hide_on_delete(created)
    }

    private func rowText(_ notification: TokenClockNotification) -> String {
        let icon: String
        switch notification.kind {
        case .dailyReport: icon = "📄"
        case .weeklyReport: icon = "🗓️"
        case .monthlyReport: icon = "📅"
        case .modelDetection: icon = "✨"
        case .system: icon = "ⓘ"
        }
        return "\(icon)  \(notification.title)\n\(notification.message)  ›"
    }
}

private let linuxNotificationAction: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { widget, data in
    guard let widget, let data else { return }
    Unmanaged<LinuxNotificationWindow>.fromOpaque(data).takeUnretainedValue().handleAction(widget: widget)
}
