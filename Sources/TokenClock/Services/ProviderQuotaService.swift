import Foundation
#if os(Windows) || os(Linux)
import CSQLite
#else
import SQLite3
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

struct ProviderQuotaGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let buckets: [CodexQuotaBucket]
}

struct ProviderQuotaSnapshot: Equatable, Sendable {
    var status: CodexQuotaStatus
    var groups: [ProviderQuotaGroup]
    var planType: String?
    var refreshedAt: Date?
    var source: String
    var message: String?

    static func idle(source: String) -> Self {
        Self(status: .idle, groups: [], planType: nil, refreshedAt: nil, source: source, message: nil)
    }

    static func loading(previous: Self) -> Self {
        var value = previous; value.status = .loading; value.message = nil; return value
    }

    static func unavailable(_ message: String, source: String) -> Self {
        Self(status: .unavailable, groups: [], planType: nil, refreshedAt: Date(), source: source, message: message)
    }

    var isStale: Bool {
        guard let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) >= 60
    }
}

/// Reads Antigravity's local, authenticated Models & Usage summary on demand.
/// The short-lived loopback token remains in memory and is never logged or persisted.
final class AntigravityQuotaService: @unchecked Sendable {
    private struct Endpoint { let port: Int; let csrfToken: String }
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String

    init(fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: String = NSHomeDirectory()) {
        self.fileManager = fileManager; self.environment = environment; self.homeDirectory = homeDirectory
    }

    func fetch() -> ProviderQuotaSnapshot {
        let source = "Antigravity local service"
        guard let endpoint = endpointFromLatestLog() else {
            return .unavailable("Antigravity is not running or its local quota service was not found.", source: source)
        }
        guard let data = request(endpoint: endpoint), let snapshot = Self.decodeResponse(data) else {
            return .unavailable("Antigravity quota response was not available.", source: source)
        }
        return snapshot
    }

    static func decodeResponse(_ data: Data, now: Date = Date()) -> ProviderQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let rawGroups = response["groups"] as? [[String: Any]] else { return nil }
        var groups: [ProviderQuotaGroup] = []
        for (groupIndex, rawGroup) in rawGroups.enumerated() {
            let groupName = rawGroup["displayName"] as? String ?? "Models"
            let rawBuckets = rawGroup["buckets"] as? [[String: Any]] ?? []
            let buckets = rawBuckets.enumerated().compactMap { bucketIndex, raw -> CodexQuotaBucket? in
                guard let remaining = number(raw["remainingFraction"]) else { return nil }
                let bucketID = raw["bucketId"] as? String ?? "\(groupIndex):\(bucketIndex)"
                let name = raw["displayName"] as? String ?? bucketID
                let window = (raw["window"] as? String ?? bucketID).lowercased()
                let minutes = window.contains("weekly") || window.contains("week") ? 10_080
                    : (window.contains("5h") || window.contains("five") ? 300 : 0)
                return CodexQuotaBucket(
                    id: "antigravity:\(bucketID)", name: name,
                    usedPercent: min(100, max(0, (1 - remaining) * 100)),
                    windowMinutes: minutes, resetsAt: date(raw["resetTime"])
                )
            }
            if !buckets.isEmpty {
                groups.append(ProviderQuotaGroup(id: "antigravity:\(groupIndex):\(groupName)", name: groupName, buckets: buckets))
            }
        }
        guard !groups.isEmpty else { return nil }
        return ProviderQuotaSnapshot(status: .available, groups: groups, planType: nil, refreshedAt: now,
                                     source: "Antigravity local service", message: response["description"] as? String)
    }

    private func endpointFromLatestLog() -> Endpoint? {
        var candidates: [(date: Date, url: URL)] = []
        for root in logRoots() {
            guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == "ls-main.log" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((date, url))
            }
        }
        for candidate in candidates.sorted(by: { $0.date > $1.date }) {
            guard let text = try? String(contentsOf: candidate.url, encoding: .utf8),
                  let token = capture(#"--csrf_token(?:=|\s+)([^\s]+)"#, in: text, last: false), !token.isEmpty else { continue }
            let portText = capture(#"LS started on port\s+([0-9]+)"#, in: text, last: true)
                ?? capture(#"random port at\s+([0-9]+)\s+for HTTPS"#, in: text, last: true)
            if let portText, let port = Int(portText), (1...65_535).contains(port) {
                return Endpoint(port: port, csrfToken: token)
            }
        }
        return nil
    }

    private func logRoots() -> [String] {
        #if os(Windows)
        let appData = environment["APPDATA"] ?? (homeDirectory + "\\AppData\\Roaming")
        return [appData + "\\Antigravity\\logs", appData + "\\Antigravity IDE\\logs"]
        #elseif os(macOS)
        return [homeDirectory + "/Library/Application Support/Antigravity/logs",
                homeDirectory + "/Library/Application Support/Antigravity IDE/logs"]
        #else
        let config = environment["XDG_CONFIG_HOME"] ?? (homeDirectory + "/.config")
        return [config + "/Antigravity/logs", config + "/Antigravity IDE/logs"]
        #endif
    }

    private func request(endpoint: Endpoint) -> Data? {
        let url = "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        let body = Data(#"{"forceRefresh":true}"#.utf8)
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(url: url, method: "POST", headers: [
            "Content-Type": "application/json", "x-codeium-csrf-token": endpoint.csrfToken,
        ], body: body, connectTimeout: 3, sendTimeout: 3, receiveTimeout: 12), response.statusCode == 200 else { return nil }
        return response.body
        #else
        guard let executable = ["/usr/bin/curl", "/usr/local/bin/curl"].first(where: fileManager.isExecutableFile(atPath:)) else { return nil }
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-ksS", "--max-time", "12", "-X", "POST", "-H", "Content-Type: application/json",
            "-H", "x-codeium-csrf-token: \(endpoint.csrfToken)", "--data-binary", "{\"forceRefresh\":true}", url]
        process.standardOutput = output; process.standardError = Pipe()
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return output.fileHandleForReading.readDataToEndOfFile()
        } catch { return nil }
        #endif
    }

    private func capture(_ pattern: String, in text: String, last: Bool) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = last ? matches.last : matches.first, match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// Reads Cursor's authenticated dashboard summary. Unknown response shapes fail closed;
