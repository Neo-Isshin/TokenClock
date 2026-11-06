import Foundation
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif
#if os(Windows)
/// Request data only. Windows transport stays on WinHTTP, without FoundationNetworking.
struct ProviderHTTPRequest: Sendable {
    enum CachePolicy: Sendable { case reloadIgnoringLocalCacheData }
    var url: URL?
    var httpMethod: String? = "GET"
    var httpBody: Data?
    var httpShouldHandleCookies = false
    var timeoutInterval: TimeInterval = 8
    var cachePolicy: CachePolicy = .reloadIgnoringLocalCacheData
    var allHTTPHeaderFields: [String:String]? = [:]
    init(url: URL) { self.url = url }
    mutating func setValue(_ value: String?, forHTTPHeaderField name: String) {
        let existing = allHTTPHeaderFields?.keys.first { $0.lowercased() == name.lowercased() }
        if let existing { allHTTPHeaderFields?.removeValue(forKey:existing) }
        if let value { allHTTPHeaderFields?[name] = value }
    }
    func value(forHTTPHeaderField name: String) -> String? {
        allHTTPHeaderFields?.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}
#else
typealias ProviderHTTPRequest = URLRequest
#endif
