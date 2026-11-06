#if os(macOS)
import SwiftUI
import AppKit
import CoreTransferable
import UniformTypeIdentifiers

func toolboxText(_ cn: String, _ en: String) -> String { L10n.shared.language.rawValue.hasPrefix("zh") ? cn : en }

@MainActor
enum InstantHintTextLayout {
    static func label(for text: String, maximumWidth: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        // NSTextField's cell includes text insets that NSString.size omits.
        let naturalWidth = ceil(label.cell?.cellSize.width ?? label.fittingSize.width)
        let width = min(260, max(1, maximumWidth), max(110, naturalWidth))
        label.preferredMaxLayoutWidth = width
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000))
        let height = ceil(measured?.height ?? label.fittingSize.height) + 2
        label.frame = NSRect(x: 10, y: 8, width: width, height: height)
        return label
    }
}

private struct InstantHint: ViewModifier {
    let text: String
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.onHover { hovered = $0 }
            .background(InstantHintAnchor(text: text, isPresented: hovered).allowsHitTesting(false))
            .onDisappear { hovered = false }
    }
}

/// A separate, nonactivating window keeps long hints out of table-column layout
/// and ScrollView clipping. Only one hint can be visible across adjacent rows.
@MainActor private struct InstantHintAnchor: NSViewRepresentable {
    let text: String
    let isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(anchor: view, text: text, isPresented: isPresented)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private static weak var active: Coordinator?
        private var panel: NSPanel?

        func update(anchor: NSView, text: String, isPresented: Bool) {
            guard isPresented, !text.isEmpty, let source = anchor.window, source.isVisible else {
                close()
                return
            }
            let target = source.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: target.midX, y: target.midY)) }
                ?? source.screen ?? NSScreen.main
            guard let screen else { close(); return }
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let label = InstantHintTextLayout.label(for: text, maximumWidth: visible.width - 20)
            let size = NSSize(width: label.frame.width + 20, height: label.frame.height + 16)

            let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            background.material = .toolTip
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 8
            background.layer?.masksToBounds = true
            background.addSubview(label)

            if Self.active !== self { Self.active?.close() }
            Self.active = self
            let window: NSPanel
            if let panel { window = panel } else {
                window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.hidesOnDeactivate = true
                window.ignoresMouseEvents = true
                window.becomesKeyOnlyIfNeeded = true
                panel = window
            }
            window.appearance = source.effectiveAppearance
            window.contentView = background
            let x = min(max(target.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            let above = target.maxY + 6
            let preferredY = above + size.height <= visible.maxY ? above : target.minY - size.height - 6
            let y = min(max(preferredY, visible.minY), visible.maxY - size.height)
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
            if window.parent !== source {
                window.parent?.removeChildWindow(window)
                source.addChildWindow(window, ordered: .above)
            }
            window.orderFront(nil)
        }

        func close() {
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.close()
                self.panel = nil
            }
            if Self.active === self { Self.active = nil }
        }
    }
}
extension View {
    func instantHint(_ text: String) -> some View { modifier(InstantHint(text: text)) }
    func toolboxCard() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 0.6))
    }
}

