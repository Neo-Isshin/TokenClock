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
    var numberColor: UInt32 = 0x00000000
    var tickColor: UInt32 = 0x00000000
    var majorTickColor: UInt32 = 0x00000000
    var dropdownBg: UInt32 = 0xFFF0F0F2
    var dropdownText: UInt32 = 0xFF2E2E33
    var dropdownSubtext: UInt32 = 0xFF73737A
    var dropdownBorder: UInt32 = 0xFFD1D1D1
    var hourWidth: Double = 4.5
    var minuteWidth: Double = 3.0
    var secondWidth: Double = 1.5
    var hourLength: Double = 0.48
    var minuteLength: Double = 0.68
    var secondLength: Double = 0.78
    var showNumbers = false
    var showTicks = false
    var hasDecoration = false
    var numberStyle = 1            // 1 arabic / 2 chinese

    /// 编辑器里 9 个颜色字段的顺序（与按钮 id 500+i 对应）。
    static let colorKeys = ["dialFill", "dialRim", "hourColor", "minuteColor", "secondColor",
                            "capOuter", "capInner", "numberColor", "tickColor", "majorTickColor",
                            "textPrimary", "textSecondary", "dropdownBg", "dropdownText", "dropdownSubtext", "dropdownBorder"]

    func colorField(_ i: Int) -> UInt32 {
        switch i {
        case 0: return dialFill; case 1: return dialRim; case 2: return hourColor
        case 3: return minuteColor; case 4: return secondColor; case 5: return capOuter
        case 6: return capInner; case 7: return numberColor; case 8: return tickColor
        case 9: return majorTickColor; case 10: return textPrimary; case 11: return textSecondary
        case 12: return dropdownBg; case 13: return dropdownText; case 14: return dropdownSubtext
        case 15: return dropdownBorder
        default: return 0
        }
    }
    mutating func setColorField(_ i: Int, _ v: UInt32) {
        switch i {
        case 0: dialFill = v; case 1: dialRim = v; case 2: hourColor = v
        case 3: minuteColor = v; case 4: secondColor = v; case 5: capOuter = v
        case 6: capInner = v; case 7: numberColor = v; case 8: tickColor = v
        case 9: majorTickColor = v; case 10: textPrimary = v; case 11: textSecondary = v
        case 12: dropdownBg = v; case 13: dropdownText = v; case 14: dropdownSubtext = v
        case 15: dropdownBorder = v
        default: break
        }
    }

    init() {}

    init(dictionary d: [String: Any]) {
        self.init()
        for (i, key) in Self.colorKeys.enumerated() {
            if let s = d[key] as? String, let value = Self.parseHex(s) { setColorField(i, value) }
        }
        func number(_ key: String, _ fallback: Double) -> Double { (d[key] as? NSNumber)?.doubleValue ?? fallback }
        rimWidth = number("rimWidth", rimWidth)
        handStyle = Int(number("handStyle", Double(handStyle)))
        hourWidth = number("hourWidth", hourWidth); minuteWidth = number("minuteWidth", minuteWidth); secondWidth = number("secondWidth", secondWidth)
        hourLength = number("hourLength", hourLength); minuteLength = number("minuteLength", minuteLength); secondLength = number("secondLength", secondLength)
        showNumbers = (d["showNumbers"] as? Bool) ?? showNumbers
        showTicks = (d["showTicks"] as? Bool) ?? showTicks
        hasDecoration = (d["hasDecoration"] as? Bool) ?? hasDecoration
        numberStyle = Int(number("numberStyle", Double(numberStyle)))
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
        return WindowsCustomTheme(dictionary: d)
    }

    var dictionary: [String: Any] {
        var d: [String: String] = [:]
        for i in 0..<Self.colorKeys.count { d[Self.colorKeys[i]] = Self.hex(colorField(i)) }
        var full: [String: Any] = d
        full["rimWidth"] = rimWidth
        full["handStyle"] = handStyle
        full["hourWidth"] = hourWidth; full["minuteWidth"] = minuteWidth; full["secondWidth"] = secondWidth
        full["hourLength"] = hourLength; full["minuteLength"] = minuteLength; full["secondLength"] = secondLength
        full["showNumbers"] = showNumbers; full["showTicks"] = showTicks; full["hasDecoration"] = hasDecoration
        full["numberStyle"] = numberStyle
        return full
    }

    func save() {
        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.setString(json, for: .customThemeConfig)
        }
    }

    var asWinTheme: win_theme {
        var t = win_theme()
        t.dial_fill = dialFill; t.dial_rim = dialRim; t.rim_width = rimWidth
        t.hand_style = Int32(handStyle)
        t.hour_color = hourColor; t.minute_color = minuteColor; t.second_color = secondColor
        t.hour_len = hourLength; t.minute_len = minuteLength; t.second_len = secondLength
        t.hour_w = hourWidth; t.minute_w = minuteWidth; t.second_w = secondWidth
        t.cap_outer = capOuter; t.cap_inner = capInner
        t.show_ticks = showTicks ? 1 : 0; t.tick_color = tickColor; t.major_tick_color = majorTickColor
        t.show_numbers = showNumbers ? Int32(numberStyle) : 0; t.number_color = numberColor
        t.has_decoration = hasDecoration ? 1 : 0
        t.text_primary = textPrimary; t.text_secondary = textSecondary
        t.dd_bg = dropdownBg; t.dd_text = dropdownText; t.dd_subtext = dropdownSubtext; t.dd_border = dropdownBorder
        return t
    }

    static func hex(_ argb: UInt32) -> String { String(format: "#%06X", argb & 0xFFFFFF) }
    static func parseHex(_ s: String) -> UInt32? {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        guard let v = UInt32(h, radix: 16) else { return nil }
        return 0xFF000000 | v
    }
}

struct WindowsSavedCustomTheme {
    let id: String
    var name: String
    var config: WindowsCustomTheme

    static func loadAll() -> [WindowsSavedCustomTheme] {
        guard let raw = UserDefaults.standard.string(for: .savedCustomThemes),
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String,
                  let config = item["config"] as? [String: Any] else { return nil }
            return WindowsSavedCustomTheme(id: id, name: name, config: WindowsCustomTheme(dictionary: config))
        }
    }

    static func saveAll(_ themes: [WindowsSavedCustomTheme]) {
        let array: [[String: Any]] = themes.map { ["id": $0.id, "name": $0.name, "config": $0.config.dictionary] }
        if let data = try? JSONSerialization.data(withJSONObject: array), let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.setString(raw, for: .savedCustomThemes)
        }
    }
}