/// TokenClock never estimates plan limits from sticker prices.
final class CursorQuotaService: @unchecked Sendable {
    private struct Credential { let token: String; let userID: String }
    private let fileManager: FileManager
    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func fetch() -> ProviderQuotaSnapshot {
        let source = "Cursor dashboard"
        guard UserDefaults.standard.bool(for: .cursorCloudFetchEnabled, default: true) else {
            return .unavailable("Cursor cloud access is disabled in Settings.", source: source)
        }
        guard let credential = credentialFromStateDatabase() else {
            return .unavailable("Cursor login was not found.", source: source)
        }
        guard let data = request(credential: credential), let snapshot = Self.decodeResponse(data) else {
            return .unavailable("Cursor subscription quota was not available.", source: source)
        }
        return snapshot
    }

    static func decodeResponse(_ data: Data, now: Date = Date()) -> ProviderQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["usageSummary"] as? [String: Any]) ?? (root["response"] as? [String: Any]) ?? root
        let individual = payload["individualUsage"] as? [String: Any] ?? payload
        let plan = individual["plan"] as? [String: Any] ?? individual
        let used = number(plan["used"]), limit = number(plan["limit"])
        let cursorPercent = number(plan["totalPercentUsed"])
            ?? number(individual["totalPercentUsed"])
        let otherPercent = number(plan["apiPercentUsed"]) ?? {
            guard let used, let limit, limit > 0 else { return nil }; return used / limit * 100
        }()
        let reset = date(payload["billingCycleEnd"]), start = date(payload["billingCycleStart"])
        let minutes = start.flatMap { start in reset.map { max(0, Int($0.timeIntervalSince(start) / 60)) } } ?? 43_200
        var buckets: [CodexQuotaBucket] = []
        if let cursorPercent {
            buckets.append(CodexQuotaBucket(
                id: "cursor:first-party", name: "Cursor Models",
                usedPercent: min(100, max(0, cursorPercent)),
                windowMinutes: minutes, resetsAt: reset
            ))
        }
        let membership = (payload["membershipType"] as? String ?? "").lowercased()
        if membership != "start", let otherPercent {
            buckets.append(CodexQuotaBucket(
                id: "cursor:other-models", name: "Other Models",
                usedPercent: min(100, max(0, otherPercent)),
                windowMinutes: minutes, resetsAt: reset
            ))
        }
        guard !buckets.isEmpty else { return nil }
        // Cursor's two monthly pools share the account billing-cycle boundary.
        // Normalize it onto every bucket so an exhausted secondary pool does not
        // lose its reset label when the dashboard omits pool-local reset metadata.
        if let sharedReset = reset ?? buckets.compactMap(\.resetsAt).first {
            buckets = buckets.map {
                CodexQuotaBucket(
                    id: $0.id, name: $0.name, usedPercent: $0.usedPercent,
                    windowMinutes: $0.windowMinutes, resetsAt: sharedReset
                )
            }
        }
        return ProviderQuotaSnapshot(status: .available,
            groups: [ProviderQuotaGroup(id: "cursor:plan", name: "Subscription", buckets: buckets)],
            planType: payload["membershipType"] as? String, refreshedAt: now, source: "Cursor dashboard", message: nil)
    }

    private func credentialFromStateDatabase() -> Credential? {
        let dbPath = AppPaths.appSupport("Cursor", "User", "globalStorage", "state.vscdb")
        guard fileManager.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: pointer)
        guard let userID = Self.userID(from: token) else { return nil }
        return Credential(token: token, userID: userID)
    }

    static func userID(from token: String) -> String? {
        let decoded = token.removingPercentEncoding ?? token
        if decoded.contains("::") { let value = decoded.components(separatedBy: "::")[0]; return value.isEmpty ? nil : value }
        let parts = decoded.components(separatedBy: "."); guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String else { return nil }
        if let range = subject.range(of: #"user_[A-Za-z0-9]+"#, options: .regularExpression) { return String(subject[range]) }
        return subject.split(separator: "|").last.map(String.init)
    }

    private func request(credential: Credential) -> Data? {
        let cookieToken = credential.token.contains("::")
            ? credential.token.replacingOccurrences(of: "::", with: "%3A%3A")
            : "\(credential.userID)%3A%3A\(credential.token)"
        let headers = ["Accept": "application/json", "Cookie": "WorkosCursorSessionToken=\(cookieToken)",
            "Origin": AppConfig.API.cursorOrigin, "Referer": AppConfig.API.cursorDashboard,
            "User-Agent": AppConfig.HTTP.userAgent]
        let url = AppConfig.API.cursorOrigin + "/api/usage-summary"
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(url: url, headers: headers,
            connectTimeout: 8, sendTimeout: 8, receiveTimeout: 15), response.statusCode == 200 else { return nil }
        return response.body
        #else
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let semaphore = DispatchSemaphore(value: 0); let box = HTTPResultBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in box.store(data: data, response: response); semaphore.signal() }.resume()
        guard semaphore.wait(timeout: .now() + 16) == .success,
              let response = box.load(), response.statusCode == 200 else { return nil }
        return response.data
        #endif
    }

    #if !os(Windows)
    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock(); private var result: (data: Data, statusCode: Int)?
        func store(data: Data?, response: URLResponse?) {
            guard let data, let response = response as? HTTPURLResponse else { return }
            lock.withLock { result = (data, response.statusCode) }
        }
        func load() -> (data: Data, statusCode: Int)? { lock.withLock { result } }
    }
    #endif

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func date(_ value: Any?) -> Date? {
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue / 1_000) }
        guard let value = value as? String else { return nil }
        if let milliseconds = Double(value), milliseconds > 10_000_000_000 { return Date(timeIntervalSince1970: milliseconds / 1_000) }
        let plain = ISO8601DateFormatter()
        if let parsed = plain.date(from: value) { return parsed }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

