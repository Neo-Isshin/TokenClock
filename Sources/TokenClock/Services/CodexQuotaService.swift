import Foundation

enum CodexQuotaSource: String, Sendable {
    case appServer
    case sessionLog
}

enum CodexQuotaStatus: String, Sendable {
    case idle
    case loading
    case available
    case unavailable
}

struct CodexQuotaBucket: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    var status: CodexQuotaStatus
    var buckets: [CodexQuotaBucket]
    var planType: String?
    var creditBalance: String?
    var hasUnlimitedCredits: Bool
    var resetCreditCount: Int
    var refreshedAt: Date?
    var source: CodexQuotaSource?
    var message: String?

    static let idle = CodexQuotaSnapshot(
        status: .idle,
        buckets: [],
        planType: nil,
        creditBalance: nil,
        hasUnlimitedCredits: false,
        resetCreditCount: 0,
        refreshedAt: nil,
        source: nil,
        message: nil
    )

    static func loading(previous: CodexQuotaSnapshot) -> CodexQuotaSnapshot {
        var value = previous
        value.status = .loading
        value.message = nil
        return value
    }

    static func unavailable(_ message: String) -> CodexQuotaSnapshot {
        var value = Self.idle
        value.status = .unavailable
        value.message = message
        value.refreshedAt = Date()
        return value
    }

    var isStale: Bool {
        guard let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) >= AppConfig.Scan.codexQuotaCacheSeconds
    }
}

/// Reads Codex rate-limit windows without touching auth files.
///
/// The primary path is the official Codex app-server JSON-RPC method
/// `account/rateLimits/read`. A bounded tail read of recent rollout logs is kept as
/// an offline fallback for older CLI versions. The service is deliberately invoked
/// on demand from the detail panel; it never installs a timer or leaves app-server
/// running after the response/timeout.
final class CodexQuotaService: @unchecked Sendable {
    enum HostPlatform: Equatable {
        case macOS
        case windows
        case unix

        static var current: Self {
            #if os(macOS)
            return .macOS
            #elseif os(Windows)
            return .windows
            #else
            return .unix
            #endif
        }
    }

    private final class ResponseBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var responseLine: Data?
        private var didSignal = false

