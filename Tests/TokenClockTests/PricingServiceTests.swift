import XCTest
@testable import TokenClock

/// PricingService 计费数学与三层查询逻辑
final class PricingServiceTests: XCTestCase {

    /// 用真实内置快照验证：bundle 资源已正确打包、目录可加载、核心模型在册
    func testBundledSnapshotLoads() {
        let summary = PricingService.shared.catalogSummary
        XCTAssertGreaterThan(summary.count, 100, "内置快照应加载出 100+ 模型，实际 \(summary.count)")
        XCTAssertNotNil(summary.generatedAt, "快照应带 generatedAt 元数据")
        XCTAssertGreaterThanOrEqual(summary.generatedAt ?? "", "2026-08-21T11:30:00Z")
        // 核心模型必须能查到价（脚本侧也有同样的保底断言）
        XCTAssertNotNil(PricingService.shared.price(forModel: "claude-sonnet-4-5"))
        XCTAssertNotNil(PricingService.shared.price(forModel: "gpt-5-codex"))
        XCTAssertEqual(
            PricingService.shared.price(forModel: "MiniMax-M2.7-highspeed"),
            ModelPrice(input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375)
        )
    }

    /// Antigravity appends the thinking level to Gemini's official model ID. Thinking level
    /// changes token consumption, not unit prices, so all variants use the base catalog row.
    func testGeminiThinkingLevelPricingAliases() {
        let base = PricingService.shared.price(forModel: "gemini-3.7-flash")
        XCTAssertEqual(base, ModelPrice(input: 0.75, output: 3.75, cacheRead: 0.075))
        XCTAssertEqual(PricingService.shared.price(forModel: "gemini-3.7-flash-low"), base)
        XCTAssertEqual(PricingService.shared.price(forModel: "gemini-3.7-flash-medium"), base)
        XCTAssertEqual(PricingService.shared.price(forModel: "gemini-3.7-flash-high"), base)
    }

    /// 日期后缀归一化：日志里的带日期模型名应命中目录里的无日期 key
    func testDateSuffixNormalization() {
        let dated = PricingService.shared.price(forModel: "claude-sonnet-4-5-20250929")
        let bare = PricingService.shared.price(forModel: "claude-sonnet-4-5")
        XCTAssertEqual(dated, bare, "带日期后缀的模型名应折算到同一目录条目")
    }

    func testCursorEffortSuffixPricingFallback() {
        let base = "cursor-pricing-test"
        let price = ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)
        PricingService.shared.setCustomPrice(model: base, price: price)
        defer { PricingService.shared.setCustomPrice(model: base, price: nil) }

