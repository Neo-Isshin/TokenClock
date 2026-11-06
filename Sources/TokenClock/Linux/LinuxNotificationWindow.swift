import CGtk
import Foundation

/// Small native GTK notification list used by the Linux shell. Report rows carry the
/// same UsageOverviewRoute as macOS, so opening a report preserves its exact date range.
final class LinuxNotificationWindow: @unchecked Sendable {
  private let parent: UnsafeMutablePointer<GtkWidget>
  private var window: UnsafeMutablePointer<GtkWidget>?
  private var root: UnsafeMutablePointer<GtkWidget>?
  private var routes: [String: UsageOverviewRoute] = [:]
  private let onOpen: (UsageOverviewRoute) -> Void
  private let onBilling: (String) -> Void
  var onNews: ((String) -> Void)?
  var onNotebook: ((UUID) -> Void)?
  var onRead: (([TokenClockNotification]) -> Void)?
  private var allNotices: [TokenClockNotification] = []
  private var filter = NotificationPanelFilter.all
  private var newsRoutes: [String: String] = [:]
  private var notebookRoutes: [String: UUID] = [:]
  private var billingRoutes: [String: String] = [:]
  private var releaseRoutes: [String: URL] = [:]
  private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

  init(
    parent: UnsafeMutablePointer<GtkWidget>, onBilling: @escaping (String) -> Void = { _ in },
    onOpen: @escaping (UsageOverviewRoute) -> Void
  ) {
    self.parent = parent
    self.onOpen = onOpen
    self.onBilling = onBilling
    buildWindow()
  }

  func show(_ notifications: [TokenClockNotification]) {
    allNotices = notifications
    filter = notifications.contains { $0.kind == .news && !$0.isRead } ? .news : .all
    render()
  }
  private func render() {
    let notifications = allNotices.filter { filter.includes($0) }
    guard let window, let root else { return }
    routes.removeAll()
    billingRoutes.removeAll()
    releaseRoutes.removeAll()
    newsRoutes.removeAll()
    notebookRoutes.removeAll()
    tc_gtk_remove_all_children(root)
    if let picker = gtk_combo_box_text_new() {
      for value in NotificationPanelFilter.allCases {
        gtk_combo_box_text_append(tc_gtk_combo_box_text(picker), value.rawValue, value.title)
      }
      gtk_combo_box_set_active_id(tc_gtk_combo_box(picker), filter.rawValue)
      _ = tc_gtk_on_changed(picker, linuxNotificationFilterChanged, opaque)
      gtk_box_pack_start(tc_gtk_box(root), picker, 0, 0, 0)
    }
    let actionable = notifications
    if actionable.isEmpty {
      let empty = gtk_label_new(L10n.shared.tr("notification.empty"))
      gtk_widget_set_margin_top(empty, 20)
      gtk_widget_set_margin_bottom(empty, 20)
      gtk_box_pack_start(tc_gtk_box(root), empty, 0, 0, 0)
    } else {
      for notification in actionable {
        guard let button = gtk_button_new_with_label(rowText(notification)) else { continue }
        let id = notification.id.uuidString
        routes[id] = notification.route
        billingRoutes[id] = notification.subscriptionAccountID
        releaseRoutes[id] = notification.releaseURL
        newsRoutes[id] = notification.newsItemID
        notebookRoutes[id] = notification.notebookEntryID
        gtk_widget_set_name(button, "notification:\(id)")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        gtk_widget_set_tooltip_text(button, notification.message)
        _ = tc_gtk_on_clicked(button, linuxNotificationAction, opaque)
        gtk_box_pack_start(tc_gtk_box(root), button, 0, 0, 4)
      }
    }
    gtk_widget_show_all(window)
    gtk_window_present(tc_gtk_window(window))
    onRead?(notifications)
  }
  fileprivate func changeFilter(_ widget: UnsafeMutablePointer<GtkWidget>) {
    if let raw = gtk_combo_box_get_active_id(tc_gtk_combo_box(widget)),
      let value = NotificationPanelFilter(rawValue: String(cString: raw))
    {
      filter = value
      render()
    }
  }

  func hide() {
    if let window { gtk_widget_hide(window) }
  }

  fileprivate func handleAction(widget: UnsafeMutablePointer<GtkWidget>) {
    let name = String(cString: tc_gtk_widget_name(widget))
    if name.hasPrefix("notification:"),
      let id = newsRoutes[String(name.dropFirst("notification:".count))]
    {
      hide()
      onNews?(id)
      return
    }
    if name.hasPrefix("notification:"),
      let id = notebookRoutes[String(name.dropFirst("notification:".count))]
    {
      hide()
      onNotebook?(id)
      return
    }
    if name.hasPrefix("notification:"),
      let url = releaseRoutes[String(name.dropFirst("notification:".count))]
    {
      gtk_show_uri_on_window(tc_gtk_window(parent), url.absoluteString, 0, nil)
      hide()
      return
    }
    if name.hasPrefix("notification:"),
      let account = billingRoutes[String(name.dropFirst("notification:".count))]
    {
      hide()
      onBilling(account)
      return
    }
    guard name.hasPrefix("notification:"),
      let route = routes[String(name.dropFirst("notification:".count))]
    else { return }
    onOpen(route)
  }

  private func buildWindow() {
    guard let created = gtk_window_new(GTK_WINDOW_TOPLEVEL),
      let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
    else { return }
    window = created
    root = box
    gtk_window_set_title(tc_gtk_window(created), L10n.shared.tr("notification.title"))
    gtk_window_set_default_size(tc_gtk_window(created), 360, 280)
    gtk_window_set_resizable(tc_gtk_window(created), 1)
    gtk_window_set_transient_for(tc_gtk_window(created), tc_gtk_window(parent))
    gtk_window_set_keep_above(tc_gtk_window(created), 1)
    gtk_container_set_border_width(tc_gtk_container(box), 14)
    if let scroll = gtk_scrolled_window_new(nil, nil) {
      gtk_scrolled_window_set_policy(
        tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      gtk_container_add(tc_gtk_container(scroll), box)
      gtk_container_add(tc_gtk_container(created), scroll)
    } else {
      gtk_container_add(tc_gtk_container(created), box)
    }
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
    case .releaseUpdate: icon = "⬆️"
    case .news: icon = "📰"
    case .notebookReminder: icon = "📝"
    }
    return "\(icon)  \(notification.title)\n\(notification.message)  ›"
  }
}

private let linuxNotificationAction:
  @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { widget, data in
    guard let widget, let data else { return }
    Unmanaged<LinuxNotificationWindow>.fromOpaque(data).takeUnretainedValue().handleAction(
      widget: widget)
  }

private let linuxNotificationFilterChanged:
  @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { widget, data in
    guard let widget, let data else { return }
    Unmanaged<LinuxNotificationWindow>.fromOpaque(data).takeUnretainedValue().changeFilter(widget)
  }
