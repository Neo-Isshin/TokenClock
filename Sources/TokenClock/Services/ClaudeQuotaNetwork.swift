#if os(macOS)
import Foundation
import CFNetwork
import Darwin

/// Claude quota only. Follow the selected system route by default (including
/// direct/TUN). A selected proxy is immutable for that request and never falls
/// back to direct. Requiring an explicit proxy is a separate opt-in policy.
enum ClaudeQuotaNetwork {
    enum Mode: Sendable { case system, requireProxy }
    static func mode(defaults: UserDefaults = .standard) -> Mode {
        defaults.bool(forKey: SettingsKey.claudeQuotaRequireProxy.rawValue) ? .requireProxy : .system
    }
    #if TOKENCLOCK_PROXY_TESTS
    // Only the standalone loopback test binary defines this flag. No trust
    // override exists in the app build, and no system trust store is changed.
    nonisolated(unsafe) static var fixtureAnchorPath: String?
    #endif
    enum Failure: String, Error, Sendable {
        case proxyRequired = "quota.claudeProxyRequired"
        case requestFailed = "quota.claudeProxyRequestFailed"
    }
    struct Response: Sendable {
        let status: Int
        let data: Data
        let challenge: Bool
    }
    struct Route: Equatable, Sendable {
        enum Kind: String, Sendable { case http, https, socks5 }
        let kind: Kind
        let host: String
        let port: UInt16
        var username: String? = nil
        var password: String? = nil

        var proxyURL: String {
            let address = host.contains(":") ? "[" + host + "]" : host
            return (kind == .socks5 ? "socks5h" : kind.rawValue) + "://" + address + ":" + String(port)
        }
    }

    struct Invocation {
        let arguments: [String]
        let configuration: Data
        let environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
    }

