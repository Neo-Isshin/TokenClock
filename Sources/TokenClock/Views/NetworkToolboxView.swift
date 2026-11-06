#if os(macOS)
import SwiftUI

@MainActor final class NetworkToolboxPresentation: ObservableObject {
    struct Card: Identifiable {
        let id: String; var title: String; var status: String; var text: String; var state: String
        var localizedTitle: String {
            switch id {
            case "exit": return toolboxText("网页出口", "Web connection")
            case "dns": return toolboxText("DNS 解析器", "DNS resolvers")
            case "rtc": return toolboxText("WebRTC 地址", "WebRTC addresses")
            case "consistency": return toolboxText("出口与地区一致性", "Exit & location consistency")
            case "ipv6": return toolboxText("IPv6 暴露", "IPv6 exposure")
            case "ai": return toolboxText("AI 域名分流", "AI domain routing")
            case "doh": return toolboxText("DoH 参考检测", "DoH reference check")
            default: return title
            }
        }
        var localizedStatus: String {
            if ["ai","doh"].contains(id), let range = status.range(of:#"\d+/\d+"#,options:.regularExpression) {
                return (id == "ai" ? toolboxText("已观测 ", "Observed ") : toolboxText("DNS 已验证 ", "DNS verified ")) + status[range]
            }
            switch state {
            case "risk": return ["dns","rtc","ipv6"].contains(id) ? toolboxText("可能泄漏", "Possible leak") : toolboxText("需核对", "Review")
            case "review": return id == "dns" ? toolboxText("待设置预期", "Set expected DNS") : toolboxText("需核对", "Review")
            case "match": return toolboxText("一致", "Matches")
            case "observed": return toolboxText("已观测", "Observed")
            case "notObserved": return toolboxText("未观测到", "Not observed")
            case "incomplete": return toolboxText("未完成", "Incomplete")
            case "running": return toolboxText("检测中", "Checking")
            case "idle": return toolboxText("尚未检测", "Not checked")
            case "invalid": return toolboxText("预期输入无效", "Invalid expected input")
            default: return status
            }
        }
    }
    @Published var status = ""
    @Published var summary = ""
    @Published var running = false
    @Published var cards: [Card] = []
    @Published var expectedDNS = ""
    @Published var ipv4Only = false
    @Published var observedExitIP: String?
    let mainland = MainlandReachabilityModel()
    var issueSummary: String {
        guard !cards.isEmpty else { return toolboxText("点击检测，核对当前连接的出口与泄漏风险。", "Run checks to review this connection’s exit and leak risks.") }
        if running { return toolboxText("正在检测，结论将在完成后显示。", "Checking; the summary will appear when finished.") }
        let issues = cards.compactMap { card -> String? in
            if card.state == "risk" {
                switch card.id {
                case "dns": return toolboxText("DNS泄漏：可能泄漏", "DNS: possible leak")
                case "rtc": return toolboxText("WebRTC：可能泄漏", "WebRTC: possible leak")
                case "ipv6": return toolboxText("IPv6：可能泄漏", "IPv6: possible leak")
                default: return card.localizedTitle + toolboxText("：需核对", ": review needed")
                }
            }
            // DNS “review” means the user has not supplied expected resolver IPs.
            if card.state == "review", ["rtc", "ipv6", "consistency", "ai", "doh"].contains(card.id) {
                return card.localizedTitle + toolboxText("：需核对", ": review needed")
            }
            return nil
        }
        let completed = cards.contains { ["match", "observed", "none"].contains($0.state) }
        if issues.isEmpty {
            return completed ? toolboxText("已完成项目未检出泄漏风险。", "No leak risk detected in completed checks.") : toolboxText("暂未取得可判断的结果。", "No conclusive results yet.")
        }
        return issues.joined(separator: toolboxText("；", "; ")) + (completed ? toolboxText("。其余已完成项目未检出风险。", ". Other completed checks found no risk.") : toolboxText("。", "."))
    }
    var pendingSummary: String {
        let pending = cards.filter { !["risk", "match", "observed", "none"].contains($0.state) && !($0.state == "review" && ["rtc", "ipv6", "consistency", "ai", "doh"].contains($0.id)) }
        guard !pending.isEmpty, !running else { return "" }
        return toolboxText("另有 \(pending.count) 项未完成或待核对：", "\(pending.count) incomplete or awaiting review: ") + pending.map(\.localizedTitle).joined(separator: toolboxText("、", ", "))
    }
    func update(_ data: [String: Any]) {
        status = String((data["status"] as? String ?? "").prefix(400))

        running = data["running"] as? Bool ?? false
        if let items = data["cards"] as? [[String: String]] {
            cards = items.prefix(7).map { Card(id: $0["id"] ?? "", title: $0["title"] ?? "", status: $0["status"] ?? "", text: String(($0["text"] ?? "").prefix(10000)), state: $0["state"] ?? "") }
        }
        summary = issueSummary
    }
}
struct NetworkToolboxView: View {
    @ObservedObject var model: NetworkToolboxPresentation
    @ObservedObject private var mainland: MainlandReachabilityModel
    let onRun: () -> Void
    let onStop: () -> Void
    let onBrowser: () -> Void
    let onOptions: () -> Void

