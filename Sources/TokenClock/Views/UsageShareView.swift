#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageShareWindowView: View {
    @State private var selectedDate: Date
    let onDone: () -> Void

    init(initialDate: Date, onDone: @escaping () -> Void) {
        _selectedDate = State(initialValue: min(initialDate, Date()))
        self.onDone = onDone
    }

    private var data: UsageShareData { UsageShareBuilder.load(date: selectedDate) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.shared.tr("share.title"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("share.chooseDate"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            UsageShareCardView(data: data, scale: 0.59)
                .frame(width: 354, height: 443)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 12, y: 5)

            HStack(spacing: 9) {
                Button { copyImage() } label: {
                    Label(L10n.shared.tr("share.copyImage"), systemImage: "doc.on.doc")
                }
                Button { savePNG() } label: {
                    Label(L10n.shared.tr("share.savePNG"), systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button { shareImage() } label: {
                    Label(L10n.shared.tr("share.share"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 430, height: 570)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func renderedImage() -> NSImage? {
        UsageShareImageRenderer.image(for: data)
    }

    private func copyImage() {
        guard let image = renderedImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func savePNG() {
        guard let image = renderedImage(), let png = image.pngData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TokenClock-\(data.dateKey).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url, options: .atomic)
    }

    private func shareImage() {
        guard let image = renderedImage(),
              let view = NSApp.keyWindow?.contentView else { return }
        UsageShareImageRenderer.showSharingPicker(image: image, from: view)
    }
}

struct UsageShareCardView: View {
    let data: UsageShareData
    var scale: CGFloat = 1

    private let palette: [Color] = [
        Color(red: 0.34, green: 0.80, blue: 0.98),
        Color(red: 0.56, green: 0.45, blue: 0.98),
        Color(red: 0.98, green: 0.53, blue: 0.62),
        Color(red: 0.31, green: 0.86, blue: 0.65),
        Color(red: 1.00, green: 0.72, blue: 0.32),
        Color(red: 0.42, green: 0.64, blue: 0.98),
        Color(red: 0.72, green: 0.76, blue: 0.86),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.055, blue: 0.12),
                    Color(red: 0.055, green: 0.11, blue: 0.22),
                    Color(red: 0.10, green: 0.08, blue: 0.22),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.cyan.opacity(0.16))
                .frame(width: 360 * scale)
                .blur(radius: 65 * scale)
                .offset(x: 210 * scale, y: -310 * scale)
            Circle()
                .fill(Color.purple.opacity(0.14))
                .frame(width: 320 * scale)
                .blur(radius: 70 * scale)
                .offset(x: -235 * scale, y: 320 * scale)

            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer().frame(height: 34 * scale)
                Text(TokenFormat.compact(data.totalTokens))
                    .font(.system(size: 58 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(-2 * scale)
                Text(L10n.shared.tr("share.tokens"))
                    .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    .tracking(2.4 * scale)
                    .foregroundStyle(Color.white.opacity(0.52))
                Spacer().frame(height: 25 * scale)
                summaryRow
                Spacer().frame(height: 29 * scale)
                Text(L10n.shared.tr("share.toolBreakdown"))
                    .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    .tracking(1.9 * scale)
                    .foregroundStyle(Color.white.opacity(0.50))
                Spacer().frame(height: 13 * scale)
                breakdown
                Spacer(minLength: 18 * scale)
                quote
                Spacer().frame(height: 14 * scale)
                HStack {
                    Text(L10n.shared.tr("share.generatedBy"))
                    Spacer()
                    Text("tokenclock")
                }
                .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.38))
            }
            .padding(38 * scale)
        }
        .frame(width: 600 * scale, height: 750 * scale)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(spacing: 10 * scale) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    Circle().stroke(Color.white.opacity(0.24), lineWidth: 1 * scale)
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 16 * scale, weight: .semibold))
                }
                .frame(width: 38 * scale, height: 38 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("TokenClock")
                        .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("share.dailyUsage"))
                        .font(.system(size: 8.5 * scale, weight: .bold, design: .rounded))
                        .tracking(1.4 * scale)
                        .foregroundStyle(Color.white.opacity(0.48))
                }
            }
            Spacer()
            Text(dateLabel)
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.top, 4 * scale)
        }
        .foregroundStyle(.white)
    }

    private var summaryRow: some View {
        HStack(spacing: 12 * scale) {
            summaryMetric("bubble.left.and.bubble.right.fill", data.messages,
                          L10n.shared.tr("share.messages"), .purple)
            summaryMetric("bolt.horizontal.fill", data.averageCacheRate * 100,
                          L10n.shared.tr("share.cache"), .orange, suffix: "%")
        }
    }

    private func summaryMetric(
        _ symbol: String, _ value: Int, _ label: String, _ tint: Color
    ) -> some View {
        summaryMetric(symbol, Double(value), label, tint)
    }

    private func summaryMetric(
        _ symbol: String, _ value: Double, _ label: String, _ tint: Color,
        suffix: String = ""
    ) -> some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28 * scale, height: 28 * scale)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(suffix.isEmpty ? integer(Int(value)) : String(format: "%.2f%@", value, suffix))
                    .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 8 * scale, weight: .bold, design: .rounded))
                    .tracking(1.2 * scale)
                    .foregroundStyle(Color.white.opacity(0.44))
            }
            Spacer()
        }
        .padding(.horizontal, 15 * scale)
        .frame(maxWidth: .infinity, minHeight: 64 * scale)
        .background(RoundedRectangle(cornerRadius: 15 * scale).fill(Color.white.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 15 * scale)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7 * scale))
    }

    @ViewBuilder
    private var breakdown: some View {
        if data.rows.isEmpty {
            Text(L10n.shared.tr("share.noUsage"))
                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(maxWidth: .infinity, minHeight: 190 * scale)
        } else {
            VStack(spacing: 13 * scale) {
                ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                    VStack(spacing: 6 * scale) {
                        HStack(spacing: 8 * scale) {
                            Text(row.emoji).font(.system(size: 13 * scale))
                            Text(row.name)
                                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.84))
                                .lineLimit(1)
                            Spacer()
                            Text(TokenFormat.compact(row.tokens))
                                .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(palette[index % palette.count])
                                    .frame(width: max(3 * scale, geometry.size.width * row.fraction))
                            }
                        }
                        .frame(height: 5 * scale)
                    }
                }
            }
        }
    }

    private var quote: some View {
        HStack(alignment: .top, spacing: 12 * scale) {
            Text("“")
                .font(.system(size: 34 * scale, weight: .black, design: .serif))
                .foregroundStyle(Color.cyan.opacity(0.75))
                .offset(y: -7 * scale)
            Text(L10n.shared.tr(data.quoteKey))
                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(3 * scale)
            Spacer(minLength: 0)
        }
        .padding(16 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.white.opacity(0.055)))
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateStyle = .long
        return formatter.string(from: data.date)
    }

    private func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

@MainActor
enum UsageShareImageRenderer {
    private static var sharingPicker: NSSharingServicePicker?

    static func image(for data: UsageShareData) -> NSImage? {
        let size = NSSize(width: 1_200, height: 1_500)
        let view = NSHostingView(rootView: UsageShareCardView(data: data, scale: 2))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        representation.size = size
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    static func showSharingPicker(image: NSImage, from view: NSView) {
        let picker = NSSharingServicePicker(items: [image])
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
