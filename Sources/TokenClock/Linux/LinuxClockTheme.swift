import Foundation

struct LinuxColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let clear = LinuxColor(0, 0, 0, 0)
}

/// Linux normal 的内置主题镜像。数值与 macOS normal 的 `ClockFaceTheme` 保持一致；
/// 自定义主题是编辑器生成的数据，并非固定表盘，因此不列入内置主题菜单。
enum LinuxClockTheme: String, CaseIterable, Sendable {
    case glass
    case classic
    case glacier
    case midnight
    case luxe
    case gufeng
    case railgun
    case sky
    case custom

    enum HandStyle: Sendable { case round, tapered, lance, sword }
    enum NumberStyle: Sendable { case arabic, chinese }

    static let builtInCases: [LinuxClockTheme] = [
        .glass, .classic, .glacier, .midnight, .luxe, .gufeng, .railgun, .sky,
    ]

    private var custom: LinuxCustomThemeConfig { LinuxCustomThemeStore.shared.config }

    var displayName: String { L10n.shared.tr("themeName.\(rawValue)") }

    var dialColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.91, 0.93, 0.96)
        case .classic: return LinuxColor(0.97, 0.97, 0.98)
        case .glacier: return LinuxColor(0.96, 0.96, 0.96)
        case .midnight: return LinuxColor(0.106, 0.157, 0.220)
        case .luxe: return LinuxColor(0.102, 0.102, 0.180)
        case .gufeng: return LinuxColor(0.925, 0.886, 0.812)
        case .railgun: return LinuxColor(0.918, 0.898, 0.855)
        case .sky: return LinuxColor(0.529, 0.745, 0.922)
        case .custom: return custom.dialColor.linuxColor
        }
    }

    var dialRimColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.85, 0.85, 0.85)
        case .classic: return LinuxColor(0.82, 0.82, 0.82)
        case .glacier: return .clear
        case .midnight: return LinuxColor(0.165, 0.247, 0.373)
        case .luxe: return LinuxColor(0.176, 0.176, 0.267)
        case .gufeng: return LinuxColor(0.580, 0.400, 0.247)
        case .railgun: return LinuxColor(0.620, 0.470, 0.380)
        case .sky: return LinuxColor(0.420, 0.620, 0.820)
        case .custom: return custom.dialRimColor.linuxColor
        }
    }

    var dialRimWidth: Double {
        switch self {
        case .glass: return 1.5
        case .classic: return 6
        case .glacier: return 0
        case .midnight: return 2.5
        case .luxe: return 2
        case .gufeng: return 3
        case .railgun, .sky: return 2.5
        case .custom: return custom.dialRimWidth
        }
    }

    var hasDialDecoration: Bool { self == .sky || (self == .custom && custom.hasDialDecoration) }

    var hourHandColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.16, 0.16, 0.18)
        case .classic: return LinuxColor(0.718, 0.110, 0.110)
        case .glacier: return LinuxColor(0.18, 0.18, 0.18)
        case .midnight: return LinuxColor(0.149, 0.776, 0.855)
        case .luxe: return LinuxColor(1.0, 0.835, 0.310)
        case .gufeng: return LinuxColor(0.200, 0.180, 0.160)
        case .railgun: return LinuxColor(0.820, 0.580, 0.560)
        case .sky: return LinuxColor(0.960, 0.878, 0.400)
        case .custom: return custom.hourHandColor.linuxColor
        }
    }

    var minuteHandColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.16, 0.16, 0.18)
        case .classic: return LinuxColor(0.898, 0.224, 0.208)
        case .glacier: return LinuxColor(0.35, 0.35, 0.35)
        case .midnight: return LinuxColor(0.502, 0.871, 0.918)
        case .luxe: return LinuxColor(1.0, 0.718, 0.302)
        case .gufeng: return LinuxColor(0.350, 0.280, 0.220)
        case .railgun: return LinuxColor(0.850, 0.650, 0.600)
        case .sky: return LinuxColor(0.980, 0.910, 0.520)
        case .custom: return custom.minuteHandColor.linuxColor
        }
    }

    var secondHandColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.90, 0.42, 0.18)
        case .classic: return LinuxColor(1.0, 0.322, 0.322)
        case .glacier: return LinuxColor(0.95, 0.40, 0.55)
        case .midnight: return LinuxColor(1, 1, 1)
        case .luxe: return LinuxColor(0.941, 0.384, 0.573)
        case .gufeng: return LinuxColor(0.722, 0.184, 0.184)
        case .railgun: return LinuxColor(0.400, 0.620, 0.950)
        case .sky: return LinuxColor(1.0, 0.580, 0.200)
        case .custom: return custom.secondHandColor.linuxColor
        }
    }

    var handStyle: HandStyle {
        switch self {
        case .glass, .classic: return .round
        case .midnight, .railgun, .sky: return .tapered
        case .luxe: return .lance
        case .glacier, .gufeng: return .sword
        case .custom:
            switch custom.handStyleRaw {
            case "tapered": return .tapered
            case "lance": return .lance
            case "sword": return .sword
            default: return .round
            }
        }
    }

    var centerDotOuterColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.16, 0.16, 0.18)
        case .classic: return LinuxColor(0.82, 0.82, 0.82)
        case .glacier: return LinuxColor(0.18, 0.18, 0.18)
        case .midnight: return LinuxColor(0.149, 0.776, 0.855)
        case .luxe: return LinuxColor(1.0, 0.835, 0.310)
        case .gufeng: return LinuxColor(0.580, 0.400, 0.247)
        case .railgun: return LinuxColor(0.820, 0.580, 0.560)
        case .sky: return LinuxColor(0.960, 0.878, 0.400)
        case .custom: return custom.centerDotOuterColor.linuxColor
        }
    }

    var centerDotInnerColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.90, 0.42, 0.18)
        case .classic: return LinuxColor(0.898, 0.224, 0.208)
        case .glacier: return LinuxColor(0.95, 0.40, 0.55)
        case .midnight: return LinuxColor(1, 1, 1)
        case .luxe: return LinuxColor(0.102, 0.102, 0.180)
        case .gufeng: return LinuxColor(0.722, 0.184, 0.184)
        case .railgun: return LinuxColor(0.400, 0.620, 0.950)
        case .sky: return LinuxColor(1.0, 0.580, 0.200)
        case .custom: return custom.centerDotInnerColor.linuxColor
        }
    }

    var tickMarkColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(1, 1, 1, 0.7)
        case .classic: return .clear
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.55)
        case .midnight: return LinuxColor(0.290, 0.396, 0.502)
        case .luxe: return LinuxColor(0.400, 0.333, 0.200)
        case .gufeng: return LinuxColor(0.650, 0.500, 0.350)
        case .railgun: return LinuxColor(0.750, 0.650, 0.580)
        case .sky: return LinuxColor(0.620, 0.780, 0.920)
        case .custom: return custom.hasTickMarks ? custom.tickMarkColor.linuxColor : .clear
        }
    }

    var majorTickMarkColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(1, 1, 1)
        case .classic: return .clear
        case .glacier: return LinuxColor(0.10, 0.20, 0.42)
        case .midnight: return LinuxColor(0.502, 0.871, 0.918)
        case .luxe: return LinuxColor(1.0, 0.835, 0.310)
        case .gufeng: return LinuxColor(0.350, 0.220, 0.160)
        case .railgun: return LinuxColor(0.620, 0.470, 0.380)
        case .sky: return LinuxColor(0.960, 0.920, 0.780)
        case .custom: return custom.hasTickMarks ? custom.majorTickMarkColor.linuxColor : .clear
        }
    }

    var numberColor: LinuxColor {
        switch self {
        case .glass, .classic: return .clear
        case .glacier: return LinuxColor(0.10, 0.20, 0.42)
        case .midnight: return LinuxColor(0.400, 0.533, 0.667)
        case .luxe: return LinuxColor(0.667, 0.567, 0.333)
        case .gufeng: return LinuxColor(0.300, 0.200, 0.150)
        case .railgun: return LinuxColor(0.500, 0.350, 0.300)
        case .sky: return LinuxColor(0.220, 0.380, 0.560)
        case .custom: return custom.showNumbers ? custom.numberColor.linuxColor : .clear
        }
    }

    var numberStyle: NumberStyle {
        self == .gufeng || (self == .custom && custom.numberStyleRaw == "chinese")
            ? .chinese : .arabic
    }

    var numberFontFamily: String {
        switch self {
        case .gufeng: return "Noto Serif CJK SC, Serif"
        case .railgun: return "Monospace"
        case .custom:
            switch custom.numberFontDesignRaw {
            case "serif": return "Noto Serif CJK SC, Serif"
            case "monospaced": return "Monospace"
            default: return "Sans"
            }
        default: return "Sans"
        }
    }

    var hourHandWidth: Double {
        switch self {
        case .glass, .classic: return 4.5
        case .glacier: return 4
        case .midnight, .railgun: return 5.5
        case .luxe: return 6
        case .gufeng, .sky: return 5
        case .custom: return custom.hourHandWidth
        }
    }

    var minuteHandWidth: Double {
        switch self {
        case .glass, .classic: return 3
        case .glacier: return 2.8
        case .luxe: return 4.5
        case .midnight, .gufeng, .railgun, .sky: return 3.5
        case .custom: return custom.minuteHandWidth
        }
    }

    var secondHandWidth: Double {
        switch self {
        case .glass, .classic, .gufeng, .sky: return 1.5
        case .glacier, .midnight: return 1.2
        case .luxe: return 1
        case .railgun: return 1.8
        case .custom: return custom.secondHandWidth
        }
    }

    var hourHandLength: Double { self == .custom ? custom.hourHandLength : 0.48 }
    var minuteHandLength: Double { self == .custom ? custom.minuteHandLength : 0.68 }
    var secondHandLength: Double { self == .custom ? custom.secondHandLength : 0.78 }

    var textPrimaryColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(1, 1, 1)
        case .classic: return LinuxColor(0.18, 0.18, 0.20)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42)
        case .midnight: return LinuxColor(0.878, 0.878, 0.878)
        case .luxe: return LinuxColor(0.910, 0.835, 0.639)
        case .gufeng: return LinuxColor(0.250, 0.180, 0.130)
        case .railgun: return LinuxColor(0.500, 0.350, 0.300)
        case .sky: return LinuxColor(0.180, 0.340, 0.520)
        case .custom: return custom.textPrimaryColor.linuxColor
        }
    }

    var textSecondaryColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(1, 1, 1, 0.8)
        case .classic: return LinuxColor(0.45, 0.45, 0.48)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.7)
        case .midnight: return LinuxColor(0.533, 0.600, 0.667)
        case .luxe: return LinuxColor(0.600, 0.533, 0.400)
        case .gufeng: return LinuxColor(0.500, 0.380, 0.280)
        case .railgun: return LinuxColor(0.680, 0.560, 0.480)
        case .sky: return LinuxColor(0.380, 0.520, 0.660)
        case .custom: return custom.textSecondaryColor.linuxColor
        }
    }

    var dropdownBackgroundColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.93, 0.95, 0.97)
        case .classic: return LinuxColor(0.94, 0.94, 0.95)
        case .glacier: return LinuxColor(0.94, 0.97, 1.00)
        case .midnight: return LinuxColor(0.133, 0.184, 0.247)
        case .luxe: return LinuxColor(0.125, 0.125, 0.200)
        case .gufeng: return LinuxColor(0.910, 0.878, 0.812)
        case .railgun: return LinuxColor(0.925, 0.906, 0.875)
        case .sky: return LinuxColor(0.600, 0.780, 0.920)
        case .custom: return custom.dropdownBgColor.linuxColor
        }
    }

    var dropdownHeaderColor: LinuxColor {
        switch self {
        case .glass: return LinuxColor(0.55, 0.55, 0.58)
        case .classic: return LinuxColor(0.55, 0.55, 0.58)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.7)
        case .midnight: return LinuxColor(0.533, 0.600, 0.667)
        case .luxe: return LinuxColor(0.667, 0.567, 0.400)
        case .gufeng: return LinuxColor(0.450, 0.320, 0.220)
        case .railgun: return LinuxColor(0.620, 0.470, 0.380)
        case .sky: return LinuxColor(0.300, 0.480, 0.660)
        case .custom: return custom.dropdownSubtextColor.linuxColor
        }
    }

    var dropdownTextColor: LinuxColor {
        switch self {
        case .glass, .classic: return LinuxColor(0.18, 0.18, 0.20)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42)
        case .midnight: return LinuxColor(0.878, 0.878, 0.878)
        case .luxe: return LinuxColor(0.910, 0.835, 0.639)
        case .gufeng: return LinuxColor(0.280, 0.200, 0.150)
        case .railgun: return LinuxColor(0.500, 0.350, 0.300)
        case .sky: return LinuxColor(0.180, 0.340, 0.520)
        case .custom: return custom.dropdownTextColor.linuxColor
        }
    }

    var dropdownSubtextColor: LinuxColor {
        switch self {
        case .glass, .classic: return LinuxColor(0.45, 0.45, 0.48)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.7)
        case .midnight: return LinuxColor(0.533, 0.600, 0.667)
        case .luxe: return LinuxColor(0.600, 0.533, 0.400)
        case .gufeng: return LinuxColor(0.520, 0.400, 0.300)
        case .railgun: return LinuxColor(0.680, 0.560, 0.480)
        case .sky: return LinuxColor(0.380, 0.520, 0.660)
        case .custom: return custom.dropdownSubtextColor.linuxColor
        }
    }

    var dropdownBorderColor: LinuxColor {
        switch self {
        case .glass, .classic: return LinuxColor(0.82, 0.82, 0.82)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.18)
        case .midnight: return LinuxColor(0.200, 0.290, 0.400)
        case .luxe: return LinuxColor(0.250, 0.220, 0.150)
        case .gufeng: return LinuxColor(0.650, 0.480, 0.320)
        case .railgun: return LinuxColor(0.780, 0.680, 0.600)
        case .sky: return LinuxColor(0.500, 0.680, 0.840)
        case .custom: return custom.dropdownBorderColor.linuxColor
        }
    }

    var dropdownDividerColor: LinuxColor {
        switch self {
        case .glass, .classic: return LinuxColor(0.85, 0.85, 0.85)
        case .glacier: return LinuxColor(0.10, 0.20, 0.42, 0.18)
        case .midnight: return LinuxColor(0.220, 0.310, 0.420)
        case .luxe: return LinuxColor(0.280, 0.240, 0.160)
        case .gufeng: return LinuxColor(0.700, 0.540, 0.380)
        case .railgun: return LinuxColor(0.820, 0.730, 0.660)
        case .sky: return LinuxColor(0.650, 0.780, 0.900)
        case .custom: return custom.dropdownDividerColor.linuxColor
        }
    }
}

enum LinuxClockSize: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    var diameter: Int {
        switch self {
        case .small: return 200
        case .medium: return 240
        case .large: return 300
        case .extraLarge: return 360
        }
    }

    var scale: Double { Double(diameter) / 240 }

    var displayName: String {
        switch self {
        case .small: return L10n.shared.tr("size.small")
        case .medium: return L10n.shared.tr("size.medium")
        case .large: return L10n.shared.tr("size.large")
        case .extraLarge: return L10n.shared.tr("size.extraLarge")
        }
    }
}