    init(model: NetworkToolboxPresentation, onRun: @escaping () -> Void, onStop: @escaping () -> Void,
         onBrowser: @escaping () -> Void, onOptions: @escaping () -> Void) {
        self.model = model
        self.mainland = model.mainland
        self.onRun = onRun; self.onStop = onStop; self.onBrowser = onBrowser; self.onOptions = onOptions
    }
    private var combinedSummary: String {
        [model.issueSummary, mainland.report.flatMap { $0.verdict == .suspectedRestriction ? toolboxText("大陆可达性：", "Mainland reachability: ") + $0.summary : nil }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func cardIcon(_ id: String) -> String {
        switch id {
        case "dns": return "server.rack"
        case "rtc": return "video"
        case "consistency": return "globe"
        case "ipv6": return "network"
        case "ai": return "point.3.connected.trianglepath.dotted"
        case "doh": return "lock.shield"
        default: return "wifi"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(toolboxText("网络工具箱", "Network Toolbox")).font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(toolboxText("按需检测当前连接，不读取账号或会话", "On-demand checks for this connection; no account or session access")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onBrowser) { Image(systemName: "safari") }.instantHint(toolboxText("在默认浏览器中单独检测", "Check the default browser separately"))
                if model.running { Button(toolboxText("停止", "Stop"), action: onStop).instantHint(toolboxText("立即取消本次探测", "Cancel this check immediately")) }
                else { Button(toolboxText("开始检测", "Run checks"), action: onRun).instantHint(toolboxText("检测一次，完成后停止", "Run once, then stop")) }
            }.buttonStyle(.bordered).padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            HStack(spacing: 7) {
                if model.running { ProgressView().controlSize(.mini) }
                VStack(alignment:.leading,spacing:3) {
                    if !combinedSummary.isEmpty {Text(combinedSummary).font(.system(size:12,weight:.semibold)).fixedSize(horizontal:false,vertical:true)}
                    if !model.pendingSummary.isEmpty { Text(model.pendingSummary).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    Text(model.status.isEmpty ? toolboxText("等待检测", "Ready") : model.status).font(.system(size:10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.toolboxCard().padding(.horizontal,16).padding(.top,12)
            ScrollView {
                MainlandReachabilityCard(model: mainland, observedExitIP: model.observedExitIP)
                    .padding(.horizontal, 16).padding(.top, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(model.cards) { card in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top) {
                                Label(card.localizedTitle, systemImage: cardIcon(card.id)).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(card.localizedStatus).font(.system(size: 10, weight: .medium)).foregroundStyle(card.state == "risk" ? Color.orange : Color.secondary).padding(.horizontal,6).padding(.vertical,3).background(.primary.opacity(0.045), in:Capsule())
                            }
                            if card.text.components(separatedBy: .newlines).count > 10 {
                                ScrollView {
                                    Text(card.text).font(.system(size:10.5,design:.monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                                }.frame(height:150)
                            } else {
                                Text(card.text.isEmpty ? toolboxText("尚未取得数据", "No data yet") : card.text).font(.system(size:10.5,design:.monospaced)).textSelection(.enabled)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                            }
                        }.toolboxCard()
                    }
                }.padding(16)
                DisclosureGroup(toolboxText("检测预期（可选）", "Expected policy (optional)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(toolboxText("预期查询来源 IP（可与本机 DNS 地址不同）", "Expected DNS IPs, comma-separated"), text: $model.expectedDNS)
                            .textFieldStyle(.roundedBorder).onChange(of: model.expectedDNS) { _ in onOptions() }
                        Toggle(toolboxText("预期只使用 IPv4", "Expect IPv4 only"), isOn: $model.ipv4Only).onChange(of: model.ipv4Only) { _ in onOptions() }
                        Text(toolboxText("地址或地区不同仅提示核对。无响应不代表安全；应用内结果不代表浏览器扩展规则。", "Address/location differences need review. No response does not prove safety; app results do not cover browser extension rules.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 16)
            }
        }.frame(minWidth: 440, minHeight: 420).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MainlandReachabilityCard: View {
    @ObservedObject var model: MainlandReachabilityModel
    let observedExitIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(toolboxText("大陆可达性 / GFW 参考", "Mainland reachability / GFW reference"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                else { Text(model.report == nil ? toolboxText("尚未检测", "Not checked") : toolboxText("检测完成", "Finished"))
                    .font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text(toolboxText("填写已开放的服务端口。大陆三网多点与境外对照；出口 IP 可能不接受入站连接。", "Use an open service port. Compare mainland carrier probes with foreign controls; an exit IP may not accept inbound connections."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) { targetFields; controls }
            if !model.inputError.isEmpty {
                Text(model.inputError).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if model.running {
                Text(toolboxText("请求大陆三网及境外节点；必要时复用同一批探针核对参考地址，最多等待 40 秒。", "Requesting mainland and foreign probes; reusing the same probes for a reference check when needed. Up to 40 seconds."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let report = model.report {
                Text(report.target.display).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(report.summary).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(report.verdict == .suspectedRestriction ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 9) {
                    ForEach(report.observations) { row in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(nodeTitle(row)).font(.system(size: 10, weight: .medium)).lineLimit(2)
                                Text("AS\(String(row.asn)) · \(row.city)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                                if let reference = row.referenceReachable {
                                    Text(reference ? toolboxText("同探针对照：可达", "Same-probe reference: reachable") : toolboxText("同探针对照：未连通", "Same-probe reference: no connection"))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 2)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(outcomeText(row.outcome)).font(.system(size: 10))
                                if let rtt = row.milliseconds { Text(String(format: "%.0f ms", rtt)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                            }
                        }.padding(8).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                HStack {
                    Text(report.checkedAt, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Divider()
            HStack(spacing: 5) {
                Text(toolboxText("探测服务：", "Measurements: "))
                Link("Globalping ↗", destination: URL(string: "https://globalping.io/")!)
                Spacer()
                Link(toolboxText("条款与隐私", "Terms & privacy"), destination: URL(string: "https://globalping.io/terms")!)
            }.font(.system(size: 10))
            Text(toolboxText("点击检测会将目标 IP、端口及测量参数发送给 Globalping；参数和结果可能公开。超时不等于封锁。", "Running a check sends the target IP, port and measurement options to Globalping; parameters and results may be public. A timeout does not prove blocking."))
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(toolboxText("仅验证 TCP 连接，不覆盖域名、TLS/SNI 或代理协议。", "TCP reachability only; this does not test domain, TLS/SNI or proxy-protocol filtering."))
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.toolboxCard()
    }

    private var targetFields: some View {
        HStack(spacing: 7) {
            TextField(toolboxText("公网 IPv4 / IPv6", "Public IPv4 / IPv6"), text: $model.targetIP)
                .textFieldStyle(.roundedBorder).frame(minWidth: 140)
                .accessibilityLabel(toolboxText("检测目标 IP", "Target IP"))
            TextField(toolboxText("端口", "Port"), text: $model.targetPort)
                .textFieldStyle(.roundedBorder).frame(width: 65)
                .accessibilityLabel(toolboxText("检测目标端口", "Target port"))
        }.disabled(model.running)
    }
    private var controls: some View {
        HStack(spacing: 7) {
            Button(toolboxText("当前出口", "Use exit IP")) { model.targetIP = observedExitIP ?? "" }
                .disabled(model.running || observedExitIP == nil)
                .instantHint(toolboxText("仅填入本次检测观测到的出口；请确认该 IP 上有开放端口。", "Fill the observed exit only; confirm that this IP has an open port."))
            if model.running {
                Button(toolboxText("停止", "Stop")) { model.stop() }
                    .instantHint(toolboxText("取消本地等待；已下发的远端探测可能仍会完成。", "Cancel local waiting; already submitted remote tests may still finish."))
            } else {
                Button(toolboxText("检测可达性", "Check reachability")) { model.start() }
                    .instantHint(toolboxText("发起一次 Globalping 公开测量，不会后台定时运行。", "Run one public Globalping measurement; no background schedule."))
            }
        }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }
    private func nodeTitle(_ row: MainlandProbeObservation) -> String {
        if let carrier = row.carrier {
            if carrier == "China Telecom" { return toolboxText("大陆 · 电信", "Mainland · Telecom") }
            if carrier == "China Unicom" { return toolboxText("大陆 · 联通", "Mainland · Unicom") }
            return toolboxText("大陆 · 移动", "Mainland · Mobile")
        }
        return toolboxText("境外对照 · ", "Foreign control · ") + row.country
    }
    private func outcomeText(_ value: MainlandProbeOutcome) -> String {
        switch value {
        case .reachable: return toolboxText("可达", "Connected")
        case .noResponse: return toolboxText("无响应", "No response")
        case .refused: return toolboxText("连接被拒绝", "Refused")
        case .unavailable: return toolboxText("未取得结果", "Unavailable")
        }
    }
}
#endif
