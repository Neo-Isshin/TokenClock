import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 单个模型的单价，单位 USD / 百万 tokens（与 pricing-snapshot.json 的 `_meta.unit` 一致）。
struct ModelPrice: Equatable, Hashable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// 从快照条目（键 in/out/cr/cw，USD/MTok）解码；缺 cr/cw 视为 0（如 OpenAI 无缓存写计价）。
    fileprivate init?(entry: [String: Any]) {
        guard let input = entry["in"] as? Double,
              let output = entry["out"] as? Double else { return nil }
        self.input = input
        self.output = output
        self.cacheRead = entry["cr"] as? Double ?? 0
        self.cacheWrite = entry["cw"] as? Double ?? 0
    }
}

/// 一段用量按计费口径的分桶（token 数）。
/// Claude 日志四桶天然齐备；Codex 的 input 已含 cached，拆为 input(未缓存) + cacheRead。
struct ModelBuckets: Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    var totalTokens: Int { input + output + cacheRead }

    mutating func merge(_ other: ModelBuckets) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

/// 计费结果：金额（USD）+ 覆盖标记。
/// 有模型查不到单价时 complete=false —— 金额是下限，UI 以「≈」前缀提示。
struct CostEstimate: Sendable, Hashable {
    var value: Double = 0
    var complete: Bool = true

    static let zero = CostEstimate(value: 0, complete: true)

    mutating func merge(_ other: CostEstimate) {
        value += other.value
        complete = complete && other.complete
    }
}

/// 费用估算格式化：< $0.01 显示 "<$0.01"，千位以上不设上限按千分位取整。
/// 不完整覆盖时加「≈」前缀；无数据（tokens 为 0）由调用方显示「—」。
enum CostFormat {
    static func estimate(_ e: CostEstimate) -> String {
        let body: String
        if e.value < 0.005 && e.value > 0 {
            body = "<$0.01"
        } else if e.value >= 1000 {
            let n = Int(e.value.rounded())
            body = String(format: "$%d", n)
        } else {
            body = String(format: "$%.2f", e.value)
        }
        return e.complete ? body : "≈\(body)"
    }
}

/// 模型价格目录服务：三层查询（用户自定义 > 在线刷新缓存 > 内置快照）。
///
/// - 内置快照：Resources/pricing-snapshot.json，随发版更新（CI 每周自动 PR）。
/// - 刷新缓存：Application Support/TokenClock/pricing-catalog.json，内容格式与快照一致，
///   拉取自本仓库 main 分支的 raw 地址（与内置格式永远同构，坏数据不会破坏解析）。
/// - 自定义价格：UserDefaults JSON，优先级最高，覆盖代理/自定义模型（如 glm-5.3）。
///
/// 目录查询发生在后台扫描线程，价格编辑/刷新发生在主线程 —— 用锁保护可变状态。
final class PricingService: @unchecked Sendable {
    static let shared = PricingService()

    /// 目录刷新后广播（ViewModel 收到后增量重扫，30 秒内的下一轮扫描也会自然重算）
    static let catalogUpdatedNotification = Notification.Name("PricingCatalogUpdated")

    /// 刷新源：本仓库 main 分支的快照 raw 地址（由 CI 每周更新）
    private static let refreshURL = URL(string:
        "https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/Sources/TokenClock/Resources/pricing-snapshot.json")!

    private var catalog: [String: ModelPrice] = [:]
    /// 带路由前缀的 key（如 dashscope/glm-5.2）→ 后缀索引；后缀唯一才收录，歧义即弃用
    private var suffixIndex: [String: String] = [:]
    private var customPrices: [String: ModelPrice] = [:]
    /// 查过但没命中的模型名（设置页展示，引导用户补自定义价）
    private var unpriced: Set<String> = []
    private let lock = NSLock()

    /// 最近一次成功刷新时间；nil = 从未刷新过
    private(set) var lastRefresh: Date?

    private init() {
        loadCustomPrices()
        // 刷新缓存（若存在）优先于内置快照
        if !loadCatalog(from: Self.cacheURL) {
            loadBundledCatalog()
        }
        let ts = UserDefaults.standard.double(for: .pricingLastRefresh)
        if ts > 0 { lastRefresh = Date(timeIntervalSince1970: ts) }
    }

    // MARK: - 查询

    /// 查模型单价。raw 为工具日志里的原始模型名，会先过 ModelNormalizer 去日期后缀。
    func price(forModel raw: String) -> ModelPrice? {
        let name = ModelNormalizer.normalize(raw) ?? raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        lock.lock(); defer { lock.unlock() }
        // 1. 用户自定义（原始名与归一名都试）
        if let p = customPrices[name] ?? customPrices[raw] { return p }
        // 2. 目录精确命中（一方模型是无前缀规范名，与归一化结果直接对齐）
        if let p = catalog[name] { return p }
        if let p = catalog[raw] { return p }
        // 3. 路由前缀索引：dashscope/glm-5.2 ← glm-5.2
        if let key = suffixIndex[name], let p = catalog[key] { return p }
        // 4. 未命中记账
        unpriced.insert(name)
        return nil
    }

