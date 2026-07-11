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

    // MARK: - 宽容解码（向后兼容旧 schema）
    // 合成 init(from:) 对缺失键不回退默认 → 任何字段增删都会让旧主题解码失败、静默清空。
    // 这里逐字段 decodeIfPresent ?? 默认：缺失字段回默认实例的值，新增字段不破坏已存主题。
    //
    // 注意：自定义 init(from:) 会让编译器停止合成默认/成员初始化器，故显式补回空 init()
    //（所有属性已有默认值），保持各处 CustomThemeConfig() 调用可用。
    init() {}

    private enum CodingKeys: String, CodingKey {
        case dialColor, dialRimColor, dialRimWidth, glassTint
        case hourHandColor, minuteHandColor, secondHandColor
        case hourHandWidth, minuteHandWidth, secondHandWidth
        case hourHandLength, minuteHandLength, secondHandLength, handStyleRaw
        case centerDotOuterColor, centerDotInnerColor
        case numberColor, tickMarkColor, majorTickMarkColor
        case dropdownBgColor, dropdownTextColor, dropdownSubtextColor, dropdownBorderColor, dropdownDividerColor
        case textPrimaryColor, textSecondaryColor
        case showNumbers, hasTickMarks, hasDialDecoration, numberStyleRaw, numberFontDesignRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CustomThemeConfig()  // 默认实例兜底，避免重复书写全部默认值
        dialColor = try c.decodeIfPresent(CodableColor.self, forKey: .dialColor) ?? d.dialColor
        dialRimColor = try c.decodeIfPresent(CodableColor.self, forKey: .dialRimColor) ?? d.dialRimColor
        dialRimWidth = try c.decodeIfPresent(CGFloat.self, forKey: .dialRimWidth) ?? d.dialRimWidth
        glassTint = try c.decodeIfPresent(CodableColor.self, forKey: .glassTint) ?? d.glassTint
        hourHandColor = try c.decodeIfPresent(CodableColor.self, forKey: .hourHandColor) ?? d.hourHandColor
        minuteHandColor = try c.decodeIfPresent(CodableColor.self, forKey: .minuteHandColor) ?? d.minuteHandColor
        secondHandColor = try c.decodeIfPresent(CodableColor.self, forKey: .secondHandColor) ?? d.secondHandColor
        hourHandWidth = try c.decodeIfPresent(CGFloat.self, forKey: .hourHandWidth) ?? d.hourHandWidth
        minuteHandWidth = try c.decodeIfPresent(CGFloat.self, forKey: .minuteHandWidth) ?? d.minuteHandWidth
        secondHandWidth = try c.decodeIfPresent(CGFloat.self, forKey: .secondHandWidth) ?? d.secondHandWidth
        hourHandLength = try c.decodeIfPresent(CGFloat.self, forKey: .hourHandLength) ?? d.hourHandLength
        minuteHandLength = try c.decodeIfPresent(CGFloat.self, forKey: .minuteHandLength) ?? d.minuteHandLength
        secondHandLength = try c.decodeIfPresent(CGFloat.self, forKey: .secondHandLength) ?? d.secondHandLength
        handStyleRaw = try c.decodeIfPresent(String.self, forKey: .handStyleRaw) ?? d.handStyleRaw
        centerDotOuterColor = try c.decodeIfPresent(CodableColor.self, forKey: .centerDotOuterColor) ?? d.centerDotOuterColor
        centerDotInnerColor = try c.decodeIfPresent(CodableColor.self, forKey: .centerDotInnerColor) ?? d.centerDotInnerColor
        numberColor = try c.decodeIfPresent(CodableColor.self, forKey: .numberColor) ?? d.numberColor
        tickMarkColor = try c.decodeIfPresent(CodableColor.self, forKey: .tickMarkColor) ?? d.tickMarkColor
        majorTickMarkColor = try c.decodeIfPresent(CodableColor.self, forKey: .majorTickMarkColor) ?? d.majorTickMarkColor
        dropdownBgColor = try c.decodeIfPresent(CodableColor.self, forKey: .dropdownBgColor) ?? d.dropdownBgColor
        dropdownTextColor = try c.decodeIfPresent(CodableColor.self, forKey: .dropdownTextColor) ?? d.dropdownTextColor
        dropdownSubtextColor = try c.decodeIfPresent(CodableColor.self, forKey: .dropdownSubtextColor) ?? d.dropdownSubtextColor
        dropdownBorderColor = try c.decodeIfPresent(CodableColor.self, forKey: .dropdownBorderColor) ?? d.dropdownBorderColor
        dropdownDividerColor = try c.decodeIfPresent(CodableColor.self, forKey: .dropdownDividerColor) ?? d.dropdownDividerColor
        textPrimaryColor = try c.decodeIfPresent(CodableColor.self, forKey: .textPrimaryColor) ?? d.textPrimaryColor
        textSecondaryColor = try c.decodeIfPresent(CodableColor.self, forKey: .textSecondaryColor) ?? d.textSecondaryColor
        showNumbers = try c.decodeIfPresent(Bool.self, forKey: .showNumbers) ?? d.showNumbers
        hasTickMarks = try c.decodeIfPresent(Bool.self, forKey: .hasTickMarks) ?? d.hasTickMarks
        hasDialDecoration = try c.decodeIfPresent(Bool.self, forKey: .hasDialDecoration) ?? d.hasDialDecoration
        numberStyleRaw = try c.decodeIfPresent(String.self, forKey: .numberStyleRaw) ?? d.numberStyleRaw
        numberFontDesignRaw = try c.decodeIfPresent(String.self, forKey: .numberFontDesignRaw) ?? d.numberFontDesignRaw
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

    // 宽容解码：单个通道缺失时回默认（不致整对象解码失败）。
    private enum CodingKeys: String, CodingKey { case red, green, blue, opacity }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }
}

extension CodableColor {
    /// 从 NSColor 构造（拾色器回写用）。
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }

    /// 转回 NSColor（sRGB，喂给私有 NSGlassEffectView tintColor）。
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    /// 解析 #RRGGBB / #RRGGBBAA / RRGGBB；失败返回 nil。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }
        if s.count == 8 {
            self.init(red: Double((rgba >> 24) & 0xFF) / 255,
                      green: Double((rgba >> 16) & 0xFF) / 255,
                      blue: Double((rgba >> 8) & 0xFF) / 255,
                      opacity: Double(rgba & 0xFF) / 255)
        } else {
            self.init(red: Double((rgba >> 16) & 0xFF) / 255,
                      green: Double((rgba >> 8) & 0xFF) / 255,
                      blue: Double(rgba & 0xFF) / 255)
        }
    }

    /// 输出 #RRGGBB（菜单 / 拾色器互通；忽略 opacity 通道）。
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()),
               Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([SavedCustomTheme].self, from: data)
        } catch {
            // 不静默清空：打日志便于排查（数据损坏/schema 演进），行为降级为空。
            print("[CustomTheme] saved themes decode failed: \(error)")
            return []
        }
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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return CustomThemeConfig() }
        do {
            return try JSONDecoder().decode(CustomThemeConfig.self, from: data)
        } catch {
            print("[CustomTheme] config decode failed: \(error)")
            return CustomThemeConfig()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
