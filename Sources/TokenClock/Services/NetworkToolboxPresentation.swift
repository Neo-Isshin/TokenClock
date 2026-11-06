import Foundation
#if canImport(Combine)
import Combine
#endif
@MainActor final class NetworkToolboxPresentation: ObservableObject {
    struct Card: Identifiable, Codable {
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
