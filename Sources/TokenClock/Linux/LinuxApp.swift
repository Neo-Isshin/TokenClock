import Foundation
import CGtk

final class LinuxApp: @unchecked Sendable {
    private let model = LinuxUsageModel()
    private var apiServer: LinuxAPIServer?

    private var window: UnsafeMutablePointer<GtkWidget>?
    private var dial: UnsafeMutablePointer<GtkWidget>?
    private var summaryLabel: UnsafeMutablePointer<GtkWidget>?
    private var detailsLabel: UnsafeMutablePointer<GtkWidget>?
    private var detailsVisible = false

    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    func run() {
        gtk_init(nil, nil)
        buildInterface()
        apiServer = LinuxAPIServer(model: model)
        apiServer?.start()
        scheduleScan(incremental: false)

        _ = tc_gtk_timeout_add(1_000, linuxClockTick, opaque)
        _ = tc_gtk_timeout_add_seconds(
            guint(max(1, Int(AppConfig.Timers.dataScan))),
            linuxScanTick,
            opaque
        )
        gtk_main()
    }

    private func buildInterface() {
        let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        window = createdWindow
        gtk_window_set_title(tc_gtk_window(createdWindow), "TokenClock")
        gtk_window_set_default_size(tc_gtk_window(createdWindow), 360, 430)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_decorated(tc_gtk_window(createdWindow), 0)
        gtk_window_set_keep_above(tc_gtk_window(createdWindow), 1)
        gtk_window_set_skip_taskbar_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_position(tc_gtk_window(createdWindow), GTK_WIN_POS_CENTER)
        gtk_widget_add_events(createdWindow, gint(GDK_BUTTON_PRESS_MASK.rawValue))
        tc_gtk_add_class(createdWindow, "tokenclock-window")

        if UserDefaults.standard.object(forKey: "TCLinuxWindowX") != nil {
            let x = UserDefaults.standard.integer(forKey: "TCLinuxWindowX")
            let y = UserDefaults.standard.integer(forKey: "TCLinuxWindowY")
            gtk_window_move(tc_gtk_window(createdWindow), gint(x), gint(y))
        }

        let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
        gtk_container_set_border_width(tc_gtk_container(root), 14)
        gtk_container_add(tc_gtk_container(createdWindow), root)

        let createdDial = gtk_drawing_area_new()
        dial = createdDial
        gtk_widget_set_size_request(createdDial, 324, 324)
        gtk_box_pack_start(tc_gtk_box(root), createdDial, 1, 1, 0)
        gtk_widget_add_events(createdDial, gint(GDK_BUTTON_PRESS_MASK.rawValue))

        let createdSummary = gtk_label_new("Scanning local usage…")
        summaryLabel = createdSummary
        tc_gtk_add_class(createdSummary, "summary")
        gtk_box_pack_start(tc_gtk_box(root), createdSummary, 0, 0, 0)

        let createdDetails = gtk_label_new("")
        detailsLabel = createdDetails
        tc_gtk_add_class(createdDetails, "details")
        gtk_label_set_xalign(tc_gtk_label(createdDetails), 0)
        gtk_label_set_selectable(tc_gtk_label(createdDetails), 1)
        gtk_box_pack_start(tc_gtk_box(root), createdDetails, 0, 0, 0)

        let controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_box_set_homogeneous(tc_gtk_box(controls), 1)
        let refreshButton = gtk_button_new_with_label("Refresh")
        let detailsButton = gtk_button_new_with_label("Details")
        let quitButton = gtk_button_new_with_label("Quit")
        gtk_box_pack_start(tc_gtk_box(controls), refreshButton, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(controls), detailsButton, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(controls), quitButton, 1, 1, 0)
        gtk_box_pack_end(tc_gtk_box(root), controls, 0, 0, 0)

        _ = tc_gtk_on_destroy(createdWindow, linuxDestroy, opaque)
        _ = tc_gtk_on_button_press(createdDial, linuxButtonPress, opaque)
        _ = tc_gtk_on_draw(createdDial, linuxDraw, opaque)
        _ = tc_gtk_on_clicked(refreshButton, linuxRefresh, opaque)
        _ = tc_gtk_on_clicked(detailsButton, linuxToggleDetails, opaque)
        _ = tc_gtk_on_clicked(quitButton, linuxQuit, opaque)

        tc_gtk_apply_css(
            """
            .tokenclock-window {
              background: #f4f1ea;
              border: 2px solid #69645b;
              border-radius: 22px;
            }
            .summary {
              color: #292722;
              font: 600 15px Sans;
              padding: 2px 6px;
            }
            .details {
              color: #39362f;
              background: #e7e1d6;
              border-radius: 10px;
              font: 13px Monospace;
              padding: 10px;
            }
            button {
              color: #292722;
              background: #ded6c8;
              border: 1px solid #8c8476;
              border-radius: 8px;
              padding: 6px;
            }
            button:hover { background: #d0c6b6; }
            """
        )

        gtk_widget_show_all(createdWindow)
        gtk_widget_hide(createdDetails)
        refreshUI()
    }

