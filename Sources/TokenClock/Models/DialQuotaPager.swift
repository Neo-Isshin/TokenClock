import Foundation

/// Pages only the already-resolved indicators; changing pages never fetches quota.
struct DialQuotaPager {
    static let maximumSelection = 4
    static let pageSize = 2
    static let interval: TimeInterval = 60
    private(set) var page = 0

    func visible<Element>(from elements: [Element]) -> [Element] {
        guard !elements.isEmpty else { return [] }
        let count = (elements.count + Self.pageSize - 1) / Self.pageSize
        let start = (page % count) * Self.pageSize
        return Array(elements.dropFirst(start).prefix(Self.pageSize))
    }

    mutating func advance(count: Int) {
        let pages = max(1, (count + Self.pageSize - 1) / Self.pageSize)
        page = (page % pages + 1) % pages
    }
}
