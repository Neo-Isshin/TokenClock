#if os(macOS)
import Foundation

/// A portable view of the same result. No scripts, remote assets or regrading.
@MainActor
enum ModelDetectReadableReport {
    static func render(brief: ModelDetectNativeModel.Brief, presentation: ModelDetectResultPresentation,
                       target: String, suggestion: String, cost: String, comparison: ModelDetectJSON = .null) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        func point(_ i: Int, _ r: Double) -> String {
            let a = -Double.pi / 2 + Double(i) * Double.pi / 3
            return "\(180 + cos(a) * r),\(150 + sin(a) * r)"
        }
        func color(_ state: ModelDetectResultPresentation.State) -> String {
            switch state { case .issue: return "#b65b18"; case .aligned: return "#247c75"; case .observed: return "#6564c8"; default: return "#777d89" }
        }
        let axes = presentation.radarAxes
        var svg = "<svg viewBox='0 0 360 300' role='img' aria-label='检测覆盖概览'>"
        for ring in 1...3 {
            svg += "<polygon points='" + (0..<6).map { point($0, Double(ring) * 29) }.joined(separator: " ") + "' fill='none' stroke='#dfe2e8'/>"
        }
        if !presentation.multipleSubjects && presentation.observedCount > 0 {
            svg += "<polygon points='" + axes.map { point($0.id, $0.coverage * 87) }.joined(separator: " ") + "' fill='#716bcb' fill-opacity='.13' stroke='#716bcb' stroke-width='1.5'/>"
        }
        for axis in axes {
            let xy = point(axis.id, 121).split(separator: ",")
            let label = presentation.multipleSubjects ? "分别查看" : ModelDetectRadarView.label(axis.state)
            svg += "<text x='\(xy[0])' y='\(xy[1])' text-anchor='middle' font-size='12' fill='#343946'>\(escape(axis.title))</text>"
            svg += "<text x='\(xy[0])' y='\(Double(xy[1])! + 15)' text-anchor='middle' font-size='10' fill='\(color(axis.state))'>\(escape(label))</text>"
        }
        svg += "</svg>"
        let rows = ModelDetectResultPresentation.items.compactMap { item -> String? in
            let observed = (1...3).filter { ![.notRun, .unavailable].contains(presentation.cell(item.id, $0).state) }
            guard !observed.isEmpty else { return nil }
            return "<tr><td>\(escape(item.title))</td><td>" + observed.map { layer in
                let cell = presentation.cell(item.id, layer)
                let note = cell.notes.first?.text ?? ""
                return "L\(layer) · \(escape(cell.state.label))：\(escape(note))"
            }.joined(separator: "<br>") + "</td></tr>"
        }.joined()
        var history = ""
        if let title = comparison["title"].string {
            history = "<section><h2>历史对照 · " + escape(title) + "</h2><p>" + escape(comparison["summary"].string ?? "") + "</p>"
            for (key,label) in [("left","历史结果"),("right","本次结果")] {
                history += "<p><strong>" + label + "：</strong>" + escape(comparison[key]["title"].string ?? "") + "<br>" + escape(comparison[key]["summary"].string ?? "") + "</p>"
            }
            if !comparison["changes"].array.isEmpty { history += "<details><summary>查看差别</summary><ul>" + comparison["changes"].array.map { "<li>" + escape($0["text"].string ?? "") + "</li>" }.joined() + "</ul></details>" }
            history += "<p class='muted'>仅使用已保存的记录，没有再次调用模型。</p></section>"
        }
        return """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>Model Detect · \(escape(brief.title))</title><style>
        *{box-sizing:border-box}body{margin:0;background:#f4f5f8;color:#303541;font:15px/1.65 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:760px;margin:36px auto;padding:28px}h1{font-size:26px;line-height:1.35;margin:12px 0}h2{font-size:16px}
        section{background:white;border:1px solid #e4e6ed;border-radius:18px;padding:24px;margin:18px 0}.muted{font-size:12px;color:#707784}
        svg{display:block;width:360px;max-width:100%;margin:auto}summary{cursor:pointer}td{padding:8px;vertical-align:top;border-bottom:1px solid #eee}table{width:100%;font-size:12px;border-collapse:collapse}
        @media print{body{background:white}main{margin:0;padding:0}section{break-inside:avoid}}
        </style><main><p class="muted">TokenClock · Model Detect</p><p>\(escape(target))</p>
        <section><h1>\(escape(brief.title))</h1><p>\(escape(brief.summary))</p><p class="muted">\(escape(brief.caveat))</p></section>
        <section><h2>检测概览</h2>\(svg)<p class="muted">\(presentation.multipleSubjects ? "包含多个对象，请分别查看。" : "图形展开程度表示检查覆盖，不表示模型好坏。橙色提示发现问题，灰色表示信息不足。")</p></section>
        <p>\(escape(suggestion))</p><p class="muted">\(escape(cost))</p>\(history)
        <details><summary>查看判断依据</summary><ul>\(brief.reasons.map { "<li>" + escape($0) + "</li>" }.joined())</ul><table>\(rows)</table></details>
        <p class="muted">这份报告仅描述本次检测；完整原始记录可在 TokenClock 中另行导出。</p></main></html>
        """
    }
}
#endif
