import Foundation
#if os(Windows)
import WinSDK
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

struct NetworkDiagnosticRow: Codable, Sendable, Equatable {
    var id: String
    var category: String
    var label: String
    var host: String
    var state: String
    var ip: String?
    var country: String?
    var region: String?
    var city: String?
    var httpStatus: Int?
    var note: String? = nil
    var proxy: Bool? = nil
}

struct NetworkDiagnosticsResult: Codable, Sendable {
    let runID: String
    let rows: [NetworkDiagnosticRow]
}

enum NetworkDiagnosticParser {
    static func address(_ raw: String?) -> String? {
        guard let raw, raw.count <= 45, !raw.contains("%") else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        let family: Int32 = raw.contains(":") ? AF_INET6 : AF_INET
        var text = [CChar](repeating: 0, count: 65)
        #if os(Windows)
        guard raw.withCString({ InetPtonA(family, $0, &bytes) }) == 1,
              InetNtopA(family, &bytes, &text, UInt(text.count)) != nil else { return nil }
        #else
        guard raw.withCString({ inet_pton(family, $0, &bytes) }) == 1,
              inet_ntop(family, &bytes, &text, socklen_t(text.count)) != nil else { return nil }
        #endif
        return String(cString: text)
    }

    static func country(_ raw: String?) -> String? {
        guard let value = raw?.uppercased(), value.utf8.count == 2,
              value.utf8.allSatisfy({ (65...90).contains($0) }), !["XX", "T1"].contains(value) else { return nil }
        return value
    }

    static func trace(_ data: Data) -> (ip: String, country: String?)? {
        guard data.count <= NetworkDiagnosticFetcher.bodyLimit,
              let text = String(data: data, encoding: .utf8), !text.contains("<html") else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let value = address(fields["ip"]) else { return nil }
        // loc is the client country. colo identifies an edge datacentre instead.
        return (value, country(fields["loc"]))
    }

    static func json(_ data: Data) -> [String: Any]? {
        guard data.count <= NetworkDiagnosticFetcher.bodyLimit else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func runID(_ value: String) -> Bool {
        (8...64).contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45
        }
    }
}

struct NetworkDiagnosticReply: Sendable {
    var data: Data
    var status: Int?
    var limited: Bool
    var mime: String? = nil
    var proxy: Bool? = nil
}

/// Per-check transport. Uses the Mac's system proxy/PAC and VPN, with no shared
/// login state. Bounds response bodies before downloading WAF pages or redirects.
#if os(Windows)
final class NetworkDiagnosticFetcher: @unchecked Sendable {
    static let bodyLimit = 16 * 1024
    private let limit: Int
    private let userAgent: String
    private let lock = NSLock()
    private var stopped = false
    init(maximumBodyBytes: Int = NetworkDiagnosticFetcher.bodyLimit, userAgent: String = "TokenClock-NetworkCheck/1") {
        self.limit = maximumBodyBytes; self.userAgent = userAgent
    }
    func fetch(_ url: URL, method: String = "GET") async -> NetworkDiagnosticReply {
        var request = ProviderHTTPRequest(url:url); request.httpMethod = method; return await fetch(request)
    }
    func fetch(_ input: ProviderHTTPRequest) async -> NetworkDiagnosticReply {
        guard !lock.withLock({ stopped }), let url = input.url, ["http","https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil else { return .init(data:Data(),status:nil,limited:false) }
        var request = input
        request.setValue(userAgent,forHTTPHeaderField:"User-Agent")
        let transportRequest = request
        let reply = await Task.detached(priority:.utility) { [limit] in
            guard let response = try? WindowsNativeHTTP.request(url:url.absoluteString,method:transportRequest.httpMethod ?? "GET",
                headers:transportRequest.allHTTPHeaderFields ?? [:],body:transportRequest.httpBody,connectTimeout:8,sendTimeout:8,receiveTimeout:8,
                maximumResponseBytes:limit) else { return NetworkDiagnosticReply(data:Data(),status:nil,limited:false) }
            return NetworkDiagnosticReply(data:response.body,status:response.statusCode,limited:response.body.count>limit)
        }.value
        return lock.withLock { stopped ? .init(data:Data(),status:nil,limited:false) : reply }
    }
    func cancel() { lock.withLock { stopped=true } }
}
#else
final class NetworkDiagnosticFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let bodyLimit = 16 * 1024
    private let maximumBodyBytes: Int
    private let userAgent: String
    private struct Pending {
        let continuation: CheckedContinuation<NetworkDiagnosticReply, Never>
        var data = Data()
        var status: Int?
        var limited = false
        var mime: String?
        var proxy: Bool?
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var stopped = false
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .ephemeral, maximumBodyBytes: Int = NetworkDiagnosticFetcher.bodyLimit,
         userAgent: String = "TokenClock-NetworkCheck/1") {
        self.maximumBodyBytes = maximumBodyBytes
        self.userAgent = userAgent
        super.init()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, head: Bool = false) async -> NetworkDiagnosticReply {
        var request = ProviderHTTPRequest(url: url)
        request.httpMethod = head ? "HEAD" : "GET"
        return await fetch(request)
    }

