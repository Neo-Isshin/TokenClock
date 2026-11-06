#if os(macOS)
import SwiftUI
extension SubscriptionProvider {
    var dialQuotaColor: Color {
        let defaults = UserDefaults.standard
        let theme = ClockFaceTheme(rawValue: defaults.string(for: .selectedTheme) ?? "classic") ?? .classic
        let mode = DialTextMode(rawValue: defaults.int(for: .dialTextMode, default: 0)) ?? .theme
        let contrast: Color
        switch mode {
        case .theme: contrast = theme.textPrimaryColor
        case .white: contrast = .white
        case .black: contrast = .black
        case .custom: contrast = CodableColor(hex: defaults.string(for: .dialTextColor) ?? "")?.swiftUIColor ?? theme.textPrimaryColor
        }
        return theme.dialQuotaColor(for: self, contrastColor: contrast)
    }
}
#endif
