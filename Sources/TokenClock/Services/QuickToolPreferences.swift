import Foundation
#if canImport(Combine)
import Combine
#endif
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
