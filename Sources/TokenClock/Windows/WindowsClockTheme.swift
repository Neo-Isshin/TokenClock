import Foundation
import Win32Shim

/// Windows 表盘主题：8 个内置主题的 win_theme 取值，逐项移植自 macOS ClockFaceTheme
/// （颜色转 ARGB 以表达 .clear/opacity；指针/刻度/数字/装饰标志由 winrender.cpp 据此渲染）。
/// custom 主题暂映射到 classic（自定义编辑器属后续设置面板范畴）。
enum WindowsClockTheme: String, CaseIterable {
    // Keep the picker/menu order identical to ClockFaceTheme.allCases on macOS normal.
    case glass, classic, glacier, midnight, luxe, gufeng, railgun, sky, custom

    var displayName: String { L10n.shared.tr("themeName.\(rawValue)") }

    var winTheme: win_theme {
        if self == .custom { return WindowsCustomTheme.load().asWinTheme }   // 自定义：读编辑器存盘
        var t = win_theme()
        t.hour_len = 0.48; t.minute_len = 0.68; t.second_len = 0.78
        switch self {
        case .classic:
            // Porcelain — warm glazed ceramic, fine minute track, graphite hands.
            t.dial_fill = rgb(0.985, 0.976, 0.945); t.dial_rim = rgb(0.72, 0.68, 0.59); t.rim_width = 2.2
            t.material_style = 2
            t.hand_style = 0
            t.hour_color = rgb(0.15, 0.14, 0.13); t.minute_color = rgb(0.23, 0.21, 0.19); t.second_color = rgb(0.82, 0.20, 0.14)
            t.hour_w = 5.0; t.minute_w = 3.2; t.second_w = 1.35
            t.cap_outer = rgb(0.36, 0.32, 0.27); t.cap_inner = rgb(0.89, 0.72, 0.43)
            t.show_ticks = 1; t.tick_color = rgb(0.36, 0.33, 0.29, 0.52); t.major_tick_color = rgb(0.22, 0.20, 0.18)
            t.show_numbers = 0; t.number_color = clear
            t.has_decoration = 0
            t.text_primary = rgb(0.17, 0.16, 0.14); t.text_secondary = rgb(0.40, 0.37, 0.32)

        case .midnight:
            // Smoked Glass — near-black glass with cool edge light and a cyan seconds hand.
            t.dial_fill = rgb(0.055, 0.075, 0.098, 0.96); t.dial_rim = rgb(0.36, 0.48, 0.59, 0.82); t.rim_width = 2.0
            t.material_style = 3
            t.hand_style = 1
            t.hour_color = rgb(0.89, 0.93, 0.96); t.minute_color = rgb(0.68, 0.77, 0.84); t.second_color = rgb(0.16, 0.78, 0.91)
            t.hour_w = 5.5; t.minute_w = 3.4; t.second_w = 1.25
            t.cap_outer = rgb(0.69, 0.82, 0.89); t.cap_inner = rgb(0.16, 0.78, 0.91)
            t.show_ticks = 1; t.tick_color = rgb(0.66, 0.75, 0.82, 0.42); t.major_tick_color = rgb(0.86, 0.93, 0.97, 0.92)
            t.show_numbers = 0; t.number_color = clear
            t.has_decoration = 0
            t.text_primary = rgb(0.91, 0.94, 0.96); t.text_secondary = rgb(0.59, 0.68, 0.75)

        case .luxe:
            t.dial_fill = rgb(0.102, 0.102, 0.180); t.dial_rim = rgb(0.176, 0.176, 0.267); t.rim_width = 2
            t.hand_style = 2
            t.hour_color = rgb(1.0, 0.835, 0.310); t.minute_color = rgb(1.0, 0.718, 0.302); t.second_color = rgb(0.941, 0.384, 0.573)
            t.hour_w = 6.0; t.minute_w = 4.5; t.second_w = 1.0
            t.cap_outer = rgb(1.0, 0.835, 0.310); t.cap_inner = rgb(0.102, 0.102, 0.180)
            t.show_ticks = 1; t.tick_color = rgb(0.400, 0.333, 0.200); t.major_tick_color = rgb(1.0, 0.835, 0.310)
            t.show_numbers = 1; t.number_color = rgb(0.667, 0.567, 0.333)
            t.has_decoration = 0
            t.text_primary = rgb(0.910, 0.835, 0.639); t.text_secondary = rgb(0.600, 0.533, 0.400)

        case .gufeng:
            t.dial_fill = rgb(0.925, 0.886, 0.812); t.dial_rim = rgb(0.580, 0.400, 0.247); t.rim_width = 3
            t.hand_style = 3
            t.hour_color = rgb(0.200, 0.180, 0.160); t.minute_color = rgb(0.350, 0.280, 0.220); t.second_color = rgb(0.722, 0.184, 0.184)
            t.hour_w = 5.0; t.minute_w = 3.5; t.second_w = 1.5
            t.cap_outer = rgb(0.580, 0.400, 0.247); t.cap_inner = rgb(0.722, 0.184, 0.184)
            t.show_ticks = 1; t.tick_color = rgb(0.650, 0.500, 0.350); t.major_tick_color = rgb(0.350, 0.220, 0.160)
            t.show_numbers = 2; t.number_color = rgb(0.300, 0.200, 0.150)   // 中文壹贰叁…
            t.has_decoration = 0
            t.text_primary = rgb(0.250, 0.180, 0.130); t.text_secondary = rgb(0.500, 0.380, 0.280)

        case .railgun:
            t.dial_fill = rgb(0.918, 0.898, 0.855); t.dial_rim = rgb(0.620, 0.470, 0.380); t.rim_width = 2.5
            t.hand_style = 1
            t.hour_color = rgb(0.820, 0.580, 0.560); t.minute_color = rgb(0.850, 0.650, 0.600); t.second_color = rgb(0.400, 0.620, 0.950)
            t.hour_w = 5.5; t.minute_w = 3.5; t.second_w = 1.8
            t.cap_outer = rgb(0.820, 0.580, 0.560); t.cap_inner = rgb(0.400, 0.620, 0.950)
            t.show_ticks = 1; t.tick_color = rgb(0.750, 0.650, 0.580); t.major_tick_color = rgb(0.620, 0.470, 0.380)
            t.show_numbers = 1; t.number_color = rgb(0.500, 0.350, 0.300)
            t.has_decoration = 0
            t.text_primary = rgb(0.500, 0.350, 0.300); t.text_secondary = rgb(0.680, 0.560, 0.480)

        case .sky:
            t.dial_fill = rgb(0.529, 0.745, 0.922); t.dial_rim = rgb(0.420, 0.620, 0.820); t.rim_width = 2.5
            t.hand_style = 1
            t.hour_color = rgb(0.960, 0.878, 0.400); t.minute_color = rgb(0.980, 0.910, 0.520); t.second_color = rgb(1.0, 0.580, 0.200)
            t.hour_w = 5.0; t.minute_w = 3.5; t.second_w = 1.5
            t.cap_outer = rgb(0.960, 0.878, 0.400); t.cap_inner = rgb(1.0, 0.580, 0.200)
            t.show_ticks = 1; t.tick_color = rgb(0.620, 0.780, 0.920); t.major_tick_color = rgb(0.960, 0.920, 0.780)
            t.show_numbers = 1; t.number_color = rgb(0.220, 0.380, 0.560)
            t.has_decoration = 1   // 太阳 + 云朵
            t.text_primary = rgb(0.180, 0.340, 0.520); t.text_secondary = rgb(0.380, 0.520, 0.660)

        case .glass:
            // Frost — cool translucent crystal with an icy inner edge and Windows-blue seconds.
            t.dial_fill = rgb(0.91, 0.95, 0.99, 0.92); t.dial_rim = rgb(0.70, 0.82, 0.91, 0.85); t.rim_width = 1.5
            t.material_style = 1
            t.hand_style = 0
            t.hour_color = rgb(0.12, 0.17, 0.22); t.minute_color = rgb(0.20, 0.28, 0.35); t.second_color = rgb(0.0, 0.47, 0.84)
            t.hour_w = 4.8; t.minute_w = 3.0; t.second_w = 1.25
            t.cap_outer = rgb(0.18, 0.25, 0.31); t.cap_inner = rgb(0.74, 0.89, 0.98)
            t.show_ticks = 1; t.tick_color = rgb(0.18, 0.29, 0.38, 0.38); t.major_tick_color = rgb(0.12, 0.22, 0.30, 0.78)
            t.show_numbers = 0; t.number_color = clear
            t.has_decoration = 0
            t.text_primary = rgb(0.11, 0.16, 0.20); t.text_secondary = rgb(0.31, 0.40, 0.47)

        case .glacier:
            t.dial_fill = gray(0.96); t.dial_rim = clear; t.rim_width = 0
            t.hand_style = 3
            t.hour_color = gray(0.18); t.minute_color = gray(0.35); t.second_color = rgb(0.95, 0.40, 0.55)
            t.hour_w = 4.0; t.minute_w = 2.8; t.second_w = 1.2
            t.cap_outer = gray(0.18); t.cap_inner = rgb(0.95, 0.40, 0.55)
            t.show_ticks = 1; t.tick_color = rgb(0.10, 0.20, 0.42, 0.55); t.major_tick_color = rgb(0.10, 0.20, 0.42)
            t.show_numbers = 1; t.number_color = rgb(0.10, 0.20, 0.42)
            t.has_decoration = 0
            t.text_primary = rgb(0.10, 0.20, 0.42); t.text_secondary = rgb(0.10, 0.20, 0.42, 0.7)
        default: break   // .custom 在函数顶部已 early-return
        }
        // 下拉卡片配色（移植自 ClockFaceTheme.dropdownBgColor/Text/Subtext/Border）
        switch self {
        case .classic:  t.dd_bg = rgb(0.94, 0.94, 0.95); t.dd_text = rgb(0.18, 0.18, 0.20); t.dd_subtext = rgb(0.45, 0.45, 0.48); t.dd_border = gray(0.82)
        case .midnight: t.dd_bg = rgb(0.133, 0.184, 0.247); t.dd_text = rgb(0.878, 0.878, 0.878); t.dd_subtext = rgb(0.533, 0.600, 0.667); t.dd_border = rgb(0.200, 0.290, 0.400)
        case .luxe:     t.dd_bg = rgb(0.125, 0.125, 0.200); t.dd_text = rgb(0.910, 0.835, 0.639); t.dd_subtext = rgb(0.600, 0.533, 0.400); t.dd_border = rgb(0.250, 0.220, 0.150)
        case .gufeng:   t.dd_bg = rgb(0.910, 0.878, 0.812); t.dd_text = rgb(0.280, 0.200, 0.150); t.dd_subtext = rgb(0.520, 0.400, 0.300); t.dd_border = rgb(0.650, 0.480, 0.320)
        case .railgun:  t.dd_bg = rgb(0.925, 0.906, 0.875); t.dd_text = rgb(0.500, 0.350, 0.300); t.dd_subtext = rgb(0.680, 0.560, 0.480); t.dd_border = rgb(0.780, 0.680, 0.600)
        case .sky:      t.dd_bg = rgb(0.600, 0.780, 0.920); t.dd_text = rgb(0.180, 0.340, 0.520); t.dd_subtext = rgb(0.380, 0.520, 0.660); t.dd_border = rgb(0.500, 0.680, 0.840)
        case .glass:    t.dd_bg = rgb(0.93, 0.95, 0.97); t.dd_text = rgb(0.18, 0.18, 0.20); t.dd_subtext = rgb(0.45, 0.45, 0.48); t.dd_border = gray(0.82)
        case .glacier:  t.dd_bg = rgb(0.94, 0.97, 1.00); t.dd_text = rgb(0.10, 0.20, 0.42); t.dd_subtext = rgb(0.10, 0.20, 0.42, 0.7); t.dd_border = rgb(0.10, 0.20, 0.42, 0.22)
        default: break
        }
        return t
    }

    // MARK: - 颜色辅助：Color(r,g,b[,opacity]) → ARGB 0xAARRGGBB（.clear ⇒ alpha 0）
    private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> UInt32 {
        let R = UInt32(min(255, max(0, (r * 255).rounded())))
        let G = UInt32(min(255, max(0, (g * 255).rounded())))
        let B = UInt32(min(255, max(0, (b * 255).rounded())))
        let A = UInt32(min(255, max(0, (a * 255).rounded())))
        return (A << 24) | (R << 16) | (G << 8) | B
    }
    private func gray(_ w: Double, _ a: Double = 1.0) -> UInt32 { rgb(w, w, w, a) }
    private var clear: UInt32 { 0x00000000 }
}
