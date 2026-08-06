import Foundation
import Win32Shim

/// Windows 自定义主题的可编辑配置（对应 macOS CustomThemeConfig）。9 个颜色 + 指针样式 + 外环宽度，
/// 存为 JSON（颜色用 "#RRGGBB" 串规避大整数解析）于 SettingsKey.customThemeConfig。asWinTheme 以
/// classic 结构为底、用这些字段覆盖；刻度/数字保持 classic 的「干净」默认（不画）。
struct WindowsCustomTheme {
    var dialFill: UInt32 = 0xFFF7F7FA
    var dialRim: UInt32 = 0xFFD1D1D1
    var rimWidth: Double = 6
    var handStyle: Int = 0          // 0 round / 1 tapered / 2 lance / 3 sword
    var hourColor: UInt32 = 0xFFB71C1C
    var minuteColor: UInt32 = 0xFFE53935
    var secondColor: UInt32 = 0xFFFF5252
    var capOuter: UInt32 = 0xFFD1D1D1
    var capInner: UInt32 = 0xFFE53935
    var textPrimary: UInt32 = 0xFF2E2E33
    var textSecondary: UInt32 = 0xFF73737A

    /// 编辑器里 9 个颜色字段的顺序（与按钮 id 500+i 对应）。
    static let colorKeys = ["dialFill", "dialRim", "hourColor", "minuteColor", "secondColor",
                            "capOuter", "capInner", "textPrimary", "textSecondary"]

    func colorField(_ i: Int) -> UInt32 {
        switch i {
        case 0: return dialFill; case 1: return dialRim; case 2: return hourColor
        case 3: return minuteColor; case 4: return secondColor; case 5: return capOuter
        case 6: return capInner; case 7: return textPrimary; case 8: return textSecondary
        default: return 0
        }
    }
    mutating func setColorField(_ i: Int, _ v: UInt32) {
        switch i {
        case 0: dialFill = v; case 1: dialRim = v; case 2: hourColor = v
        case 3: minuteColor = v; case 4: secondColor = v; case 5: capOuter = v
        case 6: capInner = v; case 7: textPrimary = v; case 8: textSecondary = v
        default: break
        }
    }

    static func load() -> WindowsCustomTheme {
        var t = WindowsCustomTheme()
        if ProcessInfo.processInfo.environment["TC_CUSTOM_DEMO"] != nil {   // 调试：绿色演示配置
            t.dialFill = 0xFFE8F5E9; t.dialRim = 0xFF66BB6A
            t.hourColor = 0xFF1B5E20; t.minuteColor = 0xFF2E7D32; t.secondColor = 0xFFFFEB3B
            t.capOuter = 0xFF66BB6A; t.capInner = 0xFFFFEB3B
            t.textPrimary = 0xFF1B5E20; t.textSecondary = 0xFF388E3C
            t.handStyle = 2; t.rimWidth = 5
            return t
        }
        guard let raw = UserDefaults.standard.string(for: .customThemeConfig),
              let data = raw.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return t }
        for (i, key) in colorKeys.enumerated() {
            if let s = d[key] as? String, let v = parseHex(s) { t.setColorField(i, v) }
        }
        if let v = (d["rimWidth"] as? NSNumber)?.doubleValue ?? (d["rimWidth"] as? Double) { t.rimWidth = v }
        if let v = (d["handStyle"] as? NSNumber)?.intValue ?? (d["handStyle"] as? Int) { t.handStyle = v }
        return t
    }

    func save() {
        var d: [String: String] = [:]
        for i in 0..<Self.colorKeys.count { d[Self.colorKeys[i]] = Self.hex(colorField(i)) }
        var full: [String: Any] = d
        full["rimWidth"] = rimWidth
        full["handStyle"] = handStyle
        if let data = try? JSONSerialization.data(withJSONObject: full),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.setString(json, for: .customThemeConfig)
        }
    }

    var asWinTheme: win_theme {
        var t = win_theme()
        t.dial_fill = dialFill; t.dial_rim = dialRim; t.rim_width = rimWidth
        t.hand_style = Int32(handStyle)
        t.hour_color = hourColor; t.minute_color = minuteColor; t.second_color = secondColor
        t.hour_len = 0.48; t.minute_len = 0.68; t.second_len = 0.78
        t.hour_w = 4.5; t.minute_w = 3.0; t.second_w = 1.5
        t.cap_outer = capOuter; t.cap_inner = capInner
        t.show_ticks = 0; t.tick_color = 0; t.major_tick_color = 0
        t.show_numbers = 0; t.number_color = 0
        t.has_decoration = 0
        t.text_primary = textPrimary; t.text_secondary = textSecondary
        t.dd_bg = dialFill; t.dd_text = textPrimary; t.dd_subtext = textSecondary; t.dd_border = dialRim
        return t
    }

    static func hex(_ argb: UInt32) -> String { String(format: "#%06X", argb & 0xFFFFFF) }
    static func parseHex(_ s: String) -> UInt32? {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        guard let v = UInt32(h, radix: 16) else { return nil }
        return 0xFF000000 | v
    }
}