/// Reads the active ZCode Z.ai / BigModel Coding Plan configuration and queries
/// the same quota endpoint used by ZCode's Coding Plan usage screen.
final class ZhipuQuotaService: @unchecked Sendable {
    private struct Credential {
        let apiKey: String
        let baseURL: String
        let providerID: String
    }

    private let fileManager: FileManager
    private let zcodeHome: String

    init(fileManager: FileManager = .default, zcodeHome: String = PathConfig.zcodeHome()) {
        self.fileManager = fileManager
        self.zcodeHome = zcodeHome
    }

    func fetch() -> ProviderQuotaSnapshot {
        let source = "ZCode Coding Plan"
        guard let credential = credentialFromConfig() else {
            return .unavailable("ZCode Coding Plan login was not found.", source: source)
        }
        guard let data = request(credential: credential),
              let snapshot = Self.decodeResponse(data, providerID: credential.providerID) else {
            return .unavailable("GLM Coding Plan quota was not available.", source: source)
        }
        return snapshot
    }

    static func decodeResponse(
        _ data: Data,
        providerID: String = "bigmodel",
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["success"] as? Bool) == true,
              let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [[String: Any]] else { return nil }

        var buckets: [CodexQuotaBucket] = []
        for (index, raw) in rawLimits.enumerated() {
            let type = (raw["type"] as? String ?? "quota").uppercased()
            let unit = integer(raw["unit"])
            let number = integer(raw["number"])
            let suppliedPercent = double(raw["percentage"])
            let limit = double(raw["usage"])
            let used = double(raw["currentValue"])
            let usedPercent = suppliedPercent ?? {
                guard let limit, limit > 0, let used else { return nil }
                return used / limit * 100
            }()
            guard let usedPercent else { continue }

            let windowMinutes: Int
            let name: String
            if type == "TOKENS_LIMIT", unit == 3, number == 5 {
                windowMinutes = 300; name = "5-hour quota"
            } else if type == "TOKENS_LIMIT", unit == 6, number == 1 {
                windowMinutes = 10_080; name = "Weekly quota"
            } else if type == "TIME_LIMIT" {
                windowMinutes = 43_200; name = "Monthly MCP quota"
            } else {
                windowMinutes = 0; name = type.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let reset = milliseconds(raw["nextResetTime"])
            buckets.append(CodexQuotaBucket(
                id: "zhipu:\(type):\(unit):\(number):\(index)",
                name: name,
                usedPercent: min(100, max(0, usedPercent)),
                windowMinutes: windowMinutes,
                resetsAt: reset
            ))
        }
        guard !buckets.isEmpty else { return nil }
        let level = payload["level"] as? String
        let providerName = providerID.contains("zai") ? "Z.ai Coding Plan" : "BigModel Coding Plan"
        return ProviderQuotaSnapshot(
            status: .available,
            groups: [ProviderQuotaGroup(id: "zhipu:plan", name: "Subscription", buckets: buckets)],
            planType: level,
            refreshedAt: now,
            source: providerName,
            message: nil
        )
    }

