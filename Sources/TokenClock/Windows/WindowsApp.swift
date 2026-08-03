import Foundation
import Win32Shim

/// P1 skeleton: prove the Win32 plumbing (floating window + tray + menu + GDI paint + timers).
/// P2 replaces the placeholder paint with the real clock face and wires the usage data.
final class WindowsApp {
    static let shared = WindowsApp()
    private init() {}

    // Menu command ids (must match what buildMenu assigns).
    private let cmdQuit: Int32 = 1

    func run() {
        win_set_dpi_aware()
        var cb = win_callbacks()
        cb.ctx = nil
        cb.on_paint = appPaint
        cb.on_tick = appTick
        cb.on_scan = appScan
        cb.on_tray_click = appTrayClick
        cb.on_build_menu = appBuildMenu
        cb.on_menu_cmd = appMenuCmd
        cb.on_destroy = appDestroy
        cb.scan_interval_ms = 30_000
        cb.width = 360
        cb.height = 430
        cb.initial_opacity = 1.0
        cb.class_name = nil        // shim defaults to "TokenClock"
        cb.window_title = nil
        _ = win_run(&cb)
    }
}

// MARK: - instance methods called by the C callbacks

extension WindowsApp {
    func paint(hdc: UnsafeMutableRawPointer?, w: Int32, h: Int32) {
        // Placeholder: cream dial + "TokenClock". P2 paints the real clock face.
        let cx = w / 2
        let cy = h / 2
        let r = min(w, h) / 2 - 12
        gdi_clear(hdc, w, h, 0xF3F3F3)
        gdi_fill_circle(hdc, cx, cy, r, 0xE8E0CF, 0x403933, 3)
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        drawText(hdc, cx: cx, cy: cy - 8, df.string(from: Date()), size: 22, rgb: 0x403933, bold: true)
        drawText(hdc, cx: cx, cy: cy + 22, "TokenClock · Windows", size: 11, rgb: 0x8A8074, bold: false)
    }

    func trayClick(button: Int32) {
        // P2: left-click/double-click toggles the detail panel.
    }

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        addMenuItem(menu, id: cmdQuit, "Quit TokenClock", checked: false)
    }

    func menuCmd(cmd: Int32) {
        if cmd == cmdQuit { win_quit(win_self()) }
    }

    private func drawText(_ hdc: UnsafeMutableRawPointer?, cx: Int32, cy: Int32, _ s: String, size: Int32, rgb: UInt32, bold: Bool) {
        s.withCString { p in gdi_text_center(hdc, cx, cy, p, size, rgb, bold ? 1 : 0) }
    }
    private func addMenuItem(_ menu: UnsafeMutableRawPointer?, id: Int32, _ label: String, checked: Bool) {
        label.withCString { p in menu_add_item(menu, id, p, checked ? 1 : 0) }
    }
}

// MARK: - @convention(c) trampolines → WindowsApp.shared

private let appPaint: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, hdc, w, h in
    WindowsApp.shared.paint(hdc: hdc, w: w, h: h)
}
private let appTick: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    win_invalidate(win_self())   // repaint every second (clock hands move)
}
private let appScan: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    // P2: WindowsUsageModel.scheduleScan()
}
private let appTrayClick: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, button in
    WindowsApp.shared.trayClick(button: button)
}
private let appBuildMenu: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, menu in
    WindowsApp.shared.buildMenu(menu: menu)
}
private let appMenuCmd: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { _, cmd in
    WindowsApp.shared.menuCmd(cmd: cmd)
}
private let appDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    // P2: stop API server, persist window position
}