    fileprivate func scheduleScan(incremental: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard self.model.scan(incremental: incremental) else { return }
            _ = tc_gtk_idle_add(linuxScanFinished, self.opaque)
        }
    }

    fileprivate func refreshUI() {
        guard let summaryLabel, let detailsLabel, let dial else { return }
        let tools = model.tools
        let tokens = UsageAggregator.totalTokens(tools)
        let messages = UsageAggregator.totalMessages(tools)
        let active = tools.filter { $0.isActive || $0.todayTokens > 0 }
        let rate = UsageAggregator.rateEmoji(tools)

        gtk_label_set_text(
            tc_gtk_label(summaryLabel),
            "Today  \(TokenFormat.compact(tokens)) tokens  ·  \(messages) messages  \(rate)"
        )

        let detailText: String
        if active.isEmpty {
            detailText = "No local AI usage found today."
        } else {
            detailText = active.prefix(10).map {
                let marker = $0.isActive ? "●" : " "
                return "\(marker) \($0.emoji) \($0.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \($0.formattedTokens)"
            }.joined(separator: "\n")
        }
        gtk_label_set_text(tc_gtk_label(detailsLabel), detailText)
        gtk_widget_queue_draw(dial)
    }

    fileprivate func toggleDetails() {
        guard let detailsLabel, let window else { return }
        detailsVisible.toggle()
        if detailsVisible {
            gtk_widget_show(detailsLabel)
            gtk_window_resize(tc_gtk_window(window), 360, 590)
        } else {
            gtk_widget_hide(detailsLabel)
            gtk_window_resize(tc_gtk_window(window), 360, 430)
        }
    }

    fileprivate func beginMove(event: UnsafeMutablePointer<GdkEventButton>) {
        guard let window else { return }
        tc_gtk_begin_move(window, event)
    }

    fileprivate func draw(_ context: OpaquePointer) {
        guard let dial else { return }
        let width = Double(gtk_widget_get_allocated_width(dial))
        let height = Double(gtk_widget_get_allocated_height(dial))
        let centerX = width / 2
        let centerY = height / 2
        let radius = min(width, height) / 2 - 10

        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_arc(context, centerX, centerY, radius, 0, Double.pi * 2)
        tc_cairo_set_source_rgba(context, 0.91, 0.88, 0.81, 1)
        cairo_fill_preserve(context)
        tc_cairo_set_source_rgba(context, 0.25, 0.24, 0.21, 1)
        cairo_set_line_width(context, 3)
        cairo_stroke(context)

        for tick in 0..<60 {
            let angle = Double(tick) * Double.pi / 30 - Double.pi / 2
            let isHour = tick % 5 == 0
            let inner = radius - (isHour ? 18 : 10)
            cairo_move_to(context, centerX + cos(angle) * inner, centerY + sin(angle) * inner)
            cairo_line_to(context, centerX + cos(angle) * (radius - 4), centerY + sin(angle) * (radius - 4))
            cairo_set_line_width(context, isHour ? 3 : 1)
            cairo_stroke(context)
        }

        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let second = Double(components.second ?? 0)
        let minute = Double(components.minute ?? 0) + second / 60
        let hour = Double((components.hour ?? 0) % 12) + minute / 60
        drawHand(context, centerX, centerY, angle: hour * Double.pi / 6 - Double.pi / 2, length: radius * 0.50, width: 6, red: 0.12, green: 0.12, blue: 0.11)
        drawHand(context, centerX, centerY, angle: minute * Double.pi / 30 - Double.pi / 2, length: radius * 0.72, width: 4, red: 0.12, green: 0.12, blue: 0.11)
        drawHand(context, centerX, centerY, angle: second * Double.pi / 30 - Double.pi / 2, length: radius * 0.78, width: 2, red: 0.78, green: 0.20, blue: 0.12)

        cairo_arc(context, centerX, centerY, 6, 0, Double.pi * 2)
        tc_cairo_set_source_rgba(context, 0.18, 0.17, 0.15, 1)
        cairo_fill(context)

        let total = TokenFormat.compact(UsageAggregator.totalTokens(model.tools))
        cairo_select_font_face(context, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(context, 20)
        tc_cairo_set_source_rgba(context, 0.20, 0.19, 0.17, 0.92)
        cairo_move_to(context, centerX - Double(total.count) * 6, centerY + radius * 0.52)
        cairo_show_text(context, total)
    }

    private func drawHand(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        angle: Double,
        length: Double,
        width: Double,
        red: Double,
        green: Double,
        blue: Double
    ) {
        cairo_move_to(context, centerX, centerY)
        cairo_line_to(context, centerX + cos(angle) * length, centerY + sin(angle) * length)
        tc_cairo_set_source_rgba(context, red, green, blue, 1)
        cairo_set_line_width(context, width)
        cairo_stroke(context)
    }

    fileprivate func shutdown() {
        if let window {
            var x: gint = 0
            var y: gint = 0
            gtk_window_get_position(tc_gtk_window(window), &x, &y)
            UserDefaults.standard.set(Int(x), forKey: "TCLinuxWindowX")
            UserDefaults.standard.set(Int(y), forKey: "TCLinuxWindowY")
        }
        apiServer?.stop()
    }
}

