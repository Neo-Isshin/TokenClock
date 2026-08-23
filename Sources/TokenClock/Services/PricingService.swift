import Foundation
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking   // Linux；Windows 走 WinHTTP 原生桥，禁止引入本 DLL
#endif

/// 单个模型的单价，单位 USD / 百万 tokens（与 pricing-snapshot.json 的 `_meta.unit` 一致）。
struct ModelPrice: Equatable, Hashable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    /// Some providers select a higher price tier from the whole request context.
    /// These rates apply to the full request once `contextInputTokens` exceeds the threshold.
    var longContextThreshold: Int?
    var longInput: Double?
    var longOutput: Double?
    var longCacheRead: Double?
    var longCacheWrite: Double?
    /// API Priority multiplier. A value of 1 means the catalog does not publish a premium.
    var priorityMultiplier: Double

    init(
        input: Double,
        output: Double,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        longContextThreshold: Int? = nil,
        longInput: Double? = nil,
        longOutput: Double? = nil,
        longCacheRead: Double? = nil,
        longCacheWrite: Double? = nil,
        priorityMultiplier: Double = 1
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.longContextThreshold = longContextThreshold
        self.longInput = longInput
        self.longOutput = longOutput
        self.longCacheRead = longCacheRead
        self.longCacheWrite = longCacheWrite
        self.priorityMultiplier = priorityMultiplier
    }

    /// Compact catalog keys use USD/MTok. Advanced keys are optional:
    /// lt = full-request long-context threshold, lin/lout/lcr/lcw = long-context rates,
    /// pm = API Priority multiplier.
    fileprivate init?(entry: [String: Any]) {
        guard let input = entry["in"] as? Double,
              let output = entry["out"] as? Double else { return nil }
        self.input = input
        self.output = output
        self.cacheRead = entry["cr"] as? Double ?? 0
        self.cacheWrite = entry["cw"] as? Double ?? 0
        self.longContextThreshold = (entry["lt"] as? NSNumber)?.intValue
        self.longInput = entry["lin"] as? Double
        self.longOutput = entry["lout"] as? Double
        self.longCacheRead = entry["lcr"] as? Double
        self.longCacheWrite = entry["lcw"] as? Double
        self.priorityMultiplier = max(1, entry["pm"] as? Double ?? 1)
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

enum PricingServiceTier: String, Sendable {
    case standard
    case priority
}

/// One billable model request. Request granularity is required for full-request
/// long-context tiers and for service-tier changes inside a session.
struct ModelUsageRequest: Sendable {
    let model: String
    let buckets: ModelBuckets
    /// Whole input context, including cached input, used only to choose a pricing tier.
    let contextInputTokens: Int
    let serviceTier: PricingServiceTier

    init(
        model: String,
        buckets: ModelBuckets,
        contextInputTokens: Int,
        serviceTier: PricingServiceTier = .standard
    ) {
        self.model = model
        self.buckets = buckets
        self.contextInputTokens = max(0, contextInputTokens)
        self.serviceTier = serviceTier
    }
}

/// 计费结果：金额（USD）+ 覆盖标记。
/// 有模型查不到单价时 complete=false —— 金额是下限，UI 以「≈」前缀提示。
struct CostEstimate: Sendable, Hashable {
    var value: Double = 0
    var complete: Bool = true
    var available: Bool = true

    static let zero = CostEstimate(value: 0, complete: true, available: true)
    static let unavailable = CostEstimate(value: 0, complete: false, available: false)

    mutating func merge(_ other: CostEstimate) {
        guard other.available else {
            if available { complete = false }
            return
        }
        if !available {
            self = other
            return
        }
        value += other.value
        complete = complete && other.complete
    }
}

/// 费用估算格式化：< $0.01 显示 "<$0.01"，千位以上不设上限按千分位取整。
/// 不完整覆盖时加「≈」前缀；无数据（tokens 为 0）由调用方显示「—」。
enum CostFormat {
    static func estimate(_ e: CostEstimate) -> String {
        guard e.available else { return "—" }
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
/// - 内置快照：Resources/pricing-snapshot.json，随发版更新。
/// - 刷新缓存：Application Support/TokenClock/pricing-catalog.json，内容格式与快照一致，
///   拉取自 TokenClock 自有 GitHub 仓库的共享目录（与内置格式同构，坏数据不会替换缓存）。
/// - 自定义价格：UserDefaults JSON，优先级最高，覆盖代理/自定义模型（如 glm-5.3）。
///
/// 目录查询发生在后台扫描线程，价格编辑/刷新发生在主线程 —— 用锁保护可变状态。
final class PricingService: @unchecked Sendable {
    static let shared = PricingService()

    /// 目录刷新后广播（ViewModel 收到后增量重扫，30 秒内的下一轮扫描也会自然重算）
    static let catalogUpdatedNotification = Notification.Name("PricingCatalogUpdated")

    /// 四个平台共享的刷新源。统一发布线以 main 为价格目录的单一事实来源。
    private static let refreshURL = URL(string:
        "https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/Sources/TokenClock/Resources/pricing-snapshot.json")!

    private var catalog: [String: ModelPrice] = [:]
    /// 带路由前缀的 key（如 dashscope/glm-5.2）→ 后缀索引；后缀唯一才收录，歧义即弃用
    private var suffixIndex: [String: String] = [:]
    private var customPrices: [String: ModelPrice] = [:]
    /// 查过但没命中的模型名（设置页展示，引导用户补自定义价）
    private var unpriced: Set<String> = []
    private let lock = NSLock()

    /// Defensive pricing aliases for historical callers that may still supply a harness
    /// inference suffix. ModelNormalizer also removes these suffixes for display/grouping.
    private static let pricingAliases: [String: String] = [
        "gemini-3.7-flash-low": "gemini-3.7-flash",
        "gemini-3.7-flash-medium": "gemini-3.7-flash",
        "gemini-3.7-flash-high": "gemini-3.7-flash",
        "grok-4.6": "xai/grok-4.6",
        "kimi-k3": "moonshot/kimi-k3",
        "kimi-k2.7-code": "moonshot/kimi-k2.7-code",
        "kimi-k2.7-code-highspeed": "moonshot/kimi-k2.7-code-highspeed",
        "kimi-k2.6": "moonshot/kimi-k2.6",
        "kimi-k2.5": "moonshot/kimi-k2.5",
        "glm-5.1": "zai/glm-5.1",
        "glm-5": "zai/glm-5",
        "qwen3.8-max": "dashscope/qwen3.8-max",
    ]

    /// 最近一次成功刷新时间；nil = 从未刷新过
    private(set) var lastRefresh: Date?

    private init() {
        loadCustomPrices()
        // Keep the bundled catalog as a guaranteed baseline, then overlay the online cache.
        // A previously downloaded cache can lag behind a new app release and must not hide
        // provider prices added to the newer bundle.
        loadBundledCatalog()
        _ = loadCatalog(from: Self.cacheURL, merging: true)
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
        // 3. Harness-only inference-level suffixes → official billable model ID. A custom
        // override on the official ID still wins over the built-in/online catalog.
        if let alias = Self.pricingAliases[name],
           let p = customPrices[alias] ?? catalog[alias] { return p }
        // 4. 路由前缀索引：dashscope/glm-5.2 ← glm-5.2
        if let key = suffixIndex[name], let p = catalog[key] { return p }
        // 5. 未命中记账
        unpriced.insert(name)
        return nil
    }

    /// 按模型分桶计费。任一模型无价 → 该模型金额计 0 且 complete=false。
    func cost(of buckets: [String: ModelBuckets]) -> CostEstimate {
        guard !buckets.isEmpty else { return .zero }
        var result = CostEstimate.unavailable
        var hasUnpricedModel = false
        for (model, b) in buckets {
            guard let p = price(forModel: model) else {
                hasUnpricedModel = true
                continue
            }
            let value = (Double(b.input) * p.input
                + Double(b.output) * p.output
                + Double(b.cacheRead) * p.cacheRead
                + Double(b.cacheWrite) * p.cacheWrite) / 1_000_000
            result.merge(CostEstimate(value: value, complete: true, available: true))
        }
        if hasUnpricedModel, result.available { result.complete = false }
        return result
    }

    /// Request-granular pricing for providers whose price depends on context size or speed.
    func cost(of requests: [ModelUsageRequest]) -> CostEstimate {
        guard !requests.isEmpty else { return .zero }
        var result = CostEstimate.unavailable
        var hasUnpricedModel = false
        for request in requests {
            guard let price = price(forModel: request.model) else {
                hasUnpricedModel = true
                continue
            }
            let isLongContext = price.longContextThreshold.map {
                request.contextInputTokens > $0
            } ?? false
            let inputRate = isLongContext ? (price.longInput ?? price.input) : price.input
            let outputRate = isLongContext ? (price.longOutput ?? price.output) : price.output
            let cacheReadRate = isLongContext ? (price.longCacheRead ?? price.cacheRead) : price.cacheRead
            let cacheWriteRate = isLongContext ? (price.longCacheWrite ?? price.cacheWrite) : price.cacheWrite
            let multiplier = request.serviceTier == .priority ? price.priorityMultiplier : 1
            let buckets = request.buckets
            let value = (Double(buckets.input) * inputRate
                + Double(buckets.output) * outputRate
                + Double(buckets.cacheRead) * cacheReadRate
                + Double(buckets.cacheWrite) * cacheWriteRate) / 1_000_000 * multiplier
            result.merge(CostEstimate(value: value, complete: true, available: true))
        }
        if hasUnpricedModel, result.available { result.complete = false }
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
        let normalized = ModelNormalizer.normalize(model) ?? model.trimmingCharacters(in: .whitespaces)
        lock.lock()
        if let price {
            customPrices[model] = price
            unpriced.remove(model)
            unpriced.remove(normalized)
        } else {
            customPrices.removeValue(forKey: model)
            unpriced.remove(model)
            unpriced.remove(normalized)
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
        let data: Data
        #if os(Windows)
        // Windows 构建不链接 FoundationNetworking.dll：走 WinHTTP 同步桥
        // （调用方在 Task.detached 里，阻塞无碍；与 WindowsWeather 同一模式）。
        let response = try WindowsNativeHTTP.request(
            url: Self.refreshURL.absoluteString,
            connectTimeout: 10, sendTimeout: 10, receiveTimeout: 30
        )
        guard (200..<300).contains(response.statusCode) else {
            throw PricingError.badResponse
        }
        data = response.body
        #else
        let (fetched, response) = try await URLSession.shared.data(from: Self.refreshURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PricingError.badResponse
        }
        data = fetched
        #endif
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw PricingError.badResponse
        }
        try FileManager.default.createDirectory(
            at: Self.cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        catalog.removeAll(keepingCapacity: true)
        suffixIndex.removeAll(keepingCapacity: true)
        generatedAt = nil
        loadBundledCatalog()
        return loadCatalog(from: Self.cacheURL, merging: true)
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
    private func loadCatalog(from url: URL, merging: Bool = false) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: [String: Any]] else { return false }
        var next: [String: ModelPrice] = merging ? catalog : [:]
        let incomingGeneratedAt = (obj["_meta"] as? [String: Any])?["generatedAt"] as? String
        // A cache downloaded by an older app must be allowed to add missing models, but it
        // must never overwrite newer prices shipped in the current bundle.
        let canOverrideExisting = !merging || generatedAt == nil
            || (incomingGeneratedAt.map { $0 > (generatedAt ?? "") } ?? false)
        var index: [String: String] = [:]
        var suffixSeen = Set<String>()
        for (key, entry) in models {
            guard let p = ModelPrice(entry: entry) else { continue }
            if canOverrideExisting || next[key] == nil { next[key] = p }
        }
        guard !next.isEmpty else { return false }

        // Rebuild from the merged result so suffix ambiguity is detected across both sources.
        for key in next.keys where key.contains("/") {
            let suffix = String(key.split(separator: "/", maxSplits: 1).last ?? "")
            if suffixSeen.contains(suffix) {
                index.removeValue(forKey: suffix) // 歧义后缀弃用
            } else {
                index[suffix] = key
                suffixSeen.insert(suffix)
            }
        }
        catalog = next
        suffixIndex = index
        if !merging || generatedAt == nil
            || (incomingGeneratedAt.map { $0 > (generatedAt ?? "") } ?? false) {
            generatedAt = incomingGeneratedAt
        }
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
