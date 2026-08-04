import Foundation
import Win32Shim

/// Windows UI 驱动。Win32Shim（C）负责窗口/托盘/菜单/消息循环；表盘由 winrender.cpp（GDI+ +
/// UpdateLayeredWindow）逐像素 alpha 合成——窗口在表盘外完全透明、边缘抗锯齿、带柔和阴影。
final class WindowsApp {
    nonisolated(unsafe) static let shared = WindowsApp()
    private init() {}

    private let cmdQuit: Int32 = 1
    private let size: Int32 = 320   // 浮窗尺寸（正方形，表盘填满，表盘外透明）

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
        cb.width = size
        cb.height = size
        cb.initial_opacity = 1.0
        cb.class_name = nil
        cb.window_title = nil
        _ = win_run(&cb)
    }

    /// 渲染一帧（时间 + token 文本 + 经典配色）。token 目前占位，P2 接上 WindowsUsageModel 后显示真实用量。
    func render() {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let token = "—"   // TODO(P2): compact today token count
        token.withCString { p in
            win_render_clock(size, size,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0), p,
                             0xE8E0CF,  // dial fill (cream)
                             0x403933,  // dial stroke (dark brown)
                             0x6A5F52,  // ticks
                             0x403933,  // hour/minute hands (dark)
                             0xC7331F,  // second hand (red)
                             0x403933)  // token text
        }
    }

    func trayClick(button: Int32) { /* P2: 左键展开详情面板 */ }

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        addMenuItem(menu, id: cmdQuit, "Quit TokenClock", checked: false)
    }

    func menuCmd(cmd: Int32) {
        if cmd == cmdQuit { win_quit(win_self()) }
    }

    private func addMenuItem(_ menu: UnsafeMutableRawPointer?, id: Int32, _ label: String, checked: Bool) {
        label.withCString { p in menu_add_item(menu, id, p, checked ? 1 : 0) }
    }
}

// MARK: - @convention(c) trampolines → WindowsApp.shared

private let appPaint: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, _, _, _ in
    WindowsApp.shared.render()      // layered window: render via UpdateLayeredWindow
}
private let appTick: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.render()      // 每秒重绘一帧（秒针走动）
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
