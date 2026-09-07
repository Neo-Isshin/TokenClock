#if os(macOS)
import AppKit
import SwiftUI

@MainActor
private enum TokenClockIconImageCache {
    static var images: [TokenClockIcon: NSImage] = [:]

    static func image(for icon: TokenClockIcon) -> NSImage? {
        if let image = images[icon] { return image }
        let url = Bundle.module.url(
            forResource: icon.resourceName,
            withExtension: "svg",
            subdirectory: "TokenClockIcons"
        ) ?? Bundle.module.url(forResource: icon.resourceName, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        images[icon] = image
        return image
    }
}

/// Displays a TokenClock-owned SVG when the name has a custom glyph and falls
/// back to the provider's existing emoji everywhere else.
struct TokenClockIconView: View {
    let displayName: String
    let fallbackEmoji: String
    let size: CGFloat

    var body: some View {
        if let icon = TokenClockIcon.resolve(displayName: displayName),
           let image = TokenClockIconImageCache.image(for: icon) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(fallbackEmoji)
                .font(.system(size: size))
                .offset(y: ["🅉", "🄺", "ℤ"].contains(fallbackEmoji) ? -1.25 : 0)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
#endif
