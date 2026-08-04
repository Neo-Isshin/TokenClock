import Foundation
import Win32Shim

/// P1 skeleton: prove the Win32 plumbing (floating window + tray + menu + GDI paint + timers).
/// P2 replaces the placeholder paint with the real clock face and wires the usage data.
final class WindowsApp {
    nonisolated(unsafe) static let shared = WindowsApp()
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
        gdi_clear(hdc, w, h, 0xF3F3F3)
        drawClock(hdc: hdc, w: w, h: h, date: Date())
    }

    /// GDI 复刻 Linux/Cairo 的经典表盘：奶白表盘 + 60 刻度 + 时/分/秒针 + 中心帽 + token 文本。
    private func drawClock(hdc: UnsafeMutableRawPointer?, w: Int32, h: Int32, date: Date) {
        let cx = w / 2
        let cy = h / 2
        let r = Double(min(w, h) / 2 - 12)
        let cxd = Double(cx), cyd = Double(cy)

        gdi_fill_circle(hdc, cx, cy, Int32(r), 0xE8E0CF, 0x403933, 3)   // dial

        for i in 0..<60 {                                                 // ticks
            let a = deg2rad(Double(i) * 6.0 - 90.0)
            let isHour = (i % 5 == 0)
            let inner = isHour ? r - 18.0 : r - 10.0
            let outer = r - 2.0
            gdi_line(hdc,
                     Int32(cxd + cos(a) * inner), Int32(cyd + sin(a) * inner),
                     Int32(cxd + cos(a) * outer), Int32(cyd + sin(a) * outer),
                     isHour ? 3 : 1, isHour ? 0x403933 : 0x6A5F52)
        }

        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let h = Double(comps.hour ?? 0), m = Double(comps.minute ?? 0), s = Double(comps.second ?? 0)
        drawHand(hdc, cx, cy, deg: (h.truncatingRemainder(dividingBy: 12) + m / 60) * 30, len: r * 0.5,  width: 6, rgb: 0x403933)
        drawHand(hdc, cx, cy, deg: (m + s / 60) * 6,                  len: r * 0.72, width: 4, rgb: 0x403933)
        drawHand(hdc, cx, cy, deg: s * 6,                             len: r * 0.78, width: 2, rgb: 0xC7331F)

        gdi_fill_circle(hdc, cx, cy, 6, 0x403933, 0x403933, 0)          // center cap
        drawText(hdc, cx: cx, cy: Int32(cyd + r * 0.52), "—", size: 20, rgb: 0x403933, bold: true) // token (P2 data)
    }

    private func drawHand(_ hdc: UnsafeMutableRawPointer?, _ cx: Int32, _ cy: Int32, deg: Double, len: Double, width: Int32, rgb: UInt32) {
        let a = deg2rad(deg - 90)
        gdi_line(hdc, cx, cy,
                 Int32(Double(cx) + cos(a) * len), Int32(Double(cy) + sin(a) * len),
                 width, rgb)
    }
    private func deg2rad(_ d: Double) -> Double { d * .pi / 180.0 }

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
