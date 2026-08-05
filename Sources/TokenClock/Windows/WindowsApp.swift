import Foundation
import Win32Shim

/// Windows UI 驱动。Win32Shim（C）负责窗口/托盘/菜单/消息循环；表盘由 winrender.cpp（GDI+ +
/// UpdateLayeredWindow）逐像素 alpha 合成。数据层复用共享 Services（WindowsUsageModel 接 14 个
/// usage 服务），本地 API 服务由 winhttp.c（Winsock）后台线程承载。
final class WindowsApp: @unchecked Sendable {
    static let shared = WindowsApp()
    private init() {}

    private let cmdQuit: Int32 = 1
    /// 浮窗尺寸。280 ⇒ 表盘半径 116，与 macOS 中档（diameter 240pt）一致——
    /// classic 主题的描边/指针宽度均按 radius 116 校准，故窗口也按此对齐以像素级还原。
    private let size: Int32 = 280

    private let model = WindowsUsageModel()
    fileprivate var api: WindowsAPIServer?

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
        cb.scan_interval_ms = Int32(AppConfig.Timers.dataScan * 1000)   // 30s 数据扫描
        cb.width = size
        cb.height = size
        cb.initial_opacity = 1.0
        cb.class_name = nil
        cb.window_title = nil

        // 数据层：本地 API 服务 + 首次全量扫描（后台线程，下一帧起渲染真实用量）
        api = WindowsAPIServer(model: model)
        api?.start()
        scheduleScan(incremental: false)

        _ = win_run(&cb)
    }

    /// 渲染一帧：忠实 classic 表盘 + 叠加真实用量（日期 / token 计数 / 消息数 / 活跃工具）。
    /// 天气（IP 定位）尚未接入，暂留空。表盘配色/几何由 winrender.cpp 内置。
    func render() {
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let date = Self.dateFmt.string(from: now)

        let tools = model.tools
        let tokens = TokenFormat.compact(UsageAggregator.totalTokens(tools))
        let messages = L10n.shared.tr("clock.messagesCount", UsageAggregator.totalMessages(tools))
        let top = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let tool1 = top.first.map { "\($0.emoji) \($0.abbreviation)" } ?? ""
        let tool2 = top.count > 1 ? "\(top[1].emoji) \(top[1].abbreviation)" : ""
        let weather = ""   // TODO: 接入 WeatherService IP 定位

        Self.withCStrings([date, weather, tokens, messages, tool1, tool2]) { ptrs in
            var ov = win_overlay()
            ov.date = ptrs[0]
            ov.weather = ptrs[1]
            ov.tokens = ptrs[2]
            ov.messages = ptrs[3]
            ov.tool_left1 = ptrs[4]
            ov.tool_left2 = ptrs[5]
            win_render_clock(size, size,
                             Int32(comps.hour ?? 0), Int32(comps.minute ?? 0), Int32(comps.second ?? 0),
                             &ov)
        }
    }

    /// 后台扫描用量；完成后下一个 1s tick 自动重绘出新数据（render 经 UpdateLayeredWindow，无需显式 invalidate）。
    fileprivate func scheduleScan(incremental: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.model.scan(incremental: incremental)
        }
    }

    func trayClick(button: Int32) { /* P4: 左键展开详情面板 */ }

    func buildMenu(menu: UnsafeMutableRawPointer?) {
        addMenuItem(menu, id: cmdQuit, "Quit TokenClock", checked: false)
    }

    func menuCmd(cmd: Int32) {
        if cmd == cmdQuit { win_quit(win_self()) }
    }

    private func addMenuItem(_ menu: UnsafeMutableRawPointer?, id: Int32, _ label: String, checked: Bool) {
        label.withCString { p in menu_add_item(menu, id, p, checked ? 1 : 0) }
    }

    /// 把一组 Swift String 的 C 字符串指针在同一个活跃作用域内交给 body——
    /// 这样 win_render_clock 调用期间所有指针都有效，无需 strdup/释放。
    private static func withCStrings<T>(_ ss: [String], _ body: ([UnsafePointer<CChar>]) -> T) -> T {
        func recur(_ i: Int, _ acc: [UnsafePointer<CChar>]) -> T {
            if i == ss.count { return body(acc) }
            return ss[i].withCString { p in recur(i + 1, acc + [p]) }
        }
        return recur(0, [])
    }
}

// MARK: - @convention(c) trampolines → WindowsApp.shared

private let appPaint: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Void = { _, _, _, _ in
    WindowsApp.shared.render()      // layered window: render via UpdateLayeredWindow
}
private let appTick: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.render()      // 每秒重绘一帧（秒针走动 + 用量刷新）
}
private let appScan: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    WindowsApp.shared.scheduleScan(incremental: true)
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
    WindowsApp.shared.api?.stop()   // 关闭本地 API 服务
}