private func app(from data: gpointer?) -> LinuxApp? {
    guard let data else { return nil }
    return Unmanaged<LinuxApp>.fromOpaque(data).takeUnretainedValue()
}

private func linuxDestroy(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    app(from: data)?.shutdown()
    gtk_main_quit()
}

private func linuxQuit(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    app(from: data)?.shutdown()
    gtk_main_quit()
}

private func linuxRefresh(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    app(from: data)?.scheduleScan(incremental: true)
}

private func linuxToggleDetails(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    app(from: data)?.toggleDetails()
}

private func linuxButtonPress(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ event: UnsafeMutablePointer<GdkEventButton>?,
    _ data: gpointer?
) -> gboolean {
    guard let event else { return 0 }
    if tc_gtk_event_button(event) == 1 {
        app(from: data)?.beginMove(event: event)
        return 1
    }
    if tc_gtk_event_button(event) == 3 {
        app(from: data)?.toggleDetails()
        return 1
    }
    return 0
}

private func linuxDraw(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ context: OpaquePointer?,
    _ data: gpointer?
) -> gboolean {
    guard let context else { return 0 }
    app(from: data)?.draw(context)
    return 0
}

private func linuxClockTick(_ data: gpointer?) -> gboolean {
    if let app = app(from: data) {
        app.refreshUI()
        return 1
    }
    return 0
}

private func linuxScanTick(_ data: gpointer?) -> gboolean {
    if let app = app(from: data) {
        app.scheduleScan(incremental: true)
        return 1
    }
    return 0
}

private func linuxScanFinished(_ data: gpointer?) -> gboolean {
    app(from: data)?.refreshUI()
    return 0
}
