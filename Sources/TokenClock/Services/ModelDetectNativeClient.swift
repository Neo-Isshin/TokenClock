#if os(macOS)
import Foundation

/// Typed JSON crossing the local service boundary. No untyped values cross tasks.
enum ModelDetectJSON: Codable, Sendable, Equatable {
    case object([String: ModelDetectJSON])
    case array([ModelDetectJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(_ key: String) -> ModelDetectJSON { object[key] ?? .null }
    var object: [String: ModelDetectJSON] { if case .object(let value) = self { return value }; return [:] }
    var array: [ModelDetectJSON] { if case .array(let value) = self { return value }; return [] }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Double.self), item.isFinite { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([ModelDetectJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: ModelDetectJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

@MainActor
protocol ModelDetectNativeServing: AnyObject {
    /// nil body is GET; a JSON body is POST. Does not retry or launch a worker.
    func request(_ route: String, body: ModelDetectJSON?) async throws -> ModelDetectJSON
    /// Only fixed report filenames are accepted. Always requests original bytes.
    func download(_ route: String) async throws -> Data
}

enum ModelDetectNativeClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidReadyURL, invalidRoute, invalidJSON, invalidResponse
    case requestTooLarge, responseTooLarge, redirectRefused, unexpectedOrigin
    case cancelled, transportUnavailable
    case service(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidReadyURL: return "本地检测服务地址无效，请重新启动检测面板。"
        case .invalidRoute: return "不支持这项本地检测操作。"
        case .invalidJSON: return "本地检测数据不是有效的 JSON。"
        case .invalidResponse: return "本地检测服务返回了无法识别的数据。"
        case .requestTooLarge: return "发送的数据超出本地检测接口大小限制。"
        case .responseTooLarge: return "检测结果超出本次读取大小限制。"
        case .redirectRefused: return "本地检测服务尝试重定向，请重新启动检测面板。"
        case .unexpectedOrigin: return "检测响应不属于当前本地服务。"
        case .cancelled: return "本次本地请求已取消。"
        case .transportUnavailable: return "暂时无法连接本地检测服务，请检查服务是否仍在运行。"
        case .service(let status, let message): return "本地检测服务（\(status)）：\(message)"
        }
    }
}

struct ModelDetectNativeHTTPResponse: Sendable {
    let data: Data
    let url: URL?
    let statusCode: Int
    let contentType: String?
}

/// Injection is for local tests only; the production transport is always bounded
/// and ephemeral. Authentication lives in the ready path, never in stored headers.
protocol ModelDetectNativeTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ModelDetectNativeHTTPResponse
}

struct ModelDetectURLSessionTransport: ModelDetectNativeTransport, @unchecked Sendable {
    // Test-only URLProtocol injection. Production callers use the empty default.
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ModelDetectNativeHTTPResponse {
        try await ModelDetectBoundedTransfer(maximumBytes: maximumBytes, protocolClasses: protocolClasses).run(request)
    }
}

@MainActor
final class ModelDetectNativeClient: ModelDetectNativeServing {
    static let maximumRequestBytes = 90 * 1024 * 1024
    static let maximumJSONBytes = 32 * 1024 * 1024
    static let maximumDownloadBytes = 256 * 1024 * 1024
    private let baseURL: URL
    private let origin: String
    private let host: String
    private let transport: any ModelDetectNativeTransport
    private let jsonLimit: Int
    private let downloadLimit: Int

    init(baseURL: URL,
         transport: any ModelDetectNativeTransport = ModelDetectURLSessionTransport(),
         maximumJSONBytes: Int = ModelDetectNativeClient.maximumJSONBytes,
         maximumDownloadBytes: Int = ModelDetectNativeClient.maximumDownloadBytes) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.percentEncodedPath == parts.path,
              Self.matches(parts.path, pattern: #"^/s/[A-Za-z0-9_-]{16,128}/$"#),
              maximumJSONBytes > 0, maximumJSONBytes <= Self.maximumJSONBytes,
              maximumDownloadBytes > 0, maximumDownloadBytes <= Self.maximumDownloadBytes else {
            throw ModelDetectNativeClientError.invalidReadyURL
        }
        self.baseURL = baseURL
        self.host = "127.0.0.1:\(port)"
        self.origin = "http://127.0.0.1:\(port)"
        self.transport = transport
        self.jsonLimit = maximumJSONBytes
        self.downloadLimit = maximumDownloadBytes
    }

    func request(_ route: String, body: ModelDetectJSON? = nil) async throws -> ModelDetectJSON {
        if Task.isCancelled { throw ModelDetectNativeClientError.cancelled }
        let request = try await makeRequest(route, body: body, originalDownload: false)
        let data = try await receive(request, maximumBytes: jsonLimit, secrets: Self.secrets(in: body))
        do {
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(ModelDetectJSON.self, from: data)
            }.value
            if Task.isCancelled { throw ModelDetectNativeClientError.cancelled }
            return decoded
        }
        catch let error as ModelDetectNativeClientError { throw error }
        catch { throw ModelDetectNativeClientError.invalidJSON }
    }

    func download(_ route: String) async throws -> Data {
        if Task.isCancelled { throw ModelDetectNativeClientError.cancelled }
        let request = try await makeRequest(route, body: nil, originalDownload: true)
        return try await receive(request, maximumBytes: downloadLimit, secrets: [])
    }

    private func makeRequest(_ route: String, body: ModelDetectJSON?, originalDownload: Bool) async throws -> URLRequest {
        guard Self.allowed(route, post: body != nil, download: originalDownload),
              var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ModelDetectNativeClientError.invalidRoute
        }
        parts.path += route
        if originalDownload { parts.queryItems = [URLQueryItem(name: "download", value: "1")] }
        guard let url = parts.url else { throw ModelDetectNativeClientError.invalidRoute }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(originalDownload ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        if let body {
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try JSONEncoder().encode(body)
                }.value
            }
            catch { throw ModelDetectNativeClientError.invalidJSON }
            guard data.count <= Self.maximumRequestBytes else { throw ModelDetectNativeClientError.requestTooLarge }
            request.httpBody = data
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func receive(_ request: URLRequest, maximumBytes: Int, secrets: [String]) async throws -> Data {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            guard response.url == request.url else { throw ModelDetectNativeClientError.unexpectedOrigin }
            guard response.data.count <= maximumBytes else { throw ModelDetectNativeClientError.responseTooLarge }
            if (300...399).contains(response.statusCode) { throw ModelDetectNativeClientError.redirectRefused }
            guard (200...299).contains(response.statusCode) else {
                var message = "请求未完成，请检查输入后重试。"
                if response.data.count <= 16 * 1024,
                   let value = try? JSONDecoder().decode(ModelDetectJSON.self, from: response.data),
                   let reported = value["error"].string {
                    message = safeMessage(reported, secrets: secrets)
                }
                throw ModelDetectNativeClientError.service(status: response.statusCode, message: message)
            }
            return response.data
        } catch is CancellationError {
            throw ModelDetectNativeClientError.cancelled
        } catch let error as ModelDetectNativeClientError {
            throw error
        } catch {
            // Foundation errors can embed the complete ready URL and its token.
            // Never include underlying error text, URL, response body or headers.
            throw ModelDetectNativeClientError.transportUnavailable
        }
    }

