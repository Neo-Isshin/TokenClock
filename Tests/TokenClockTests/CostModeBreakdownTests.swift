import XCTest
@testable import TokenClock

final class CostModeBreakdownTests: XCTestCase {
    func testMixedModesPreserveTotalAndSeparateInferredRequests() {
        let requests = [
            ModelUsageRequest(model: "gpt-6.1-sol", buckets: ModelBuckets(input: 100, output: 50, cacheRead: 500),
                              contextInputTokens: 600, serviceTier: .standard),
            ModelUsageRequest(model: "gpt-6.1-sol", buckets: ModelBuckets(input: 300, output: 80, cacheRead: 300_000),
                              contextInputTokens: 300_300, serviceTier: .priority),
            ModelUsageRequest(model: "gpt-6.1-sol", buckets: ModelBuckets(input: 100, output: 20, cacheRead: 200),
                              contextInputTokens: 300, serviceTier: .priority, tierEvidence: .configuration),
            ModelUsageRequest(model: "gpt-6.1-sol", buckets: ModelBuckets(input: 100, output: 10),
                              contextInputTokens: 100, serviceTier: .standard, tierEvidence: .unknown),
        ]
        let split = CostModeBreakdown.make(requests, missingModels: 2)
        XCTAssertEqual(split.total, PricingService.shared.cost(of: requests))
        XCTAssertEqual(split.requestCount, 6)
        XCTAssertEqual(split.parts.map(\.requests), [1, 1, 4])
        XCTAssertEqual(split.parts.reduce(0) { $0 + $1.cost.value }, split.total.value, accuracy: 0.000000001)
        XCTAssertTrue(split.parts[2].formattedCost.hasPrefix("≈"))
        XCTAssertFalse(split.parts[1].rateBadge.isEmpty)
    }

    func testUnpricedRequestsDoNotAppearAsFreeAndDoNotLoseKnownAmounts() {
        let requests = [
            ModelUsageRequest(model: "gpt-6.1-sol", buckets: ModelBuckets(input: 100, output: 10),
                              contextInputTokens: 100),
            ModelUsageRequest(model: "not-a-priced-model-\(UUID().uuidString)",
                              buckets: ModelBuckets(input: 100), contextInputTokens: 100,
                              tierEvidence: .unknown),
        ]
        let split = CostModeBreakdown.make(requests)
        XCTAssertEqual(split.total, PricingService.shared.cost(of: requests))
        XCTAssertEqual(split.parts[2].formattedCost, "—")
        XCTAssertFalse(split.total.complete)
        let missing = CostModeBreakdown.make([], missingModels: 1)
        XCTAssertEqual(missing.parts[2].formattedCost, "—")
    }

    func testLegacyUnclassifiedSplitRetainsOriginalAmount() {
        let cost = CostEstimate(value: 12.34, complete: true, available: true)
        let split = CostModeBreakdown.unclassified(total: cost, requests: 7)
        XCTAssertEqual(split.total, cost)
        XCTAssertEqual(split.parts.first?.mode, .unclassified)
        XCTAssertEqual(split.parts.first?.formattedCost, "≈$12.34")
    }
}