    private func credentialFromConfig() -> Credential? {
        let path = zcodeHome.lowercased().hasSuffix("config.json")
            ? zcodeHome : zcodeHome + "/v2/config.json"
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["provider"] as? [String: Any] else { return nil }
        let priority = [
            "builtin:bigmodel-coding-plan", "builtin:zai-coding-plan",
            "builtin:bigmodel-start-plan", "builtin:zai-start-plan",
        ]
        let ordered = priority + providers.keys.filter { !priority.contains($0) }.sorted()
        for id in ordered {
            guard id.contains("coding-plan") || id.contains("start-plan"),
                  let provider = providers[id] as? [String: Any],
                  (provider["enabled"] as? Bool) != false,
                  let options = provider["options"] as? [String: Any],
                  let apiKey = options["apiKey"] as? String, !apiKey.isEmpty,
                  let baseURL = options["baseURL"] as? String, !baseURL.isEmpty else { continue }
            return Credential(apiKey: apiKey, baseURL: baseURL, providerID: id)
        }
        return nil
    }

    private func request(credential: Credential) -> Data? {
        let host = credential.baseURL.contains("api.z.ai")
            ? "https://api.z.ai" : "https://open.bigmodel.cn"
        let url = host + "/api/monitor/usage/quota/limit"
        let headers = [
            "Accept": "application/json, text/plain, */*",
            "Authorization": "Bearer \(credential.apiKey)",
        ]
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(
            url: url, headers: headers,
            connectTimeout: 8, sendTimeout: 8, receiveTimeout: 15
        ), response.statusCode == 200 else { return nil }
        return response.body
        #else
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let semaphore = DispatchSemaphore(value: 0); let box = HTTPResultBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response); semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 16) == .success,
              let response = box.load(), response.statusCode == 200 else { return nil }
        return response.data
        #endif
    }

    #if !os(Windows)
    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock(); private var result: (data: Data, statusCode: Int)?
        func store(data: Data?, response: URLResponse?) {
            guard let data, let response = response as? HTTPURLResponse else { return }
            lock.withLock { result = (data, response.statusCode) }
        }
        func load() -> (data: Data, statusCode: Int)? { lock.withLock { result } }
    }
    #endif

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func integer(_ value: Any?) -> Int { Int(double(value) ?? 0) }
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let value = double(value), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }
}