    private func safeMessage(_ raw: String, secrets: [String]) -> String {
        var text = raw.replacingOccurrences(of: baseURL.absoluteString, with: "[本地地址已隐藏]")
        text = text.replacingOccurrences(of: baseURL.path, with: "[本地地址已隐藏]")
        if let token = baseURL.path.split(separator: "/").last {
            text = text.replacingOccurrences(of: String(token), with: "[本地会话凭据已隐藏]")
        }
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[凭据已隐藏]")
        }
        let patterns = [
            #"https?://[^\s<>「」“”，。；]+"#,
            #"/s/[A-Za-z0-9_-]{1,128}/?"#,
            #"\bsk-(?:or-v\d+-)?[A-Za-z0-9_-]{12,}"#,
            #"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{12,}"#,
            #"Bearer\s+[A-Za-z0-9._~+/-]{8,}=*"#,
            #"(?:api[_-]?key|access[_-]?token|authorization|password|secret)\s*[=:：]\s*[^\s,;]+"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[敏感信息已隐藏]")
            }
        }
        return String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(500))
    }

    private static func secrets(in value: ModelDetectJSON?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .object(let fields):
            return fields.flatMap { key, item in
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                if ["apikey", "accesstoken", "authorization", "password", "secret"].contains(normalized), let string = item.string { return [string] }
                return secrets(in: item)
            }
        case .array(let values): return values.flatMap { secrets(in: $0) }
        default: return []
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private static func allowed(_ route: String, post: Bool, download: Bool) -> Bool {
        guard route.utf8.count <= 512, !route.contains("%"), !route.contains("\\"),
              !route.contains("?"), !route.contains("#") else { return false }
        let parts = route.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        func job(_ value: String) -> Bool { matches(value, pattern: #"^job-[a-f0-9]{32}$"#) }
        let reportFiles = ["report.html", "report.json", "observation.json", "evidence.zip"]
        if download { return !post && parts.count == 3 && parts[0] == "reports" && job(parts[1]) && reportFiles.contains(parts[2]) }
        if post {
            if ["api/connections", "api/connections/delete", "api/model-catalog", "api/preview", "api/jobs", "api/upload", "api/combine"].contains(route) { return true }
            return parts.count == 4 && parts[0] == "api" && parts[1] == "jobs" && job(parts[2]) && ["cancel", "resume"].contains(parts[3])
        }
        if ["api/info", "api/sessions", "api/connections", "api/probes", "api/jobs"].contains(route) { return true }
        if parts.count == 3 && parts[0] == "api" && parts[1] == "jobs" && job(parts[2]) { return true }
        if parts.count == 3 && parts[0] == "reports" && job(parts[1]) && ["report.json", "observation.json"].contains(parts[2]) { return true }
        return parts.count == 2 && parts[0] == "support" && job(parts[1])
    }
}

/// One ephemeral, bounded transfer. The lock protects delegate callbacks and
/// task cancellation; completion is resumed once and buffers are never cached.
private final class ModelDetectBoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let protocolClasses: [AnyClass]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ModelDetectNativeHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var expectedURL: URL?
    private var body = Data()
    private var finished = false

    init(maximumBytes: Int, protocolClasses: [AnyClass]? = nil) {
        self.maximumBytes = maximumBytes; self.protocolClasses = protocolClasses
    }

    func run(_ request: URLRequest) async throws -> ModelDetectNativeHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished { lock.unlock(); continuation.resume(throwing: ModelDetectNativeClientError.cancelled); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                if let protocolClasses { configuration.protocolClasses = protocolClasses }
                configuration.urlCache = nil
                configuration.urlCredentialStorage = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                          "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 180
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session; self.task = task; self.expectedURL = request.url
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(ModelDetectNativeClientError.cancelled))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ModelDetectNativeClientError.redirectRefused))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(ModelDetectNativeClientError.invalidResponse)); return
        }
        lock.lock(); let expected = expectedURL; lock.unlock()
        guard http.url == expected else {
            completionHandler(.cancel); finish(.failure(ModelDetectNativeClientError.unexpectedOrigin)); return
        }
        if (300...399).contains(http.statusCode) {
            completionHandler(.cancel); finish(.failure(ModelDetectNativeClientError.redirectRefused)); return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(ModelDetectNativeClientError.responseTooLarge)); return
        }
        lock.lock(); self.response = http; let stopped = finished; lock.unlock()
        completionHandler(stopped ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if data.count > maximumBytes - body.count {
            lock.unlock(); finish(.failure(ModelDetectNativeClientError.responseTooLarge)); return
        }
        body.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(ModelDetectNativeClientError.transportUnavailable)); return }
        lock.lock(); let response = response; let data = body; lock.unlock()
        guard let response else { finish(.failure(ModelDetectNativeClientError.invalidResponse)); return }
        finish(.success(ModelDetectNativeHTTPResponse(data: data, url: response.url, statusCode: response.statusCode,
                                                    contentType: response.value(forHTTPHeaderField: "Content-Type"))))
    }

    private func finish(_ result: Result<ModelDetectNativeHTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil
        let task = task; self.task = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
#endif