    func fetch(_ request: ProviderHTTPRequest) async -> NetworkDiagnosticReply {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !stopped else {
                    lock.unlock()
                    continuation.resume(returning: .init(data: Data(), status: nil, limited: false))
                    return
                }
                var request = request
                request.httpShouldHandleCookies = false
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request)
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock(); stopped = true; lock.unlock()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.mime = response.mimeType
        pending[dataTask.taskIdentifier]?.status = (response as? HTTPURLResponse)?.statusCode
        let tooLarge = response.expectedContentLength > maximumBodyBytes
        if tooLarge { pending[dataTask.taskIdentifier]?.limited = true }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var row = pending[dataTask.taskIdentifier]
        let tooLarge = (row?.data.count ?? 0) + data.count > maximumBodyBytes
        if tooLarge { row?.limited = true }
        else { row?.data.append(data) }
        pending[dataTask.taskIdentifier] = row
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let row = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        row?.continuation.resume(returning: .init(data: row?.data ?? Data(), status: row?.status, limited: row?.limited ?? false, mime:row?.mime, proxy:row?.proxy))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); pending[task.taskIdentifier]?.proxy = metrics.transactionMetrics.last?.isProxyConnection; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: ProviderHTTPRequest, completionHandler: @escaping (ProviderHTTPRequest?) -> Void) {
        // A login redirect is reachability evidence only. Never follow it with
        // account state, and never allow a diagnostic target to select a new host.
        completionHandler(nil)
    }
}

#endif

enum NetworkDiagnostics {
    struct Target: Sendable {
        let id: String, category: String, label: String, url: String
        var head = false
    }

    static let targets: [Target] = [
        .init(id: "ailyre", category: "exit", label: "Ailyre", url: "https://www.ailyre.com/cdn-cgi/trace"),
        .init(id: "cloudflare", category: "exit", label: "Cloudflare", url: "https://www.cloudflare.com/cdn-cgi/trace"),
        .init(id: "ipify", category: "exit", label: "ipify IPv4", url: "https://api.ipify.org?format=json"),
        .init(id: "ipv6", category: "ipv6", label: "ipify IPv6", url: "https://api6.ipify.org?format=json"),
        .init(id: "chatgpt", category: "ai", label: "ChatGPT", url: "https://chatgpt.com/cdn-cgi/trace"),
        .init(id: "claude", category: "ai", label: "Claude", url: "https://claude.ai/cdn-cgi/trace"),
        .init(id: "gemini", category: "ai", label: "Gemini", url: "https://gemini.google.com/robots.txt", head: true),
        .init(id: "openai-api", category: "ai", label: "OpenAI API", url: "https://api.openai.com/cdn-cgi/trace"),
        .init(id: "anthropic-api", category: "ai", label: "Anthropic API", url: "https://api.anthropic.com/cdn-cgi/trace"),
        .init(id: "xai-api", category: "ai", label: "xAI API", url: "https://api.x.ai/cdn-cgi/trace")
    ]

