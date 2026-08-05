import Foundation
import Win32Shim

/// Windows UI 驱动。Win32Shim（C）负责窗口/托盘/菜单/消息循环；表盘由 winrender.cpp（GDI+ +
/// UpdateLayeredWindow）逐像素 alpha 合成——窗口在表盘外完全透明、边缘抗锯齿、带柔和阴影。
final class WindowsApp {
    nonisolated(unsafe) static let shared = WindowsApp()
    private init() {}

    private let cmdQuit: Int32 = 1
    /// 浮窗尺寸。280 ⇒ 表盘半径 116，与 macOS 中档（diameter 240pt）一致——
    /// classic 主题的描边/指针宽度均按 radius 116 校准，故窗口也按此对齐以像素级还原。
    private let size: Int32 = 280

    /// 顶部日期格式器（镜像 ViewModel.dateString：zh `M月d日 EEEE`，en 本地化模板）。
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        switch L10n.shared.language {
        case .zhHans: f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        case .zhHant: f.locale = Locale(identifier: "zh_TW"); f.dateFormat = "M月d日 EEEE"
        case .en:     f.locale = Locale(identifier: "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        }
        return f
    }()

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

    /// 渲染一帧：忠实 classic 表盘（配色/几何由 winrender.cpp 内置）+ 真实日期 + token 计数。
    /// token 暂为 "0"（尚未扫描用量）；P2 接上 WindowsUsageModel 后改为 TokenFormat.compact(真实值)。
    func render() {
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let date = Self.dateFmt.string(from: now)
        let tokens = "0"   // TODO(P2): TokenFormat.compact(todayTokens)
        date.withCString { dp in
            tokens.withCString { tp in
                win_render_clock(size, size,
                                 Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                                 dp, tp)
            }
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