    /// 按模型分桶计费。任一模型无价 → 该模型金额计 0 且 complete=false。
    func cost(of buckets: [String: ModelBuckets]) -> CostEstimate {
        var result = CostEstimate.zero
        for (model, b) in buckets {
            guard let p = price(forModel: model) else {
                result.complete = false
                continue
            }
            result.value += (Double(b.input) * p.input
                + Double(b.output) * p.output
                + Double(b.cacheRead) * p.cacheRead
                + Double(b.cacheWrite) * p.cacheWrite) / 1_000_000
        }
        return result
    }

    /// 查过但目录覆盖不到的模型名（供设置页提示补价）
    var unpricedModels: [String] {
        lock.lock(); defer { lock.unlock() }
        return unpriced.sorted()
    }

    /// 当前目录条数 + 数据时点（设置页展示）
    var catalogSummary: (count: Int, generatedAt: String?) {
        lock.lock(); defer { lock.unlock() }
        return (catalog.count, generatedAt)
    }

    private var generatedAt: String?

    // MARK: - 自定义价格

    func setCustomPrice(model: String, price: ModelPrice?) {
        lock.lock()
        if let price {
            customPrices[model] = price
        } else {
            customPrices.removeValue(forKey: model)
            unpriced.remove(model)
        }
        lock.unlock()
        saveCustomPrices()
    }

    func customPrice(for model: String) -> ModelPrice? {
        lock.lock(); defer { lock.unlock() }
        return customPrices[model]
    }

    var customModels: [String] {
        lock.lock(); defer { lock.unlock() }
        return customPrices.keys.sorted()
    }

    // MARK: - 刷新

    /// 是否到了每周自动刷新的时点
    func isStale(maxAge: TimeInterval = 7 * 86_400) -> Bool {
        guard let last = lastRefresh else { return true }
        return Date().timeIntervalSince(last) > maxAge
    }

    /// 拉取远端快照写入缓存并重建目录。失败抛错（调用方决定是否提示）。
    func refresh() async throws {
        let (data, _) = try await URLSession.shared.data(from: Self.refreshURL)
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw PricingError.badResponse
        }
        try data.write(to: Self.cacheURL)
        guard applyRefreshedCatalog() else { throw PricingError.badResponse }

        let stamp = Date()
        recordRefresh(stamp)
        UserDefaults.standard.setDouble(stamp.timeIntervalSince1970, for: .pricingLastRefresh)
        NotificationCenter.default.post(name: Self.catalogUpdatedNotification, object: nil)
    }

    /// 同步上下文里持锁重建目录（Swift 6 禁止在 async 函数里直接 NSLock）
    private func applyRefreshedCatalog() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadCatalog(from: Self.cacheURL)
    }

    private func recordRefresh(_ stamp: Date) {
        lock.lock(); defer { lock.unlock() }
        lastRefresh = stamp
    }

    enum PricingError: LocalizedError {
        case badResponse
        var errorDescription: String? { "invalid pricing catalog" }
    }

    private static var cacheURL: URL {
        URL(fileURLWithPath: AppPaths.appSupport("TokenClock", "pricing-catalog.json"))
    }

    // MARK: - 目录加载

    /// 解析快照/缓存 JSON 填充 catalog。调用方需持锁。
    @discardableResult
    private func loadCatalog(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: [String: Any]] else { return false }
        var next: [String: ModelPrice] = [:]
        var index: [String: String] = [:]
        var suffixSeen = Set<String>()
        for (key, entry) in models {
            guard let p = ModelPrice(entry: entry) else { continue }
            next[key] = p
            guard key.contains("/") else { continue }
            let suffix = String(key.split(separator: "/", maxSplits: 1).last ?? "")
            if suffixSeen.contains(suffix) {
                index.removeValue(forKey: suffix) // 歧义后缀弃用
            } else {
                index[suffix] = key
                suffixSeen.insert(suffix)
            }
        }
        guard !next.isEmpty else { return false }
        catalog = next
        suffixIndex = index
        generatedAt = (obj["_meta"] as? [String: Any])?["generatedAt"] as? String
        return true
    }

    private func loadBundledCatalog() {
        guard let url = Bundle.module.url(forResource: "pricing-snapshot", withExtension: "json") else {
            return
        }
        loadCatalog(from: url)
    }

    // MARK: - 自定义价格持久化（UserDefaults JSON，键 in/out/cr/cw，USD/MTok）

    private static let customPricesKey = SettingsKey.customModelPrices.rawValue

    private func loadCustomPrices() {
        guard let s = UserDefaults.standard.string(forKey: Self.customPricesKey),
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        var result: [String: ModelPrice] = [:]
        for (model, entry) in obj {
            if let p = ModelPrice(entry: entry) { result[model] = p }
        }
        customPrices = result
    }

    private func saveCustomPrices() {
        let obj = customPrices.mapValues { p in
            ["in": p.input, "out": p.output, "cr": p.cacheRead, "cw": p.cacheWrite] as [String: Double]
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: Self.customPricesKey)
    }
}