    static func parse(_ reply: NetworkDiagnosticReply, target: Target) -> NetworkDiagnosticRow {
        var row = NetworkDiagnosticRow(id: target.id, category: target.category, label: target.label,
                                       host: URL(string: target.url)!.host!, state: reply.status == nil ? "unavailable" : "responded",
                                       httpStatus: reply.status, proxy:reply.proxy)
        guard reply.status == 200, !reply.limited else { return row }
        if target.id == "ipify" || target.id == "ipv6" {
            row.ip = NetworkDiagnosticParser.address(NetworkDiagnosticParser.json(reply.data)?["ip"] as? String)
            // A proxy returning IPv4 for an IPv6-only probe is not IPv6 evidence.
            if target.id == "ipv6", row.ip?.contains(":") != true { row.ip = nil }
        } else if let result = NetworkDiagnosticParser.trace(reply.data) {
            row.ip = result.ip; row.country = result.country
        }
        if row.ip != nil { row.state = "observed" }
        return row
    }

    static func run(runID: String, baselineIP: String?, fetcher: NetworkDiagnosticFetcher, dnsToken: String? = nil) async -> NetworkDiagnosticsResult {
        var rows = await withTaskGroup(of: NetworkDiagnosticRow.self) { group in
            for target in targets {
                group.addTask { parse(await fetcher.fetch(URL(string: target.url)!, head: target.head), target: target) }
            }
            var rows: [NetworkDiagnosticRow] = []
            for await row in group { rows.append(row) }
            return rows
        }
        if Task.isCancelled { return .init(runID: runID, rows: []) }
        var addresses: [String] = []
        if let ip = NetworkDiagnosticParser.address(baselineIP) { addresses.append(ip) }
        if let ip = rows.first(where: { $0.id == "ipv6" })?.ip, !addresses.contains(ip) { addresses.append(ip) }
        // Two providers look up the same explicit IP. Do not compare the location
        // of the API request's own egress with a different VPN endpoint.
        async let dohRows = DoHDiagnostics.run(token:dnsToken,baseline:baselineIP,fetcher:fetcher)
        let locations = await withTaskGroup(of: NetworkDiagnosticRow.self) { group in
            for ip in addresses {
                for source in ["ipwho", "countryis"] {
                    group.addTask {
                        let url = source == "ipwho" ? "https://ipwho.is/\(ip)?fields=ip,success,country_code,region,city"
                            : "https://api.country.is/\(ip)"
                        let reply = await fetcher.fetch(URL(string: url)!)
                        var row = NetworkDiagnosticRow(id: source + "-" + ip, category: "geo",
                            label: source == "ipwho" ? "IPWhois" : "Country.is", host: URL(string: url)!.host!, state: "unavailable", ip: ip)
                        if reply.status == 200, !reply.limited, let data = NetworkDiagnosticParser.json(reply.data),
                           NetworkDiagnosticParser.address(data["ip"] as? String) == ip,
                           data["success"] as? Bool != false {
                            row.country = NetworkDiagnosticParser.country((data["country_code"] ?? data["country"]) as? String)
                            row.region = (data["region"] as? String).map { String($0.prefix(100)) }
                            row.city = (data["city"] as? String).map { String($0.prefix(100)) }
                            if row.country != nil { row.state = "observed" }
                        }
                        return row
                    }
                }
            }
            var result: [NetworkDiagnosticRow] = []
            for await row in group { result.append(row) }
            return result
        }
        rows += locations
        rows += await dohRows
        return .init(runID: runID, rows: rows.sorted { $0.id < $1.id })
    }
}
