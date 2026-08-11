#if os(Windows)
import XCTest
@testable import TokenClock

final class TokenAccountingTests: XCTestCase {
    func testInclusiveTotalsExcludeOnlyCacheRead() {
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveTotal: 1_000, cacheRead: 800), 200)
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveTotal: 10, cacheRead: 20), 0)
        XCTAssertEqual(TokenAccounting.excludingCacheRead(inclusiveInput: 100, cacheRead: 40, output: 10, additional: [5]), 75)
    }

    func testSeparateFieldsIncludeCacheWriteButNeverCacheRead() {
        XCTAssertEqual(TokenAccounting.separateCacheFields(input: 10, cacheWrite: 3, output: 5), 18)
        XCTAssertEqual(TokenAccounting.separateCacheFields(input: 10, cacheWrite: 3, output: 5, additional: [7, 2]), 27)
        XCTAssertEqual(TokenAccounting.separateCacheFields(input: Int.max, cacheWrite: 1, output: 0), Int.max)
    }

    func testCacheReadShareUsesFreshPlusReadAsDenominator() {
        XCTAssertEqual(TokenAccounting.cacheReadShare(freshTokens: 60, cacheRead: 40), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(TokenAccounting.cacheReadShare(freshTokens: 0, cacheRead: 0), 0)
    }
}
#endif
