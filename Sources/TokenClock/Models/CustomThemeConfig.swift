import SwiftUI

/// 用户自定义表盘配置
struct CustomThemeConfig: Codable, Equatable {
    var dialColor: CodableColor = CodableColor(red: 0.97, green: 0.97, blue: 0.98)
    var dialRimColor: CodableColor = CodableColor(red: 0.82, green: 0.82, blue: 0.82)
    var dialRimWidth: CGFloat = 6

    /// 玻璃盘体着色（nil = 纯净玻璃）。可选字段：旧配置缺失时解码为 nil。
    var glassTint: CodableColor? = nil

    var hourHandColor: CodableColor = CodableColor(red: 0.718, green: 0.110, blue: 0.110)
    var minuteHandColor: CodableColor = CodableColor(red: 0.898, green: 0.224, blue: 0.208)
    var secondHandColor: CodableColor = CodableColor(red: 1.0, green: 0.322, blue: 0.322)

    var hourHandWidth: CGFloat = 4.5
    var minuteHandWidth: CGFloat = 3.0
    var secondHandWidth: CGFloat = 1.5
    var hourHandLength: CGFloat = 0.48
    var minuteHandLength: CGFloat = 0.68
    var secondHandLength: CGFloat = 0.78

    var handStyleRaw: String = "round" // round, tapered, lance, sword

    var centerDotOuterColor: CodableColor = CodableColor(red: 0.82, green: 0.82, blue: 0.82)
    var centerDotInnerColor: CodableColor = CodableColor(red: 0.898, green: 0.224, blue: 0.208)

    var numberColor: CodableColor = CodableColor(red: 0.0, green: 0.0, blue: 0.0, opacity: 0)
    var tickMarkColor: CodableColor = CodableColor(red: 0.0, green: 0.0, blue: 0.0, opacity: 0)
    var majorTickMarkColor: CodableColor = CodableColor(red: 0.0, green: 0.0, blue: 0.0, opacity: 0)

    var dropdownBgColor: CodableColor = CodableColor(red: 0.94, green: 0.94, blue: 0.95)
    var dropdownTextColor: CodableColor = CodableColor(red: 0.18, green: 0.18, blue: 0.20)
    var dropdownSubtextColor: CodableColor = CodableColor(red: 0.45, green: 0.45, blue: 0.48)
    var dropdownBorderColor: CodableColor = CodableColor(red: 0.82, green: 0.82, blue: 0.82)
    var dropdownDividerColor: CodableColor = CodableColor(red: 0.85, green: 0.85, blue: 0.85)

    var textPrimaryColor: CodableColor = CodableColor(red: 0.18, green: 0.18, blue: 0.20)
    var textSecondaryColor: CodableColor = CodableColor(red: 0.45, green: 0.45, blue: 0.48)

    var showNumbers: Bool = true
    var hasTickMarks: Bool = true
    var hasDialDecoration: Bool = false

    var numberStyleRaw: String = "arabic" // arabic, chinese
    var numberFontDesignRaw: String = "rounded" // rounded, serif, monospaced, default

    var handStyle: ClockFaceTheme.HandStyle {
        switch handStyleRaw {
        case "tapered": return .tapered
        case "lance": return .lance
        case "sword": return .sword
        default: return .round
        }
    }

    var numberStyle: ClockFaceTheme.NumberStyle {
        numberStyleRaw == "chinese" ? .chinese : .arabic
    }

    var numberFontDesign: Font.Design {
        switch numberFontDesignRaw {
        case "serif": return .serif
        case "monospaced": return .monospaced
        case "default": return .default
        default: return .rounded
        }
    }
}

/// 可编码的 Color 包装
struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue).opacity(opacity)
    }

    init(color: Color) {
        let nsColor = NSColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
    }
}

/// 已保存的自定义主题
struct SavedCustomTheme: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var config: CustomThemeConfig

    init(id: UUID = UUID(), name: String, config: CustomThemeConfig) {
        self.id = id
        self.name = name
        self.config = config
    }
}

extension SavedCustomTheme {
    static var userDefaultsKey: String { SettingsKey.savedCustomThemes.rawValue }

    static func loadAll() -> [SavedCustomTheme] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let themes = try? JSONDecoder().decode([SavedCustomTheme].self, from: data) else {
            return []
        }
        return themes
    }

    static func saveAll(_ themes: [SavedCustomTheme]) {
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

extension CustomThemeConfig {
    static var userDefaultsKey: String { SettingsKey.customThemeConfig.rawValue }

    static func load() -> CustomThemeConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(CustomThemeConfig.self, from: data) else {
            return CustomThemeConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
