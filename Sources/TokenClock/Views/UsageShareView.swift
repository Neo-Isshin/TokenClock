#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageShareWindowView: View {
    private enum Mode: Int { case recent, month, week }
    @State private var mode: Mode = .recent
    @State private var anchor: Date
    @State private var recentDays: Int
    @State private var weekIndex = 1
    @State private var style: UsageShareStyle = .ink
    @State private var includesCacheRead = false
    @State private var showsCalendar = false
    let onDone: () -> Void

    init(initialDate: Date, onDone: @escaping () -> Void) {
        let day = min(initialDate, Date())
        _anchor = State(initialValue: day)
        _recentDays = State(initialValue: Calendar.current.isDateInToday(day) ? 7 : 1)
        self.onDone = onDone
    }

    private var period: UsageSharePeriod {
        switch mode {
        case .recent: return .recent(days: recentDays, ending: anchor)
        case .month: return .month(containing: anchor)
        case .week: return .weekOfMonth(containing: anchor, index: weekIndex)
        }
    }
    private var data: UsageShareData {
        UsageShareBuilder.load(period: period, includingCacheRead: includesCacheRead)
    }
    private var weekCount: Int {
        let count = UsageSharePeriod.month(containing: anchor).weekCount
        if Calendar.current.isDate(anchor, equalTo: Date(), toGranularity: .month) {
            let today = Calendar.current.startOfDay(for: Date())
            return (1...count).last {
                UsageSharePeriod.weekOfMonth(containing: anchor, index: $0).bounds.start <= today
            } ?? 1
        }
        return count
    }
    private var canMoveForward: Bool {
        if mode == .recent { return !Calendar.current.isDateInToday(anchor) }
        return !Calendar.current.isDate(anchor, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.shared.tr("share.title")).font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("share.rangeHint")).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDone) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            Picker("", selection: $mode) {
                Text(L10n.shared.tr("share.period.recent")).tag(Mode.recent)
                Text(L10n.shared.tr("share.period.month")).tag(Mode.month)
                Text(L10n.shared.tr("share.period.week")).tag(Mode.week)
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 7) {
                if mode == .recent {
                    Stepper(value: $recentDays, in: 1...90) {
                        Text(recentDays == 1 ? L10n.shared.tr("share.oneDay") : L10n.shared.tr("share.daysCount", recentDays))
                            .font(.system(size: 11, weight: .semibold)).frame(width: 66, alignment: .leading)
                    }.frame(width: 115)
                }
                Button { moveAnchor(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(Text(L10n.shared.tr("share.previousPeriod")))
                Text(anchorLabel).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(minWidth: 74)
                Button { moveAnchor(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!canMoveForward)
                    .accessibilityLabel(Text(L10n.shared.tr("share.nextPeriod")))
                Button { showsCalendar.toggle() } label: { Image(systemName: "calendar") }
                    .help(L10n.shared.tr("share.chooseDate"))
                    .popover(isPresented: $showsCalendar) {
                        DatePicker("", selection: $anchor, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(12)
                    }
                if mode == .week {
                    Picker("", selection: $weekIndex) {
                        ForEach(1...weekCount, id: \.self) { index in
                            Text(L10n.shared.tr("share.weekNumber", index)).tag(index)
                        }
                    }.labelsHidden().frame(width: 100)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .onChange(of: anchor) { _ in weekIndex = min(weekIndex, weekCount) }
            .onChange(of: mode) { _ in
                if mode == .week {
                    let day = Calendar.current.startOfDay(for: anchor)
                    weekIndex = (1...weekCount).first {
                        let bounds = UsageSharePeriod.weekOfMonth(containing: anchor, index: $0).bounds
                        return bounds.start <= day && day <= bounds.end
                    } ?? 1
                } else { weekIndex = min(weekIndex, weekCount) }
            }

            HStack(spacing: 8) {
                Text(rangeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Toggle(L10n.shared.tr("share.includeCache"), isOn: $includesCacheRead)
                    .font(.system(size: 10, weight: .medium))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            UsageShareCardView(data: data, style: style, scale: 0.60)
                .frame(width: 360, height: 450)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.17), radius: 10, y: 4)

            HStack(spacing: 8) {
                Text(L10n.shared.tr("share.style")).font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(UsageShareStyle.allCases) { choice in
                    Button(L10n.shared.tr(choice.titleKey)) { style = choice }
                        .buttonStyle(.bordered).tint(style == choice ? .accentColor : .gray)
                }
                Spacer()
            }.controlSize(.small)
            HStack(spacing: 8) {
                Button { copyImage() } label: {
                    Label(L10n.shared.tr("share.copyImage"), systemImage: "doc.on.doc")
                }
                Button { savePNG() } label: {
                    Label(L10n.shared.tr("share.savePNG"), systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button { shareImage() } label: {
                    Label(L10n.shared.tr("share.share"), systemImage: "square.and.arrow.up")
                }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }
        .padding(18).frame(width: 470, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func moveAnchor(_ direction: Int) {
        let component: Calendar.Component = mode == .recent ? .day : .month
        guard let next = Calendar.current.date(byAdding: component, value: direction, to: anchor) else { return }
        anchor = min(next, Date())
        weekIndex = min(weekIndex, weekCount)
    }
    private var anchorLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateFormat = mode == .recent ? "MMM d, yyyy" : "MMM yyyy"
        return formatter.string(from: anchor)
    }
    private var rangeLabel: String {
        let bounds = period.bounds
        return "\(DateFormatter.localizedString(from: bounds.start, dateStyle: .medium, timeStyle: .none)) — \(DateFormatter.localizedString(from: bounds.end, dateStyle: .medium, timeStyle: .none))"
    }
    private func renderedImage() -> NSImage? { UsageShareImageRenderer.image(for: data, style: style) }
    private func copyImage() {
        guard let image = renderedImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    private func savePNG() {
        guard let png = renderedImage()?.pngData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TokenClock-\(data.dateKey)-\(data.endDateKey).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url, options: .atomic)
    }
    private func shareImage() {
        guard let image = renderedImage(), let view = NSApp.keyWindow?.contentView else { return }
        UsageShareImageRenderer.showSharingPicker(image: image, from: view)
    }
}

@MainActor
enum UsageShareImageRenderer {
    private static var sharingPicker: NSSharingServicePicker?
    static func image(for data: UsageShareData, style: UsageShareStyle = .ink) -> NSImage? {
        let size = NSSize(width: 1_200, height: 1_500)
        let view = NSHostingView(rootView: UsageShareCardView(data: data, style: style, scale: 2))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_200, pixelsHigh: 1_500,
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
