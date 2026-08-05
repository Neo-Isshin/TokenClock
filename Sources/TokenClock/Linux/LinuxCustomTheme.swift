import Foundation

struct LinuxThemeColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double = 1

    var linuxColor: LinuxColor { LinuxColor(red, green, blue, opacity) }
}

/// JSON-compatible mirror of macOS normal's `CustomThemeConfig`.
struct LinuxCustomThemeConfig: Codable, Equatable, Sendable {
    var dialColor = LinuxThemeColor(red: 0.97, green: 0.97, blue: 0.98)
    var dialRimColor = LinuxThemeColor(red: 0.82, green: 0.82, blue: 0.82)
    var dialRimWidth = 6.0
    var hourHandColor = LinuxThemeColor(red: 0.718, green: 0.110, blue: 0.110)
    var minuteHandColor = LinuxThemeColor(red: 0.898, green: 0.224, blue: 0.208)
    var secondHandColor = LinuxThemeColor(red: 1, green: 0.322, blue: 0.322)
    var hourHandWidth = 4.5
    var minuteHandWidth = 3.0
    var secondHandWidth = 1.5
    var hourHandLength = 0.48
    var minuteHandLength = 0.68
    var secondHandLength = 0.78
    var handStyleRaw = "round"
    var centerDotOuterColor = LinuxThemeColor(red: 0.82, green: 0.82, blue: 0.82)
    var centerDotInnerColor = LinuxThemeColor(red: 0.898, green: 0.224, blue: 0.208)
    var numberColor = LinuxThemeColor(red: 0, green: 0, blue: 0, opacity: 0)
    var tickMarkColor = LinuxThemeColor(red: 0, green: 0, blue: 0, opacity: 0)
    var majorTickMarkColor = LinuxThemeColor(red: 0, green: 0, blue: 0, opacity: 0)
    var dropdownBgColor = LinuxThemeColor(red: 0.94, green: 0.94, blue: 0.95)
    var dropdownTextColor = LinuxThemeColor(red: 0.18, green: 0.18, blue: 0.20)
    var dropdownSubtextColor = LinuxThemeColor(red: 0.45, green: 0.45, blue: 0.48)
    var dropdownBorderColor = LinuxThemeColor(red: 0.82, green: 0.82, blue: 0.82)
    var dropdownDividerColor = LinuxThemeColor(red: 0.85, green: 0.85, blue: 0.85)
    var textPrimaryColor = LinuxThemeColor(red: 0.18, green: 0.18, blue: 0.20)
    var textSecondaryColor = LinuxThemeColor(red: 0.45, green: 0.45, blue: 0.48)
    var showNumbers = true
    var hasTickMarks = true
    var hasDialDecoration = false
    var numberStyleRaw = "arabic"
    var numberFontDesignRaw = "rounded"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dialColor, dialRimColor, dialRimWidth
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LinuxCustomThemeConfig()
        dialColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dialColor) ?? defaults.dialColor
        dialRimColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dialRimColor) ?? defaults.dialRimColor
        dialRimWidth = try values.decodeIfPresent(Double.self, forKey: .dialRimWidth) ?? defaults.dialRimWidth
        hourHandColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .hourHandColor) ?? defaults.hourHandColor
        minuteHandColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .minuteHandColor) ?? defaults.minuteHandColor
        secondHandColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .secondHandColor) ?? defaults.secondHandColor
        hourHandWidth = try values.decodeIfPresent(Double.self, forKey: .hourHandWidth) ?? defaults.hourHandWidth
        minuteHandWidth = try values.decodeIfPresent(Double.self, forKey: .minuteHandWidth) ?? defaults.minuteHandWidth
        secondHandWidth = try values.decodeIfPresent(Double.self, forKey: .secondHandWidth) ?? defaults.secondHandWidth
        hourHandLength = try values.decodeIfPresent(Double.self, forKey: .hourHandLength) ?? defaults.hourHandLength
        minuteHandLength = try values.decodeIfPresent(Double.self, forKey: .minuteHandLength) ?? defaults.minuteHandLength
        secondHandLength = try values.decodeIfPresent(Double.self, forKey: .secondHandLength) ?? defaults.secondHandLength
        handStyleRaw = try values.decodeIfPresent(String.self, forKey: .handStyleRaw) ?? defaults.handStyleRaw
        centerDotOuterColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .centerDotOuterColor) ?? defaults.centerDotOuterColor
        centerDotInnerColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .centerDotInnerColor) ?? defaults.centerDotInnerColor
        numberColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .numberColor) ?? defaults.numberColor
        tickMarkColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .tickMarkColor) ?? defaults.tickMarkColor
        majorTickMarkColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .majorTickMarkColor) ?? defaults.majorTickMarkColor
        dropdownBgColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dropdownBgColor) ?? defaults.dropdownBgColor
        dropdownTextColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dropdownTextColor) ?? defaults.dropdownTextColor
        dropdownSubtextColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dropdownSubtextColor) ?? defaults.dropdownSubtextColor
        dropdownBorderColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dropdownBorderColor) ?? defaults.dropdownBorderColor
        dropdownDividerColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .dropdownDividerColor) ?? defaults.dropdownDividerColor
        textPrimaryColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .textPrimaryColor) ?? defaults.textPrimaryColor
        textSecondaryColor = try values.decodeIfPresent(LinuxThemeColor.self, forKey: .textSecondaryColor) ?? defaults.textSecondaryColor
        showNumbers = try values.decodeIfPresent(Bool.self, forKey: .showNumbers) ?? defaults.showNumbers
        hasTickMarks = try values.decodeIfPresent(Bool.self, forKey: .hasTickMarks) ?? defaults.hasTickMarks
        hasDialDecoration = try values.decodeIfPresent(Bool.self, forKey: .hasDialDecoration) ?? defaults.hasDialDecoration
        numberStyleRaw = try values.decodeIfPresent(String.self, forKey: .numberStyleRaw) ?? defaults.numberStyleRaw
        numberFontDesignRaw = try values.decodeIfPresent(String.self, forKey: .numberFontDesignRaw) ?? defaults.numberFontDesignRaw
    }
}

