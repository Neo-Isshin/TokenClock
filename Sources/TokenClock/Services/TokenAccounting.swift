import Foundation

/// Canonical token accounting used by every provider reader.
enum TokenAccounting {
    static func excludingCacheRead(inclusiveTotal: Int, cacheRead: Int) -> Int {
        let total = max(0, inclusiveTotal)
        let read = max(0, cacheRead)
        return total - min(total, read)
    }

    static func excludingCacheRead(
        inclusiveInput: Int, cacheRead: Int = 0, output: Int = 0, additional: [Int] = []
    ) -> Int {
        let input = max(0, inclusiveInput)
        let read = max(0, cacheRead)
        return saturatingSum([input - min(input, read), output] + additional)
    }

    static func separateCacheFields(
        input: Int, cacheWrite: Int = 0, output: Int, additional: [Int] = []
    ) -> Int {
        saturatingSum([input, cacheWrite, output] + additional)
    }

    static func cacheReadShare(freshTokens: Int, cacheRead: Int) -> Double {
        let fresh = Double(max(0, freshTokens))
        let read = Double(max(0, cacheRead))
        let denominator = fresh + read
        return denominator > 0 ? read / denominator : 0
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        var result = 0
        for value in values where value > 0 {
            let (next, overflow) = result.addingReportingOverflow(value)
            if overflow { return Int.max }
            result = next
        }
        return result
    }
}
