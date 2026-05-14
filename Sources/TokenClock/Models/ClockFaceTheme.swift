import SwiftUI

enum ClockFaceTheme: String, CaseIterable, Identifiable {
    case classic
    case midnight
    case luxe
    case gufeng       // 古风
    case railgun      // 超电磁炮
    case sky          // 天空
    case custom       // 自定义

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "经典"
        case .midnight: return "深夜"
        case .luxe: return "暗金"
        case .gufeng: return "古风"
        case .railgun: return "超電磁砲"
        case .sky: return "天空"
        case .custom: return "自定义"
        }
    }

    var description: String {
        switch self {
        case .classic: return "浅灰表盘 · 红色层次指针"
        case .midnight: return "深蓝表盘 · 青色锥形指针"
        case .luxe: return "暗色表盘 · 金色菱形指针"
        case .gufeng: return "宣纸底色 · 墨色剑形指针"
        case .railgun: return "米白表盘 · 电弧蓝秒针"
        case .sky: return "蓝天白云 · 阳光金色指针"
        case .custom: return "用户自定义配色与样式"
        }
    }

    private var custom: CustomThemeConfig { CustomThemeConfig.load() }

    // MARK: - 表盘

    var dialColor: Color {
        switch self {
        case .classic: return Color(red: 0.97, green: 0.97, blue: 0.98)
        case .midnight: return Color(red: 0.106, green: 0.157, blue: 0.220)
        case .luxe: return Color(red: 0.102, green: 0.102, blue: 0.180)
        case .gufeng: return Color(red: 0.925, green: 0.886, blue: 0.812)
        case .railgun: return Color(red: 0.918, green: 0.898, blue: 0.855)
        case .sky: return Color(red: 0.529, green: 0.745, blue: 0.922)
        case .custom: return custom.dialColor.swiftUIColor
        }
    }

    var dialRimColor: Color {
        switch self {
        case .classic: return Color(white: 0.82)
        case .midnight: return Color(red: 0.165, green: 0.247, blue: 0.373)
        case .luxe: return Color(red: 0.176, green: 0.176, blue: 0.267)
        case .gufeng: return Color(red: 0.580, green: 0.400, blue: 0.247)
        case .railgun: return Color(red: 0.620, green: 0.470, blue: 0.380)
        case .sky: return Color(red: 0.420, green: 0.620, blue: 0.820)
        case .custom: return custom.dialRimColor.swiftUIColor
        }
    }

    var dialRimWidth: CGFloat {
        switch self {
        case .classic: return 6
        case .midnight: return 2.5
        case .luxe: return 2
        case .gufeng: return 3
        case .railgun: return 2.5
        case .sky: return 2.5
        case .custom: return custom.dialRimWidth
        }
    }

    // MARK: - 表盘装饰

    var hasDialDecoration: Bool {
        switch self {
        case .sky: return true
        case .custom: return custom.hasDialDecoration
        default: return false
        }
    }

    // MARK: - 指针颜色

    var hourHandColor: Color {
        switch self {
        case .classic: return Color(red: 0.718, green: 0.110, blue: 0.110)
        case .midnight: return Color(red: 0.149, green: 0.776, blue: 0.855)
        case .luxe: return Color(red: 1.0, green: 0.835, blue: 0.310)
        case .gufeng: return Color(red: 0.200, green: 0.180, blue: 0.160)
        case .railgun: return Color(red: 0.820, green: 0.580, blue: 0.560)
        case .sky: return Color(red: 0.960, green: 0.878, blue: 0.400)
        case .custom: return custom.hourHandColor.swiftUIColor
        }
    }

    var minuteHandColor: Color {
        switch self {
        case .classic: return Color(red: 0.898, green: 0.224, blue: 0.208)
        case .midnight: return Color(red: 0.502, green: 0.871, blue: 0.918)
        case .luxe: return Color(red: 1.0, green: 0.718, blue: 0.302)
        case .gufeng: return Color(red: 0.350, green: 0.280, blue: 0.220)
        case .railgun: return Color(red: 0.850, green: 0.650, blue: 0.600)
        case .sky: return Color(red: 0.980, green: 0.910, blue: 0.520)
        case .custom: return custom.minuteHandColor.swiftUIColor
        }
    }

    var secondHandColor: Color {
        switch self {
        case .classic: return Color(red: 1.0, green: 0.322, blue: 0.322)
        case .midnight: return Color(white: 1.0)
        case .luxe: return Color(red: 0.941, green: 0.384, blue: 0.573)
        case .gufeng: return Color(red: 0.722, green: 0.184, blue: 0.184)
        case .railgun: return Color(red: 0.400, green: 0.620, blue: 0.950)
        case .sky: return Color(red: 1.0, green: 0.580, blue: 0.200)
        case .custom: return custom.secondHandColor.swiftUIColor
        }
    }

    // MARK: - 指针样式

    enum HandStyle {
        case round
        case tapered
        case lance
        case sword
    }

    var handStyle: HandStyle {
        switch self {
        case .classic: return .round
        case .midnight: return .tapered
        case .luxe: return .lance
        case .gufeng: return .sword
        case .railgun: return .tapered
        case .sky: return .tapered
        case .custom: return custom.handStyle
        }
    }

    // MARK: - 中心点

    var centerDotOuterColor: Color {
        switch self {
        case .classic: return Color(white: 0.82)
        case .midnight: return Color(red: 0.149, green: 0.776, blue: 0.855)
        case .luxe: return Color(red: 1.0, green: 0.835, blue: 0.310)
        case .gufeng: return Color(red: 0.580, green: 0.400, blue: 0.247)
        case .railgun: return Color(red: 0.820, green: 0.580, blue: 0.560)
        case .sky: return Color(red: 0.960, green: 0.878, blue: 0.400)
        case .custom: return custom.centerDotOuterColor.swiftUIColor
        }
    }

    var centerDotInnerColor: Color {
        switch self {
        case .classic: return Color(red: 0.898, green: 0.224, blue: 0.208)
        case .midnight: return Color(white: 1.0)
        case .luxe: return Color(red: 0.102, green: 0.102, blue: 0.180)
        case .gufeng: return Color(red: 0.722, green: 0.184, blue: 0.184)
        case .railgun: return Color(red: 0.400, green: 0.620, blue: 0.950)
        case .sky: return Color(red: 1.0, green: 0.580, blue: 0.200)
        case .custom: return custom.centerDotInnerColor.swiftUIColor
        }
    }

    // MARK: - 刻度

    var hasTickMarks: Bool { true }

    var tickMarkColor: Color {
        switch self {
        case .classic: return .clear
        case .midnight: return Color(red: 0.290, green: 0.396, blue: 0.502)
        case .luxe: return Color(red: 0.400, green: 0.333, blue: 0.200)
        case .gufeng: return Color(red: 0.650, green: 0.500, blue: 0.350)
        case .railgun: return Color(red: 0.750, green: 0.650, blue: 0.580)
        case .sky: return Color(red: 0.620, green: 0.780, blue: 0.920)
        case .custom: return custom.tickMarkColor.swiftUIColor
        }
    }

    var majorTickMarkColor: Color {
        switch self {
        case .classic: return .clear
        case .midnight: return Color(red: 0.502, green: 0.871, blue: 0.918)
        case .luxe: return Color(red: 1.0, green: 0.835, blue: 0.310)
        case .gufeng: return Color(red: 0.350, green: 0.220, blue: 0.160)
        case .railgun: return Color(red: 0.620, green: 0.470, blue: 0.380)
        case .sky: return Color(red: 0.960, green: 0.920, blue: 0.780)
        case .custom: return custom.majorTickMarkColor.swiftUIColor
        }
    }

    // MARK: - 数字

    var showNumbers: Bool { true }

    var numberColor: Color {
        switch self {
        case .classic: return .clear
        case .midnight: return Color(red: 0.400, green: 0.533, blue: 0.667)
        case .luxe: return Color(red: 0.667, green: 0.567, blue: 0.333)
        case .gufeng: return Color(red: 0.300, green: 0.200, blue: 0.150)
        case .railgun: return Color(red: 0.500, green: 0.350, blue: 0.300)
        case .sky: return Color(red: 0.220, green: 0.380, blue: 0.560)
        case .custom: return custom.numberColor.swiftUIColor
        }
    }

    enum NumberStyle {
        case arabic
        case chinese
    }

    var numberStyle: NumberStyle {
        switch self {
        case .gufeng: return .chinese
        case .custom: return custom.numberStyle
        default: return .arabic
        }
    }

    var numberFontDesign: Font.Design {
        switch self {
        case .gufeng: return .serif
        case .railgun: return .monospaced
        case .sky: return .default
        case .custom: return custom.numberFontDesign
        default: return .rounded
        }
    }

    // MARK: - 指针尺寸

    var hourHandLength: CGFloat { 0.48 }
    var minuteHandLength: CGFloat { 0.68 }
    var secondHandLength: CGFloat { 0.78 }

    var hourHandWidth: CGFloat {
        switch self {
        case .classic: return 4.5
        case .midnight: return 5.5
        case .luxe: return 6.0
        case .gufeng: return 5.0
        case .railgun: return 5.5
        case .sky: return 5.0
        case .custom: return custom.hourHandWidth
        }
    }

    var minuteHandWidth: CGFloat {
        switch self {
        case .classic: return 3.0
        case .midnight: return 3.5
        case .luxe: return 4.5
        case .gufeng: return 3.5
        case .railgun: return 3.5
        case .sky: return 3.5
        case .custom: return custom.minuteHandWidth
        }
    }

    var secondHandWidth: CGFloat {
        switch self {
        case .classic: return 1.5
        case .midnight: return 1.2
        case .luxe: return 1.0
        case .gufeng: return 1.5
        case .railgun: return 1.8
        case .sky: return 1.5
        case .custom: return custom.secondHandWidth
        }
    }

    // MARK: - 叠加文字颜色

    var textPrimaryColor: Color {
        switch self {
        case .classic: return Color(red: 0.18, green: 0.18, blue: 0.20)
        case .midnight: return Color(red: 0.878, green: 0.878, blue: 0.878)
        case .luxe: return Color(red: 0.910, green: 0.835, blue: 0.639)
        case .gufeng: return Color(red: 0.250, green: 0.180, blue: 0.130)
        case .railgun: return Color(red: 0.500, green: 0.350, blue: 0.300)
        case .sky: return Color(red: 0.180, green: 0.340, blue: 0.520)
        case .custom: return custom.textPrimaryColor.swiftUIColor
        }
    }

    var textSecondaryColor: Color {
        switch self {
        case .classic: return Color(red: 0.45, green: 0.45, blue: 0.48)
        case .midnight: return Color(red: 0.533, green: 0.600, blue: 0.667)
        case .luxe: return Color(red: 0.600, green: 0.533, blue: 0.400)
        case .gufeng: return Color(red: 0.500, green: 0.380, blue: 0.280)
        case .railgun: return Color(red: 0.680, green: 0.560, blue: 0.480)
        case .sky: return Color(red: 0.380, green: 0.520, blue: 0.660)
        case .custom: return custom.textSecondaryColor.swiftUIColor
        }
    }

    // MARK: - 下拉面板颜色

    var dropdownBgColor: Color {
        switch self {
        case .classic: return Color(red: 0.94, green: 0.94, blue: 0.95)
        case .midnight: return Color(red: 0.133, green: 0.184, blue: 0.247)
        case .luxe: return Color(red: 0.125, green: 0.125, blue: 0.200)
        case .gufeng: return Color(red: 0.910, green: 0.878, blue: 0.812)
        case .railgun: return Color(red: 0.925, green: 0.906, blue: 0.875)
        case .sky: return Color(red: 0.600, green: 0.780, blue: 0.920)
        case .custom: return custom.dropdownBgColor.swiftUIColor
        }
    }

    var dropdownHeaderColor: Color {
        switch self {
        case .classic: return Color(red: 0.55, green: 0.55, blue: 0.58)
        case .midnight: return Color(red: 0.533, green: 0.600, blue: 0.667)
        case .luxe: return Color(red: 0.667, green: 0.567, blue: 0.400)
        case .gufeng: return Color(red: 0.450, green: 0.320, blue: 0.220)
        case .railgun: return Color(red: 0.620, green: 0.470, blue: 0.380)
        case .sky: return Color(red: 0.300, green: 0.480, blue: 0.660)
        case .custom: return custom.dropdownSubtextColor.swiftUIColor
        }
    }

    var dropdownTextColor: Color {
        switch self {
        case .classic: return Color(red: 0.18, green: 0.18, blue: 0.20)
        case .midnight: return Color(red: 0.878, green: 0.878, blue: 0.878)
        case .luxe: return Color(red: 0.910, green: 0.835, blue: 0.639)
        case .gufeng: return Color(red: 0.280, green: 0.200, blue: 0.150)
        case .railgun: return Color(red: 0.500, green: 0.350, blue: 0.300)
        case .sky: return Color(red: 0.180, green: 0.340, blue: 0.520)
        case .custom: return custom.dropdownTextColor.swiftUIColor
        }
    }

    var dropdownSubtextColor: Color {
        switch self {
        case .classic: return Color(red: 0.45, green: 0.45, blue: 0.48)
        case .midnight: return Color(red: 0.533, green: 0.600, blue: 0.667)
        case .luxe: return Color(red: 0.600, green: 0.533, blue: 0.400)
        case .gufeng: return Color(red: 0.520, green: 0.400, blue: 0.300)
        case .railgun: return Color(red: 0.680, green: 0.560, blue: 0.480)
        case .sky: return Color(red: 0.380, green: 0.520, blue: 0.660)
        case .custom: return custom.dropdownSubtextColor.swiftUIColor
        }
    }

    var dropdownBorderColor: Color {
        switch self {
        case .classic: return Color(white: 0.82)
        case .midnight: return Color(red: 0.200, green: 0.290, blue: 0.400)
        case .luxe: return Color(red: 0.250, green: 0.220, blue: 0.150)
        case .gufeng: return Color(red: 0.650, green: 0.480, blue: 0.320)
        case .railgun: return Color(red: 0.780, green: 0.680, blue: 0.600)
        case .sky: return Color(red: 0.500, green: 0.680, blue: 0.840)
        case .custom: return custom.dropdownBorderColor.swiftUIColor
        }
    }

    var dropdownDividerColor: Color {
        switch self {
        case .classic: return Color(white: 0.85)
        case .midnight: return Color(red: 0.220, green: 0.310, blue: 0.420)
        case .luxe: return Color(red: 0.280, green: 0.240, blue: 0.160)
        case .gufeng: return Color(red: 0.700, green: 0.540, blue: 0.380)
        case .railgun: return Color(red: 0.820, green: 0.730, blue: 0.660)
        case .sky: return Color(red: 0.650, green: 0.780, blue: 0.900)
        case .custom: return custom.dropdownDividerColor.swiftUIColor
        }
    }
}
