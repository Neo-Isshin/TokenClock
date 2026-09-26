import AppKit
import SwiftUI

/// Original-color bitmap rendering is independent of the panel's Text Color setting.
@MainActor
struct BrandIconView: View {
    let name: String
    let fallback: String
    var size: CGFloat = 16
    @AppStorage(BrandIconStyle.defaultsKey) private var iconStyle = BrandIconStyle.official.rawValue
    private static var images: [String: NSImage] = [:]

    private var image: NSImage? {
        guard BrandIconStyle.resolved(iconStyle) == .official else { return nil }
        guard let key = BrandIconCatalog.key(for: name) else { return nil }
        if let cached = Self.images[key] { return cached }
        guard let url = BrandIconCatalog.url(forKey: key), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        Self.images[key] = image
        return image
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(BrandIconCatalog.monochromeKeys.contains(BrandIconCatalog.key(for: name) ?? "") ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
            } else {
                Text(fallback).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BrandTooltipText: View {
    let label: String
    var iconSize: CGFloat = 12
    @AppStorage(BrandIconStyle.defaultsKey) private var iconStyle = BrandIconStyle.official.rawValue

    var body: some View {
        let lines = label.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 2) {
            if BrandIconStyle.resolved(iconStyle) == .official, let first = lines.first, let parts = BrandIconCatalog.labelParts(first) {
                HStack(spacing: 4) {
                    BrandIconView(name: parts.text, fallback: "", size: iconSize)
                    Text(parts.text)
                }
            } else if let first = lines.first { Text(first) }
            if lines.count > 1 { Text(lines.dropFirst().joined(separator: "\n")) }
        }
    }
}
