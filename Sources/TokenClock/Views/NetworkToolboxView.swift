#if os(macOS)
import SwiftUI

@MainActor final class NetworkToolboxPresentation: ObservableObject {
    struct Card: Identifiable { let id: String; var title: String; var status: String; var text: String; var state: String }
    @Published var status = ""
    @Published var summary = ""
    @Published var running = false
    @Published var cards: [Card] = []
    @Published var expectedDNS = ""
    @Published var ipv4Only = false
    func update(_ data: [String: Any]) {
        status = String((data["status"] as? String ?? "").prefix(400))
        summary = String((data["summary"] as? String ?? "").prefix(800))
        running = data["running"] as? Bool ?? false
        if let items = data["cards"] as? [[String: String]] {
            cards = items.prefix(7).map { Card(id: $0["id"] ?? "", title: $0["title"] ?? "", status: $0["status"] ?? "", text: String(($0["text"] ?? "").prefix(10000)), state: $0["state"] ?? "") }
        }
    }
}
struct NetworkToolboxView: View {
    @ObservedObject var model: NetworkToolboxPresentation
    let onRun: () -> Void
    let onStop: () -> Void
    let onBrowser: () -> Void
    let onOptions: () -> Void
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
                    if !model.summary.isEmpty {Text(model.summary).font(.system(size:11,weight:.semibold)).lineLimit(3)}
                    Text(model.status.isEmpty ? toolboxText("等待检测", "Ready") : model.status).font(.system(size:10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(model.cards) { card in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top) {
                                Text(card.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(card.status).font(.system(size: 10, weight: .medium)).foregroundStyle(card.state == "risk" || card.state == "review" ? Color.orange : .secondary)
                            }
                            if card.text.components(separatedBy: .newlines).count > 10 {
                                ScrollView {
                                    Text(card.text).font(.system(size:10.5,design:.monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                                }.frame(height:150)
                            } else {
                                Text(card.text.isEmpty ? "—" : card.text).font(.system(size:10.5,design:.monospaced)).textSelection(.enabled)
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
#endif