    static func invocation(_ request: URLRequest, route: Route?) throws -> Invocation {
        guard let url = request.url, url.scheme == "https", request.httpMethod == "GET" else { throw Failure.requestFailed }
        func quote(_ value: String) throws -> String {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.requestFailed }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // nil is a deliberately selected OS route, never an error fallback.
        // Empty proxy prevents curl's ambient config from changing that choice;
        // OS routing (including TUN) remains in effect.
        var config = "proxy = " + (try quote(route?.proxyURL ?? "")) + "\n"
        if let username = route?.username { config += "proxy-user = " + (try quote(username + ":" + (route?.password ?? ""))) + "\n" }
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard name.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.requestFailed }
            config += "header = " + (try quote(name + ": " + value)) + "\n"
        }
        #if TOKENCLOCK_PROXY_TESTS
        if ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host ?? ""), let path = fixtureAnchorPath {
            config += "cacert = " + (try quote(path)) + "\n"
        }
        #endif
        let seconds = String(min(8, max(0.1, request.timeoutInterval)))
        return Invocation(arguments: ["-q", "--silent", "--globoff", "--noproxy", "", "--proto", "=https",
            "--proto-redir", "=https", "--max-redirs", "0", "--retry", "0", "--max-time", seconds,
            "--connect-timeout", seconds, "--max-filesize", "1048576", "--include", "--compressed",
            "--suppress-connect-headers", "--config", "-", "--url", url.absoluteString], configuration: Data(config.utf8))
    }

    static func allowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil else { return false }
        if url.host == "api.anthropic.com" { return ["/api/oauth/usage", "/api/oauth/profile"].contains(url.path) }
        guard url.host == "claude.ai" else { return false }
        if ["/api/account", "/api/organizations"].contains(url.path) { return true }
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && parts[0] == "api" && parts[1] == "organizations"
            && UUID(uuidString: String(parts[2])) != nil && parts[3] == "usage"
    }

    static func parseProxy(_ raw: String) throws -> Route {
        guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.proxyRequired }
        let number = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 1080)
        guard (1...65535).contains(number) else { throw Failure.proxyRequired }
        let plainHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return Route(kind: scheme.hasPrefix("socks") ? .socks5 : scheme == "https" ? .https : .http,
                     host: plainHost, port: UInt16(number), username: url.user?.removingPercentEncoding,
                     password: url.password?.removingPercentEncoding)
    }

    /// No PAC download/evaluation, DNS lookup, proxy guessing, or health probe.
    /// Explicit Claude settings/process proxies must agree if both are present.
    static func resolve(url: URL, environment: [String: String], settings: Data?, system: [String: Any], mode: Mode = .system) throws -> Route? {
        let keys = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]
        func configured(_ values: [String: String]) throws -> Route? {
            guard let key = keys.first(where: { values[$0] != nil }) else { return nil }
            return try parseProxy(values[key]!)  // An empty/invalid explicit value must not fall back.
        }
        var settingsEnvironment: [String: String] = [:]
        if let settings {
            guard settings.count <= 1_048_576,
                  let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { throw Failure.proxyRequired }
            if let raw = root["env"] {
                guard let values = raw as? [String: Any] else { throw Failure.proxyRequired }
                for key in keys where values[key] != nil {
                    guard let value = values[key] as? String else { throw Failure.proxyRequired }
                    settingsEnvironment[key] = value
                }
            }
        }
        let fromProcess = try configured(environment), fromSettings = try configured(settingsEnvironment)
        if let fromProcess, let fromSettings, fromProcess != fromSettings { throw Failure.proxyRequired }
        if let explicit = fromSettings ?? fromProcess { return explicit }
        // CFNetwork resolves system exclusions locally. Select exactly the first
        // route before dispatch. A later DIRECT alternative is never attempted.
        let choices = CFNetworkCopyProxiesForURL(url as CFURL, system as CFDictionary).takeRetainedValue() as NSArray
        guard let first = choices.firstObject as? [String: Any],
              let type = first[kCFProxyTypeKey as String] as? String else { throw Failure.proxyRequired }
        if type == kCFProxyTypeNone as String {
            guard mode == .system else { throw Failure.proxyRequired }
            return nil
        }
        guard let host = first[kCFProxyHostNameKey as String] as? String,
              let port = first[kCFProxyPortNumberKey as String] as? NSNumber,
              (1...65535).contains(port.intValue), port.doubleValue == Double(port.intValue),
              !host.isEmpty, !host.contains("/"), !host.contains("@"),
              !host.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { throw Failure.proxyRequired }
        let kind: Route.Kind
        // System "Secure Web Proxy (HTTPS)" is an HTTP CONNECT proxy for HTTPS
        // targets. TLS to the proxy itself requires an explicit https:// URL.
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String { kind = .http }
        else if type == kCFProxyTypeSOCKS as String { kind = .socks5 }
        else { throw Failure.proxyRequired }
        return Route(kind: kind, host: host, port: port.uint16Value,
                     username: first[kCFProxyUsernameKey as String] as? String,
                     password: first[kCFProxyPasswordKey as String] as? String)
    }

    static func currentRoute(url: URL, claudeHome: String, environment: [String: String], mode: Mode) throws -> Route? {
        let path = URL(fileURLWithPath: claudeHome).appendingPathComponent("settings.json")
        var data: Data?
        if FileManager.default.fileExists(atPath: path.path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
                  let body = try? Data(contentsOf: path) else { throw Failure.proxyRequired }
            data = body
        }
        guard let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { throw Failure.proxyRequired }
        return try resolve(url: url, environment: environment, settings: data, system: system, mode: mode)
    }

    static func get(_ request: URLRequest, claudeHome: String,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    mode: Mode = ClaudeQuotaNetwork.mode()) -> Result<Response, Failure> {
        guard allowed(request), let url = request.url else { return .failure(.requestFailed) }
        do {
            let route = try currentRoute(url: url, claudeHome: claudeHome, environment: environment, mode: mode)
            return transfer(request, route: route)
        } catch { return .failure(.proxyRequired) }
    }

    /// The production entry is get(), with fixed HTTPS quota destinations.
    /// curl receives a fixed proxy or the deliberately selected OS route, with
    /// no inherited overrides. A failed transfer is never re-resolved/retried.
    static func transfer(_ request: URLRequest, route: Route?) -> Result<Response, Failure> {
        guard let call = try? invocation(request, route: route) else { return .failure(.requestFailed) }
        let process = Process(), input = Pipe(), output = Pipe()
        let finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let bytes = Buffer()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = call.arguments
        process.environment = call.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .failure(.requestFailed) }
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if !bytes.append(chunk) {
                    if process.isRunning { process.terminate() }
                    break
                }
            }
        }
        var wrote = false
        do { try input.fileHandleForWriting.write(contentsOf: call.configuration); wrote = true } catch { }
        try? input.fileHandleForWriting.close()
        let timeout = min(8, max(0.1, request.timeoutInterval)) + 0.5
        let ended = finished.wait(timeout: .now() + timeout) == .success
        if !ended && process.isRunning {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) != .success && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let readAll = drained.wait(timeout: .now() + 1) == .success
        try? output.fileHandleForReading.close()
        guard ended, wrote, readAll, process.terminationStatus == 0, let data = bytes.result() else { return .failure(.requestFailed) }
        return decode(data)
    }

    static func decode(_ data: Data) -> Result<Response, Failure> {
        var rest = data
        for _ in 0..<6 {
            guard let split = rest.range(of: Data("\r\n\r\n".utf8)), split.lowerBound <= 65536,
                  let header = String(data: rest[..<split.lowerBound], encoding: .isoLatin1) else { return .failure(.requestFailed) }
            let lines = header.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2, first[0].hasPrefix("HTTP/"), let status = Int(first[1]) else { return .failure(.requestFailed) }
            rest = Data(rest[split.upperBound...])
            if (100..<200).contains(status) { continue }
            guard (200..<600).contains(status), !(300..<400).contains(status), rest.count <= 1_048_576 else { return .failure(.requestFailed) }
            let challenge = lines.contains { $0.lowercased().hasPrefix("cf-mitigated:") && $0.lowercased().contains("challenge") }
                || (status == 403 && String(decoding: rest.prefix(4096), as: UTF8.self).contains("Just a moment"))
            return .success(Response(status: status, data: rest, challenge: challenge))
        }
        return .failure(.requestFailed)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var exceeded = false
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard data.count + chunk.count <= 1_048_576 + 65536 else { exceeded = true; return false }
                data.append(chunk); return true
            }
        }
        func result() -> Data? { lock.withLock { exceeded ? nil : data } }
    }
}
#endif