        XCTAssertEqual(PricingService.shared.price(forModel: "\(base)-medium"), price)
        XCTAssertEqual(PricingService.shared.price(forModel: "\(base)-high-thinking"), price)
    }

    func testCursorClaudeVersionOrderPricingFallback() {
        let price = ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        PricingService.shared.setCustomPrice(model: "claude-opus-9-9", price: price)
        defer { PricingService.shared.setCustomPrice(model: "claude-opus-9-9", price: nil) }

        XCTAssertEqual(PricingService.shared.price(forModel: "claude-9.9-opus-high-thinking"), price)
    }

    /// 计费数学：四桶 × 单价（USD/MTok）÷ 1e6
    func testCostMath() {
        let price = ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        var buckets = ModelBuckets(
            input: 1_000_000, output: 1_000_000,
            cacheRead: 1_000_000, cacheWrite: 1_000_000
        )
        var result = PricingService.shared.cost(of: ["known-model": buckets])
        // 直接算：无目录价 → complete=false；这里仅验证数学，用自定义价保证可命中
        PricingService.shared.setCustomPrice(model: "known-model", price: price)
        defer { PricingService.shared.setCustomPrice(model: "known-model", price: nil) }
        result = PricingService.shared.cost(of: ["known-model": buckets])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.value, 22.05, accuracy: 0.0001)

        // 分桶翻倍，金额翻倍
        buckets.merge(buckets)
        let doubled = PricingService.shared.cost(of: ["known-model": buckets])
        XCTAssertEqual(doubled.value, 44.10, accuracy: 0.0001)
    }

    /// 未计价模型：金额不计入且 complete=false（UI 显示 ≈ 前缀的依据）
    func testUnpricedModelMarksIncomplete() {
        var buckets = ModelBuckets(input: 500_000, output: 0)
        var result = PricingService.shared.cost(of: ["definitely-not-a-real-model-xyz": buckets])
        XCTAssertFalse(result.complete, "查不到价的模型应把估算标记为不完整")
        XCTAssertFalse(result.available, "只有未计价模型时不能把未知金额误报成约 $0.00")
        XCTAssertEqual(result.value, 0, accuracy: 0.0001, "未计价模型金额不计入")

        // 叠加一个有价模型：金额只含已知部分
        buckets.input = 1_000_000
        PricingService.shared.setCustomPrice(model: "priced-companion", price: ModelPrice(input: 2, output: 4))
        defer { PricingService.shared.setCustomPrice(model: "priced-companion", price: nil) }
        result = PricingService.shared.cost(of: [
            "definitely-not-a-real-model-xyz": ModelBuckets(input: 9_999_999),
            "priced-companion": buckets,
        ])
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.available, "有已计价模型时应展示已知部分，并以不完整标记提示")
        XCTAssertEqual(result.value, 2.0, accuracy: 0.0001, "只应计入 priced-companion 的 $2")

        // 未计价模型应进入待补列表（供设置页提示）
        XCTAssertTrue(PricingService.shared.unpricedModels.contains("definitely-not-a-real-model-xyz"))

        PricingService.shared.setCustomPrice(
            model: "definitely-not-a-real-model-xyz",
            price: ModelPrice(input: 1, output: 2)
        )
        defer { PricingService.shared.setCustomPrice(model: "definitely-not-a-real-model-xyz", price: nil) }
        XCTAssertFalse(
            PricingService.shared.unpricedModels.contains("definitely-not-a-real-model-xyz"),
            "保存自定义价后，未计价警告应立即消失"
        )
    }

    /// 自定义价优先级高于目录（覆盖代理模型场景）
    func testCustomPriceOverridesCatalog() {
        let catalogPrice = PricingService.shared.price(forModel: "claude-sonnet-4-5")
        XCTAssertNotNil(catalogPrice)
        let custom = ModelPrice(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1)
        PricingService.shared.setCustomPrice(model: "claude-sonnet-4-5", price: custom)
        defer { PricingService.shared.setCustomPrice(model: "claude-sonnet-4-5", price: nil) }
        XCTAssertEqual(PricingService.shared.price(forModel: "claude-sonnet-4-5"), custom)
        XCTAssertNotEqual(PricingService.shared.price(forModel: "claude-sonnet-4-5"), catalogPrice)
    }

    /// 费用格式化档位
    func testCostFormat() {
        XCTAssertEqual(CostFormat.estimate(.unavailable), "—")
        XCTAssertEqual(CostFormat.estimate(CostEstimate(value: 0, complete: true)), "$0.00")
        XCTAssertEqual(CostFormat.estimate(CostEstimate(value: 0.004, complete: true)), "<$0.01")
        XCTAssertEqual(CostFormat.estimate(CostEstimate(value: 12.345, complete: true)), "$12.35")
        XCTAssertEqual(CostFormat.estimate(CostEstimate(value: 12.345, complete: false)), "≈$12.35")
        XCTAssertEqual(CostFormat.estimate(CostEstimate(value: 1234.5, complete: true)), "$1235")
    }

    /// Codex 计费口径：input 含 cached → 扣除后未缓存输入计价、cached 走缓存读价
    func testCodexBucketsSemantics() {
        let price = ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)
        PricingService.shared.setCustomPrice(model: "codex-test-model", price: price)
        defer { PricingService.shared.setCustomPrice(model: "codex-test-model", price: nil) }
        // input_tokens=1000（含 cached=600），output=400：
        // billed = 400×$1.25/M + 600×$0.125/M + 400×$10/M
        let buckets = ModelBuckets(input: 400, output: 400, cacheRead: 600)
        let result = PricingService.shared.cost(of: ["codex-test-model": buckets])
        let inputCost = 400.0 * 1.25
        let cacheReadCost = 600.0 * 0.125
        let outputCost = 400.0 * 10.0
        let expected = (inputCost + cacheReadCost + outputCost) / 1_000_000.0
        XCTAssertEqual(result.value, expected, accuracy: 0.000001)
    }

    /// Opt-in integration: exercises each platform's real network stack against the catalog
    /// hosted in TokenClock's own GitHub repository. Kept opt-in so ordinary test runs remain
    /// deterministic and offline-friendly.
    func testOnlineRefreshFromTokenClockRepository() async throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_PRICING_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_PRICING_NETWORK_TESTS=1 to test the live catalog")
        }
        try await PricingService.shared.refresh()
        XCTAssertNotNil(PricingService.shared.lastRefresh)
        XCTAssertGreaterThan(PricingService.shared.catalogSummary.count, 100)
        XCTAssertNotNil(PricingService.shared.price(forModel: "gpt-5-codex"))
    }

    /// 端到端：扫本机真实日志，验证扫描层 → 分桶 → 计费全链路出数。
    /// 与性能基准同一开关：TOKENCLOCK_RUN_REAL_DATA_BENCHMARKS=1。
    func testRealDataCostEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_REAL_DATA_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_REAL_DATA_BENCHMARKS=1 to scan local provider data")
        }

        let claude = ClaudeCodeUsageService()
        claude.fullScan()
        let claudeBuckets = claude.todayModelBuckets()
        XCTAssertFalse(claudeBuckets.isEmpty, "本机应有 Claude 今日分桶数据")
        for (model, b) in claudeBuckets {
            print("[real] claude \(model): in=\(b.input) out=\(b.output) cr=\(b.cacheRead) cw=\(b.cacheWrite)")
        }
        let claudeCost = claude.todayCost()
        print("[real] claude today cost = \(CostFormat.estimate(claudeCost)) (complete=\(claudeCost.complete))")
        XCTAssertGreaterThanOrEqual(claudeCost.value, 0)

        let sessions = claude.todaySessions()
        let sessionTotal = sessions.reduce(0.0) { $0 + $1.todayCost.value }
        print("[real] claude \(sessions.count) sessions, session-cost sum ≈ \(String(format: "$%.4f", sessionTotal))")
        // session 费用（含嵌套明细）与工具级费用（仅顶层）口径不同，只做数量级一致性检查
        XCTAssertLessThanOrEqual(sessionTotal, max(1.0, claudeCost.value * 3), "session 费用与工具级费用应处于同一数量级")

        let codex = CodexUsageService()
        codex.fullScan()
        let codexBuckets = codex.todayModelBuckets()
        for (model, b) in codexBuckets {
            print("[real] codex \(model): in=\(b.input) out=\(b.output) cr=\(b.cacheRead)")
        }
        let codexCost = codex.todayCost()
        print("[real] codex today cost = \(CostFormat.estimate(codexCost)) (complete=\(codexCost.complete))")
        XCTAssertGreaterThanOrEqual(codexCost.value, 0)

        if !claudeCost.complete || !codexCost.complete {
            print("[real] 未计价模型: \(PricingService.shared.unpricedModels)")
        }
    }
}
