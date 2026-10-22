#if os(macOS)
import SwiftUI

@MainActor
enum ModelDetectPalette {
    static let accent = Color(nsColor: .systemIndigo)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.07)
    static func color(_ state: ModelDetectResultPresentation.State) -> Color {
        switch state {
        case .issue: return Color(nsColor: .systemOrange)
        case .aligned: return Color(nsColor: .systemTeal)
        case .observed: return Color(nsColor: .systemIndigo)
        case .limited: return .secondary
        case .notRun, .unavailable: return Color.secondary.opacity(0.4)
        }
    }
}

@MainActor
struct ModelDetectEvidenceMatrixView: View {
    let presentation: ModelDetectResultPresentation
    @State private var selection: String?
    private typealias P = ModelDetectResultPresentation
    private typealias T = ModelDetectNativeText
    private let tileWidth: CGFloat = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(T.text("3 层 · 22 维度", "3 層 · 22 維度", "3 layers · 22 checks"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text(T.text("已取得观察", "已取得觀察", "Observed") + " \(presentation.observedCount) / 22")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            if presentation.multipleSubjects {
                Text(T.text("这些记录包含多个对象；图中并列展示覆盖，不能合成一个型号结论。", "這些記錄包含多個物件；圖中並列展示覆蓋，不能合成一個型號結論。", "Multiple subjects: this chart shows coverage, not a combined model verdict."))
                    .font(.caption).foregroundColor(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 66)
                        ForEach(1...3, id: \.self) { layer in
                            HStack(spacing: 5) {
                                Text("L\(layer)").font(.system(size: 11, weight: .bold, design: .rounded))
                                Text(layerName(layer)).font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                            .frame(width: 79, height: 29, alignment: .leading)
                        }
                    }
                    ForEach(0..<6, id: \.self) { group in
                        VStack(spacing: 8) {
                            Text(P.groups[group]).font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary).frame(height: 16)
                            HStack(spacing: 4) {
                                ForEach(P.items.filter { $0.group == group }) { item in
                                    VStack(spacing: 8) {
                                        Text(shortTitle(item)).font(.system(size: 10, weight: .medium))
                                            .multilineTextAlignment(.center).lineSpacing(2)
                                            .frame(width: tileWidth, height: 42)
                                            .help(item.id + " · " + item.title)
                                        ForEach(1...3, id: \.self) { layer in tile(item, layer: layer) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            HStack(spacing: 15) {
                ForEach(P.State.allCases.filter { $0 != .unavailable }, id: \.rawValue) { state in
                    HStack(spacing: 4) {
                        Image(systemName: state.symbol).font(.system(size: state == .observed ? 4 : 8, weight: .bold))
                            .foregroundColor(ModelDetectPalette.color(state)).frame(width: 10)
                        Text(state.label).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            selectedDetail
            Text(T.text("22 项按来源、服务、轨迹、交付、偏好、资源分组。颜色表示本项观察；未检测不算通过，各项不相加成真伪分数。", "22 項按來源、服務、軌跡、交付、偏好、資源分組。顏色表示本項觀察；未檢測不算通過，各項不相加成真偽分數。", "Checks span source, service, process, delivery, behavior and resources. Unchecked items do not pass; cells are not added into an authenticity score."))
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(ModelDetectPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ModelDetectPalette.border))
        .accessibilityElement(children: .contain)
    }
    private func layerName(_ layer: Int) -> String {
        switch layer {
        case 1: return T.text("已有记录", "既有記錄", "Passive")
        case 2: return T.text("轻量探针", "輕量探針", "Light")
        default: return T.text("重型探针", "重型探針", "Heavy")
        }
    }
    private func shortTitle(_ item: P.Item) -> String {
        if L10n.shared.language == .en { return item.id }
        return String(item.name.prefix(2)) + "\n" + String(item.name.dropFirst(2))
    }
    private func tile(_ item: P.Item, layer: Int) -> some View {
        let cell = presentation.cell(item.id, layer), key = P.key(item.id, layer)
        let color = ModelDetectPalette.color(cell.state)
        return Button { selection = key } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(cell.state == .unavailable ? Color.clear : color.opacity(cell.state == .notRun ? 0.06 : 0.13))
                if !cell.state.symbol.isEmpty {
                    Image(systemName: cell.state.symbol)
                        .font(.system(size: cell.state == .observed ? 5 : 10, weight: .semibold))
                        .foregroundColor(color)
                }
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selectedKey == key ? ModelDetectPalette.accent : Color.clear, lineWidth: 1.5)
            }
            .frame(width: tileWidth, height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.state == .unavailable)
        .help("L\(layer) · \(item.title) · \(cell.state.label)")
        .accessibilityLabel("L\(layer) \(item.id) \(item.title) · \(cell.state.label)")
        .accessibilityIdentifier("model-detect-cell-" + key)
    }
    private var selectedKey: String { selection ?? presentation.firstCell }
    private var selectedDetail: some View {
        let parts = selectedKey.split(separator: ".")
        let item = P.items.first { $0.id == parts.last.map(String.init) } ?? P.items[0]
        let layer = Int(parts.first?.dropFirst() ?? "1") ?? 1
        let cell = presentation.cell(item.id, layer)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("L\(layer) · \(item.id) \(item.title)").font(.system(size: 11, weight: .semibold))
                Text(cell.state.label).font(.system(size: 10, weight: .medium))
                    .foregroundColor(ModelDetectPalette.color(cell.state))
                Spacer()
                if !cell.notes.isEmpty {
                    Text(T.text("依据已保留", "依據已保留", "Evidence retained")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Text(cell.notes.first?.text ?? T.text("本次没有此项检测记录。可以选择相应层级补充检测。", "本次沒有此項檢測記錄。可以選擇相應層級補充檢測。", "No check recorded in this run. Select the appropriate layer to collect it."))
                .font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let pointer = cell.notes.first?.pointer {
                Text(pointer).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
        .frame(minHeight: 48, alignment: .top)
        .accessibilityIdentifier("model-detect-selected-evidence")
    }
}
#endif