enum QuickTool: String, CaseIterable, Identifiable, Codable {
    case model, network, local, quota, history, notebook, share
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: return toolboxText("模型检测", "Model Detect")
        case .network: return toolboxText("网络工具箱", "Network Tools")
        case .local: return toolboxText("本地工具箱", "Local Tools")
        case .quota: return toolboxText("订阅额度", "Subscription Quota")
        case .history: return toolboxText("用量历史", "History Usage")
        case .notebook: return toolboxText("行事本", "Notebook")
        case .share: return toolboxText("分享用量", "Share Usage")
        }
    }
    var symbol: String {
        switch self {
        case .model: return "waveform.path.ecg.rectangle"
        case .network: return "network.badge.shield.half.filled"
        case .local: return "externaldrive.badge.checkmark"
        case .quota: return "gauge.with.dots.needle.50percent"
        case .history: return "clock.arrow.circlepath"
        case .notebook: return "note.text"
        case .share: return "square.and.arrow.up"
        }
    }
    var hint: String {
        switch self {
        case .network: return toolboxText("DNS / DoH、WebRTC、出口与地区、IPv6、AI 分流", "DNS / DoH, WebRTC, exit/location, IPv6 and AI routing")
        case .local: return toolboxText("环境冲突、磁盘、日志泄密、时钟、API Key 验活", "Environment, disk, log secrets, clock and API keys")
        default: return title
        }
    }
}
@MainActor final class QuickToolPreferences: ObservableObject {
    static let shared = QuickToolPreferences()
    static let defaults: [QuickTool] = [.model, .network, .local, .quota, .history, .notebook]
    private let store: UserDefaults
    @Published var order: [QuickTool] {
        didSet {
            store.set(order.map(\.rawValue), forKey: "toolbox.quickOrder")
            store.set(1, forKey: "toolbox.quickOrderVersion")
        }
    }
    init(defaults: UserDefaults = .standard) {
        store = defaults
        var seen = Set<QuickTool>()
        let stored = defaults.stringArray(forKey: "toolbox.quickOrder")?.compactMap(QuickTool.init(rawValue:))
        let previousDefaults: [QuickTool] = [.model, .network, .local, .quota]
        let previousFive: [QuickTool] = previousDefaults + [.history]
        let migrate = defaults.integer(forKey: "toolbox.quickOrderVersion") < 1 && (stored == previousDefaults || stored == previousFive)
        order = (migrate ? Self.defaults : stored ?? Self.defaults).filter { seen.insert($0).inserted }
        if migrate { defaults.set(order.map(\.rawValue), forKey: "toolbox.quickOrder") }
        defaults.set(1, forKey: "toolbox.quickOrderVersion")
    }
    func toggle(_ item: QuickTool) { if order.contains(item) { order.removeAll { $0 == item } } else { order.append(item) } }
    func move(_ item: QuickTool, by step: Int) {
        guard let index = order.firstIndex(of: item), order.indices.contains(index + step) else { return }
        order.swapAt(index, index + step)
    }
    func move(_ item: QuickTool, to target: QuickTool) {
        guard item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else { return }
        var values = order
        values.remove(at: from); values.insert(item, at: to)
        order = values
    }
}
private struct QuickToolOrderDrag: Codable, Transferable {
    let tool: QuickTool
    let editorID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

struct QuickToolGrid: View {
    @ObservedObject private var preferences = QuickToolPreferences.shared
    var color: Color = .primary
    var showHeading = false
    var compactIcons = false
    var expandsOnHover = false
    var showsEditorButton = true
    let action: (QuickTool) -> Void
    @State private var editing = false
    @State private var availableWidth: CGFloat = 310
    var body: some View {
        if compactIcons {
            HStack(spacing:5) {
                ForEach(preferences.order) { item in
                    Button { action(item) } label: {
                        Image(systemName:item.symbol).font(.system(size:13)).frame(maxWidth:.infinity,minHeight:28)
                            .background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(.plain).instantHint(item.title+" · "+item.hint)
                }
                Button {editing.toggle()} label:{Image(systemName:"slider.horizontal.3").font(.system(size:11)).frame(width:22,height:28)}
                    .buttonStyle(.plain).instantHint(toolboxText("编辑快捷按钮", "Edit shortcuts")).popover(isPresented:$editing){editor}
            }
        } else {
        VStack(alignment: .leading, spacing: 6) {
            if showHeading || showsEditorButton {
            HStack {
                if showHeading { Text(toolboxText("工具箱", "Toolboxes")).font(.system(size: 11, weight: .semibold)) }
                Spacer()
                if showsEditorButton { Button { editing.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
                    .buttonStyle(.plain).instantHint(toolboxText("编辑快捷按钮：显示、排序、恢复默认", "Edit shortcuts: visibility, order and defaults"))
                    .popover(isPresented: $editing) { editor } }
            }
            }
            if expandsOnHover {
                QuickToolHoverStrip(items: preferences.order, color: color, action: action)
            } else if preferences.order.count <= 4 {
                HStack(spacing:6) {
                    ForEach(preferences.order) { item in
                        if item == .network || item == .local {
                            QuickToolNarrowButton(item:item,color:color){action(item)}
                        } else {
                            QuickToolButton(item:item,color:color,showsLeadingIcon:availableWidth>=400){action(item)}
                        }
                    }
                }.background(GeometryReader { g in Color.clear.onAppear{availableWidth=g.size.width}.onChange(of:g.size.width){availableWidth=$0} })
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:112),spacing:8)],spacing:8) {
                    ForEach(preferences.order){item in QuickToolButton(item:item,color:color){action(item)}}
                }
            }
        }
    }
    }
    private var editor: some View { QuickToolEditorView() }
}
struct QuickToolEditorView: View {
    @ObservedObject private var preferences = QuickToolPreferences.shared
    @State private var editorID = UUID()
    @State private var dropTarget: QuickTool?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toolboxText("快捷按钮", "Quick actions")).font(.headline)
            Text(toolboxText("勾选显示；拖动左侧手柄或使用箭头排序。", "Choose visible actions; drag a handle or use the arrows to reorder."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(preferences.order + QuickTool.allCases.filter { !preferences.order.contains($0) }) { item in
                HStack {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 22).contentShape(Rectangle())
                        .draggable(QuickToolOrderDrag(tool: item, editorID: editorID))
                        .allowsHitTesting(preferences.order.contains(item)).opacity(preferences.order.contains(item) ? 1 : 0.25)
                        .instantHint(toolboxText("拖动调整从左到右的顺序", "Drag to change the left-to-right order"))
                    Toggle(item.title, isOn: Binding(get: { preferences.order.contains(item) }, set: { _ in preferences.toggle(item) })).toggleStyle(.checkbox)
                    Spacer()
                    Button { preferences.move(item, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(preferences.order.first == item || !preferences.order.contains(item)).instantHint(toolboxText("向前移", "Move earlier"))
                    Button { preferences.move(item, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(preferences.order.last == item || !preferences.order.contains(item)).instantHint(toolboxText("向后移", "Move later"))
                }
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(dropTarget == item ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
                .dropDestination(for: QuickToolOrderDrag.self) { payload, _ in
                    guard payload.count == 1, let drag = payload.first, drag.editorID == editorID,
                          preferences.order.contains(item), preferences.order.contains(drag.tool) else { return false }
                    preferences.move(drag.tool, to: item); dropTarget = nil
                    return true
                } isTargeted: { targeted in dropTarget = targeted && preferences.order.contains(item) ? item : nil }
            }
            Text(toolboxText("顺序从左到右生效，自动保存。", "Applied left to right and saved automatically."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Button(toolboxText("恢复默认", "Reset to defaults")) { preferences.order = QuickToolPreferences.defaults }
        }.buttonStyle(.bordered).controlSize(.small).padding(16).frame(width: 330)
    }
}
/// One labelled shortcut at a time; hovering never invokes a tool or starts a check.
private struct QuickToolHoverStrip: View {
    let items: [QuickTool]
    let color: Color
    let action: (QuickTool) -> Void
    @State private var expandedTool: QuickTool?
    @State private var hoveredTool: QuickTool?
    @State private var expansionTask: Task<Void, Never>?
    @State private var resetTask: Task<Void, Never>?

    private var expanded: QuickTool? {
        expandedTool.flatMap { items.contains($0) ? $0 : nil } ?? items.first
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let otherCount = CGFloat(max(0, items.count - 1))
            let narrowWidth = min(32, max(24, (geometry.size.width - spacing * otherCount - 110) / max(1, otherCount)))
            let expandedWidth = max(narrowWidth, geometry.size.width - (narrowWidth + spacing) * otherCount)
            HStack(spacing: spacing) {
                ForEach(items) { item in
                    let isExpanded = expanded == item
                    Button { action(item) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium)).frame(width: 18)
                            if isExpanded {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(2).minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8)).opacity(0.5).transition(.opacity)
                            }
                        }
                        .foregroundStyle(color)
                        .padding(.horizontal, isExpanded ? 9 : 0)
                        .frame(width: isExpanded ? expandedWidth : narrowWidth, height: 46)
                        .background(color.opacity(hoveredTool == item ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.12), lineWidth: 0.6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityIdentifier("quick-tool.\(item.rawValue)")
                    .onHover { hovering in hover(item, hovering: hovering) }
                    .instantHint(item.hint)
                }
            }
            .onHover { hovering in
                resetTask?.cancel()
                if !hovering {
                    hoveredTool = nil
                    expansionTask?.cancel()
                    resetTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.16)) { expandedTool = nil }
                    }
                }
            }
        }
        .frame(height: items.isEmpty ? 0 : 46)
        .onDisappear {
            expansionTask?.cancel()
            resetTask?.cancel()
            expandedTool = nil
            hoveredTool = nil
        }
        .onChange(of: items) { _, _ in
            expansionTask?.cancel()
            resetTask?.cancel()
            expandedTool = nil
            hoveredTool = nil
        }
    }

    private func hover(_ item: QuickTool, hovering: Bool) {
        if hovering {
            resetTask?.cancel()
            expansionTask?.cancel()
            hoveredTool = item
            expansionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, hoveredTool == item else { return }
                withAnimation(.easeInOut(duration: 0.16)) { expandedTool = item }
            }
        } else if hoveredTool == item {
            hoveredTool = nil
            expansionTask?.cancel()
        }
    }
}
private struct QuickToolButton: View {
    let item: QuickTool
    let color: Color
    var showsLeadingIcon = true
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if showsLeadingIcon { Image(systemName:item.symbol).font(.system(size:14,weight:.medium)).frame(width:20) }
                Text(item.title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 8)).opacity(0.5)
            }.foregroundStyle(color).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 46)
                .background(color.opacity(hovered ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.12), lineWidth: 0.6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.instantHint(item.hint)
    }
}
private struct QuickToolNarrowButton: View {
    let item:QuickTool
    let color:Color
    let action:()->Void
    @State private var hovered=false
    var body:some View {
        Button(action:action){
            Image(systemName:item.symbol).font(.system(size:15,weight:.medium)).foregroundStyle(color)
                .frame(width:32,height:46).background(color.opacity(hovered ? 0.12:0.06),in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(color.opacity(0.12),lineWidth:0.6))
        }.buttonStyle(.plain).onHover{hovered=$0}.instantHint(item.title+" · "+item.hint).accessibilityLabel(item.title)
    }
}
#endif
