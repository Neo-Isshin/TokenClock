#if os(macOS)
import SwiftUI

/// A map of measured coverage. Radius never represents quality or model identity.
@MainActor
struct ModelDetectRadarView: View {
    let presentation: ModelDetectResultPresentation
    private typealias T = ModelDetectNativeText
    private var axes: [ModelDetectResultPresentation.RadarAxis] { presentation.radarAxes }
    private func point(_ index: Int, radius: Double) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) * Double.pi / 3
        return CGPoint(x: 176 + cos(angle) * radius, y: 145 + sin(angle) * radius)
    }
    private func polygon(_ radii: [Double]) -> Path {
        Path { path in
            for (index, radius) in radii.enumerated() {
                if index == 0 { path.move(to: point(index, radius: radius)) }
                else { path.addLine(to: point(index, radius: radius)) }
            }
            path.closeSubpath()
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ForEach(1...3, id: \.self) { ring in
                    polygon(Array(repeating: Double(ring) * 29, count: 6))
                        .stroke(Color.primary.opacity(ring == 3 ? 0.12 : 0.06), lineWidth: 1)
                }
                ForEach(0..<6, id: \.self) { i in
                    Path { p in p.move(to: point(i, radius: 0)); p.addLine(to: point(i, radius: 87)) }
                        .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if !presentation.multipleSubjects && presentation.observedCount > 0 {
                    polygon(axes.map { $0.coverage * 87 })
                        .fill(LinearGradient(colors: [ModelDetectPalette.accent.opacity(0.20), .teal.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                    polygon(axes.map { $0.coverage * 87 }).stroke(ModelDetectPalette.accent.opacity(0.7), lineWidth: 1.5)
                }
                ForEach(axes) { axis in
                    if !presentation.multipleSubjects && axis.observed > 0 {
                        Circle().fill(ModelDetectPalette.color(axis.state)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(ModelDetectPalette.card, lineWidth: 1.5))
                            .position(point(axis.id, radius: axis.coverage * 87))
                    }
                    VStack(spacing: 3) {
                        Text(axis.title).font(.system(size: 12, weight: .medium))
                        Text(presentation.multipleSubjects ? T.text("分别查看", "分別查看", "View separately") : Self.label(axis.state))
                            .font(.system(size: 10)).foregroundColor(axis.state == .notRun || axis.state == .unavailable ? .secondary : ModelDetectPalette.color(axis.state))
                    }
                    .frame(width: 108, height: 40)
                    .position(point(axis.id, radius: 121))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(axis.title + " · " + (presentation.multipleSubjects ? "分别查看" : Self.label(axis.state)) + " · \(axis.observed)/\(axis.total)")
                }
            }
            .frame(width: 352, height: 290)
            VStack(alignment: .leading, spacing: 16) {
                Text(T.text("检测概览", "檢測概覽", "At a glance")).font(.system(size: 15, weight: .semibold, design: .rounded))
                ForEach(1...3, id: \.self) { layer in
                    HStack(spacing: 8) {
                        Image(systemName: ["doc.text.magnifyingglass", "bubble.left.and.text.bubble.right", "checklist"][layer - 1])
                            .frame(width: 20).foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([T.text("会话记录", "會話紀錄", "Session records"), T.text("短题检测", "短題檢測", "Short questions"), T.text("任务检测", "任務檢測", "Task checks")][layer - 1])
                                .font(.system(size: 12, weight: .medium))
                            Text(layerStatus(layer)).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
                Text(presentation.multipleSubjects ? T.text("包含多个对象，请展开分别查看。", "包含多個物件，請展開分別查看。", "Several targets; view their results separately.") : T.text("图形展开程度表示检查覆盖。\n橙色提示发现问题，灰色表示信息不足。", "圖形展開程度表示檢查覆蓋。\n橙色提示發現問題，灰色表示資訊不足。", "The shape shows coverage.\nOrange flags issues; gray means missing information."))
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(ModelDetectPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ModelDetectPalette.border))
        .accessibilityIdentifier("model-detect-radar")
    }
    private func layerStatus(_ layer: Int) -> String {
        let count = presentation.observedCount(layer: layer)
        if count > 0 { return T.text("已有 \(count) 项观察", "已有 \(count) 項觀察", "\(count) checks observed") }
        if ModelDetectResultPresentation.items.contains(where: { presentation.cell($0.id, layer).state == .limited }) {
            return T.text("信息不足", "資訊不足", "Missing information")
        }
        return T.text("尚未检查", "尚未檢查", "Not checked")
    }
    static func label(_ state: ModelDetectResultPresentation.State) -> String {
        switch state {
        case .issue: return T.text("需要留意", "需要留意", "Needs attention")
        case .aligned: return T.text("已检查项符合", "已檢查項符合", "Checks passed")
        case .observed: return T.text("已有结果", "已有結果", "Observed")
        case .limited: return T.text("信息不足", "資訊不足", "Missing information")
        default: return T.text("尚未检查", "尚未檢查", "Not checked")
        }
    }
}
#endif
