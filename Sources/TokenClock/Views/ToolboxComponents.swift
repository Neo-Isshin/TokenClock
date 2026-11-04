#if os(macOS)
import SwiftUI
import AppKit

func toolboxText(_ cn: String, _ en: String) -> String { L10n.shared.language.rawValue.hasPrefix("zh") ? cn : en }

private struct InstantHint: ViewModifier {
    let text: String
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.onHover { hovered = $0 }
            .overlay {
                GeometryReader { geometry in
                    if hovered {
                        Text(text).font(.system(size: 10)).foregroundStyle(Color(nsColor: .labelColor))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: min(220,max(110,geometry.size.width)))
                            .position(x: geometry.size.width/2, y: geometry.frame(in:.global).minY < 55 ? geometry.size.height+24 : -24)
                    }
                }.allowsHitTesting(false)
            }.zIndex(hovered ? 100 : 0)
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
    case model, network, local, quota, history, share
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: return "Model Detect"
        case .network: return toolboxText("网络工具箱", "Network Tools")
        case .local: return toolboxText("本地工具箱", "Local Tools")
        case .quota: return "Subscription Quota"
        case .history: return "History Usage"
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
    static let defaults: [QuickTool] = [.model, .network, .local, .quota]
    @Published var order: [QuickTool] { didSet { UserDefaults.standard.set(order.map(\.rawValue), forKey: "toolbox.quickOrder") } }
    init() {
        var seen = Set<QuickTool>()
        order = (UserDefaults.standard.stringArray(forKey: "toolbox.quickOrder")?.compactMap(QuickTool.init(rawValue:)) ?? Self.defaults).filter { seen.insert($0).inserted }
    }
    func toggle(_ item: QuickTool) { if order.contains(item) { order.removeAll { $0 == item } } else { order.append(item) } }
    func move(_ item: QuickTool, by step: Int) {
        guard let index = order.firstIndex(of: item), order.indices.contains(index + step) else { return }
        order.swapAt(index, index + step)
    }
}
struct QuickToolGrid: View {
    @ObservedObject private var preferences = QuickToolPreferences.shared
    var color: Color = .primary
    var showHeading = false
    var compactIcons = false
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
            HStack {
                if showHeading { Text(toolboxText("工具箱", "Toolboxes")).font(.system(size: 11, weight: .semibold)) }
                Spacer()
                Button { editing.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
                    .buttonStyle(.plain).instantHint(toolboxText("编辑快捷按钮：显示、排序、恢复默认", "Edit shortcuts: visibility, order and defaults"))
                    .popover(isPresented: $editing) { editor }
            }
            if preferences.order.count <= 4 {
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
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toolboxText("快捷按钮", "Quick actions")).font(.headline)
            ForEach(preferences.order + QuickTool.allCases.filter { !preferences.order.contains($0) }) { item in
                HStack {
                    Toggle(item.title, isOn: Binding(get: { preferences.order.contains(item) }, set: { _ in preferences.toggle(item) })).toggleStyle(.checkbox)
                    Spacer()
                    Button { preferences.move(item, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(preferences.order.first == item || !preferences.order.contains(item)).instantHint(toolboxText("向前移", "Move earlier"))
                    Button { preferences.move(item, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(preferences.order.last == item || !preferences.order.contains(item)).instantHint(toolboxText("向后移", "Move later"))
                }
            }
            Button(toolboxText("恢复默认", "Reset to defaults")) { preferences.order = QuickToolPreferences.defaults }
        }.buttonStyle(.bordered).controlSize(.small).padding(16).frame(width: 330)
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