        func append(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard responseLine == nil else { return false }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                responseLine = line
                if !didSignal {
                    didSignal = true
                    return true
                }
            }
            return false
        }

        func response() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return responseLine
        }
    }

    private let fileManager = FileManager.default
    private let codexHome: String

    init(codexHome: String = PathConfig.codexHome()) {
        self.codexHome = codexHome
    }

    func fetch() -> CodexQuotaSnapshot {
        if let executable = codexExecutable(),
           let response = fetchFromAppServer(executable: executable),
           let snapshot = Self.decodeAppServerResponse(response) {
            return snapshot
        }
        if let snapshot = fetchFromRecentSessionLogs() {
            return snapshot
        }
        return .unavailable("Codex rate-limit data is not available. Make sure Codex is installed and signed in.")
    }

    private func codexExecutable() -> URL? {
        let candidates = Self.executableCandidatePaths(
            environment: ProcessInfo.processInfo.environment,
            platform: .current,
            homeDirectory: NSHomeDirectory()
        )

        var seen = Set<String>()
        for rawPath in candidates {
            let path = (rawPath as NSString).expandingTildeInPath
            guard seen.insert(path).inserted,
                  fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Builds host-specific executable candidates without probing the filesystem.
    /// Kept deterministic so Windows/Linux packaging can regression-test path rules
    /// while sharing the quota parser and service implementation.
    static func executableCandidatePaths(
        environment: [String: String],
        platform: HostPlatform,
        homeDirectory: String
    ) -> [String] {
        var candidates: [String] = []
        if let override = environment["CODEX_BINARY"], !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }

        switch platform {
        case .macOS:
            // Prefer the native binary bundled with ChatGPT. GUI apps commonly do
            // not inherit Homebrew's PATH, while npm wrappers depend on finding node.
            candidates += [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        case .windows:
            if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
                candidates += [
                    localAppData + "\\Programs\\OpenAI\\Codex\\bin\\codex.exe",
                    localAppData + "\\OpenAI\\Codex\\bin\\codex.exe",
                ]
            }
            if let appData = environment["APPDATA"], !appData.isEmpty {
                let npmRoot = appData + "\\npm\\node_modules\\@openai\\codex\\node_modules"
                candidates += [
                    npmRoot + "\\@openai\\codex-win32-x64\\vendor\\x86_64-pc-windows-msvc\\codex\\codex.exe",
                    npmRoot + "\\@openai\\codex-win32-arm64\\vendor\\aarch64-pc-windows-msvc\\codex\\codex.exe",
                ]
            }
        case .unix:
            candidates += [
                homeDirectory + "/.local/bin/codex",
                "/usr/local/bin/codex",
                "/usr/bin/codex",
            ]
        }

        let path = platform == .windows
            ? (environment["Path"] ?? environment["PATH"])
            : environment["PATH"]
        if let path, !path.isEmpty {
            let separator: Character = platform == .windows ? ";" : ":"
            let executable = platform == .windows ? "codex.exe" : "codex"
            let slash = platform == .windows ? "\\" : "/"
            candidates += path.split(separator: separator).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines) + slash + executable
            }
        }
        return candidates
    }

    private func fetchFromAppServer(executable: URL) -> Data? {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let responseBuffer = ResponseBuffer()
        let responseReady = DispatchSemaphore(value: 0)

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, responseBuffer.append(data) {
                responseReady.signal()
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let requests: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "tokenclock",
                        "title": "TokenClock",
                        "version": "1.0",
                    ],
                ],
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]],
        ]
        var requestData = Data()
        for request in requests {
            guard let line = try? JSONSerialization.data(withJSONObject: request) else { continue }
            requestData.append(line)
            requestData.append(0x0A)
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: requestData)
        } catch {
            stop(process: process, input: input, output: output, errors: errors)
            return nil
        }

        _ = responseReady.wait(timeout: .now() + AppConfig.Scan.codexQuotaTimeoutSeconds)
        let response = responseBuffer.response()
        stop(process: process, input: input, output: output, errors: errors)
        return response
    }

    private func stop(process: Process, input: Pipe, output: Pipe, errors: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Closing all pipe ends ensures a wedged CLI cannot retain descriptors in
        // the widget after timeout. Do not wait synchronously for termination.
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    static func decodeAppServerResponse(_ data: Data, now: Date = Date()) -> CodexQuotaSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let result = object["result"] as? [String: Any] else { return nil }

        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let main = result["rateLimits"] as? [String: Any]
        var groups: [(String, [String: Any])] = []
        if let byID, !byID.isEmpty {
            groups = byID.compactMap { key, value in
                guard let dictionary = value as? [String: Any] else { return nil }
                return (key, dictionary)
            }
        } else if let main {
            groups = [((main["limitId"] as? String) ?? "codex", main)]
        }

        var buckets: [CodexQuotaBucket] = []
        for (groupID, group) in groups where !isSparkQuotaGroup(groupID, group: group) {
            let baseName = (group["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (groupID == "codex" ? "Codex" : groupID)
            for key in ["primary", "secondary"] {
                guard let window = group[key] as? [String: Any],
                      let used = number(window["usedPercent"]),
                      let minutes = integer(window["windowDurationMins"]) else { continue }
                let reset = number(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                buckets.append(CodexQuotaBucket(
                    id: "\(groupID):\(key)",
                    name: baseName,
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: reset
                ))
            }
        }
        guard !buckets.isEmpty else { return nil }
        buckets.sort {
            if $0.name == "Codex" && $1.name != "Codex" { return true }
            if $0.name != "Codex" && $1.name == "Codex" { return false }
            if $0.name == $1.name { return $0.windowMinutes > $1.windowMinutes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let credits = main?["credits"] as? [String: Any]
        let resetCredits = result["rateLimitResetCredits"] as? [String: Any]
        return CodexQuotaSnapshot(
            status: .available,
            buckets: buckets,
            planType: main?["planType"] as? String,
            creditBalance: credits?["balance"] as? String,
            hasUnlimitedCredits: credits?["unlimited"] as? Bool ?? false,
            resetCreditCount: integer(resetCredits?["availableCount"]) ?? 0,
            refreshedAt: now,
            source: .appServer,
            message: nil
        )
    }

    private func fetchFromRecentSessionLogs() -> CodexQuotaSnapshot? {
        let root = URL(fileURLWithPath: codexHome + "/sessions", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var candidates: [(URL, Date, Int)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        candidates.sort { $0.1 > $1.1 }

        for (url, _, size) in candidates.prefix(AppConfig.Scan.codexQuotaFallbackFileLimit) {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            defer { try? handle.close() }
            let tailSize = min(size, AppConfig.Scan.codexQuotaFallbackTailBytes)
            try? handle.seek(toOffset: UInt64(max(0, size - tailSize)))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for line in lines.reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                guard let snapshot = Self.decodeSessionLogLine(Data(line)) else { continue }
                return snapshot
            }
        }
        return nil
    }

    static func decodeSessionLogLine(_ data: Data) -> CodexQuotaSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var buckets: [CodexQuotaBucket] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = integer(window["window_minutes"]) else { continue }
            let reset = number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            buckets.append(CodexQuotaBucket(
                id: "codex:\(key)",
                name: "Codex",
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: reset
            ))
        }
        guard !buckets.isEmpty else { return nil }
        let timestamp = (object["timestamp"] as? String).flatMap(DateHelper.parseISO8601) ?? Date()
        let credits = limits["credits"] as? [String: Any]
        return CodexQuotaSnapshot(
            status: .available,
            buckets: buckets.sorted { $0.windowMinutes > $1.windowMinutes },
            planType: limits["plan_type"] as? String,
            creditBalance: credits?["balance"] as? String,
            hasUnlimitedCredits: credits?["unlimited"] as? Bool ?? false,
            resetCreditCount: 0,
            refreshedAt: timestamp,
            source: .sessionLog,
            message: nil
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Spark is a separate short-window allowance rather than the user's main Codex
    /// subscription quota. Keeping it in the compact panel made the Codex section noisy
    /// and could be mistaken for another weekly allowance.
    private static func isSparkQuotaGroup(_ id: String, group: [String: Any]) -> Bool {
        let name = group["limitName"] as? String ?? ""
        return id.localizedCaseInsensitiveContains("spark")
            || name.localizedCaseInsensitiveContains("spark")
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }
}