struct LinuxSavedCustomTheme: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var config: LinuxCustomThemeConfig
}

final class LinuxCustomThemeStore: @unchecked Sendable {
    static let shared = LinuxCustomThemeStore()
    private let lock = NSLock()
    private var storedConfig: LinuxCustomThemeConfig
    private var storedThemes: [LinuxSavedCustomTheme]

    private init() {
        let defaults = UserDefaults.standard
        storedConfig = defaults.data(forKey: SettingsKey.customThemeConfig.rawValue)
            .flatMap { try? JSONDecoder().decode(LinuxCustomThemeConfig.self, from: $0) }
            ?? LinuxCustomThemeConfig()
        storedThemes = defaults.data(forKey: SettingsKey.savedCustomThemes.rawValue)
            .flatMap { try? JSONDecoder().decode([LinuxSavedCustomTheme].self, from: $0) }
            ?? []
    }

    var config: LinuxCustomThemeConfig {
        lock.lock(); defer { lock.unlock() }
        return storedConfig
    }

    var themes: [LinuxSavedCustomTheme] {
        lock.lock(); defer { lock.unlock() }
        return storedThemes
    }

    @discardableResult
    func save(config: LinuxCustomThemeConfig, name: String) -> LinuxSavedCustomTheme {
        lock.lock()
        storedConfig = config
        let activeID = UserDefaults.standard.string(for: .activeCustomThemeId).flatMap(UUID.init(uuidString:))
        let saved: LinuxSavedCustomTheme
        if let activeID, let index = storedThemes.firstIndex(where: { $0.id == activeID }) {
            storedThemes[index].name = name
            storedThemes[index].config = config
            saved = storedThemes[index]
        } else {
            saved = LinuxSavedCustomTheme(id: UUID(), name: name, config: config)
            storedThemes.append(saved)
        }
        let themes = storedThemes
        lock.unlock()
        persist(config: config, themes: themes, activeID: saved.id)
        return saved
    }

    func apply(id: UUID) -> Bool {
        lock.lock()
        guard let theme = storedThemes.first(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        storedConfig = theme.config
        lock.unlock()
        persist(config: theme.config, themes: themes, activeID: id)
        return true
    }

    func resetDraft() -> LinuxCustomThemeConfig {
        let config = LinuxCustomThemeConfig()
        lock.lock(); storedConfig = config; lock.unlock()
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: SettingsKey.customThemeConfig.rawValue)
        }
        UserDefaults.standard.synchronize()
        return config
    }

    func delete(id: UUID) {
        lock.lock()
        storedThemes.removeAll { $0.id == id }
        let themes = storedThemes
        lock.unlock()
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: SettingsKey.savedCustomThemes.rawValue)
        }
        if UserDefaults.standard.string(for: .activeCustomThemeId) == id.uuidString {
            UserDefaults.standard.remove(.activeCustomThemeId)
        }
        UserDefaults.standard.synchronize()
    }

    private func persist(
        config: LinuxCustomThemeConfig,
        themes: [LinuxSavedCustomTheme],
        activeID: UUID
    ) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(config) {
            UserDefaults.standard.set(data, forKey: SettingsKey.customThemeConfig.rawValue)
        }
        if let data = try? encoder.encode(themes) {
            UserDefaults.standard.set(data, forKey: SettingsKey.savedCustomThemes.rawValue)
        }
        UserDefaults.standard.setString(activeID.uuidString, for: .activeCustomThemeId)
        UserDefaults.standard.synchronize()
    }
}
