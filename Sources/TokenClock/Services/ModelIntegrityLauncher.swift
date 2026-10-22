import Foundation

struct ModelIntegrityLaunchConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?
    var environment: [String: String]? = nil
}

enum ModelIntegrityLaunchError: Error, LocalizedError, Sendable {
    case pythonUnavailable
    case workerUnavailable
    case invalidReady
    case timeout
    case stopped
    case startupFailed(String)
    case workerExited(Int32, String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable: return L10n.shared.tr("integrity.pythonRequired")
        case .workerUnavailable: return L10n.shared.tr("integrity.workerMissing")
        case .invalidReady: return L10n.shared.tr("integrity.invalidReady")
        case .timeout: return L10n.shared.tr("integrity.timeout")
        case .stopped: return L10n.shared.tr("integrity.stopped")
        case .startupFailed(let message): return L10n.shared.tr("integrity.failed") + "\n" + message
        case .workerExited(let code, let message):
            return L10n.shared.tr("integrity.failed") + " (\(code))" + (message.isEmpty ? "" : "\n" + message)
        }
    }
}

/// Owns only the worker it launches. Host overrides are never read from a session log.
/// Process setup, Python probing and pipe reads do not run on the app's UI thread.
final class ModelIntegrityLauncher: @unchecked Sendable {
    typealias Completion = @Sendable (Result<URL, ModelIntegrityLaunchError>) -> Void
    static let shared = ModelIntegrityLauncher()
    private let queue = DispatchQueue(label: "TokenClock.ModelIntegrityLauncher", qos: .utility)
    private let lifecycle = NSLock()
    private var ownedProcess: Process?
    private var stopping = false
    private let configurationProvider: @Sendable () throws -> ModelIntegrityLaunchConfiguration
    private let startupTimeout: TimeInterval
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var output = Data()
    private var diagnostics = Data()
    private var readyURL: URL?
    private var activeID: UUID?
    private var pending: [Completion] = []

    init(startupTimeout: TimeInterval = 20,
         configurationProvider: @escaping @Sendable () throws -> ModelIntegrityLaunchConfiguration = {
             try ModelIntegrityLauncher.defaultConfiguration()
         }) {
        self.startupTimeout = max(0.1, min(startupTimeout, 60))
        self.configurationProvider = configurationProvider
    }

    func start(completion: @escaping Completion) {
        queue.async { [self] in
            if let readyURL, process?.isRunning == true {
                completion(.success(readyURL))
                return
            }
            pending.append(completion)
            if process?.isRunning == true { return }
            lifecycle.lock()
            stopping = false
            lifecycle.unlock()
            do {
                let configuration = try configurationProvider()
                lifecycle.lock()
                let shouldStop = stopping
                lifecycle.unlock()
                if shouldStop { finish(.failure(.stopped)); return }
                launch(configuration)
            } catch let error as ModelIntegrityLaunchError {
                finish(.failure(error))
            } catch {
                finish(.failure(.startupFailed(Self.safeDiagnostic(error.localizedDescription))))
            }
        }
    }

    /// Signal the owned child immediately, including during application termination.
    /// This never searches for or terminates an existing TokenClock process.
    func stop() {
        lifecycle.lock()
        stopping = true
        let child = ownedProcess
        lifecycle.unlock()
        if child?.isRunning == true { child?.terminate() }
        queue.async { [self] in finish(.failure(.stopped)) }
    }

    private func launch(_ configuration: ModelIntegrityLaunchConfiguration) {
        let child = Process()
        let stdout = Pipe(), stderr = Pipe()
        let identifier = UUID()
        child.executableURL = configuration.executableURL
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.workingDirectory
        child.environment = configuration.environment
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = FileHandle.nullDevice
        process = child
        outputPipe = stdout
        errorPipe = stderr
        output = Data()
        diagnostics = Data()
        readyURL = nil
        activeID = identifier
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { [weak self] in self?.receive(chunk, id: identifier, isError: false) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { [weak self] in self?.receive(chunk, id: identifier, isError: true) }
        }
        child.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, self.activeID == identifier else { return }
                let diagnostic = String(data: self.diagnostics.suffix(1200), encoding: .utf8) ?? ""
                self.finish(.failure(.workerExited(child.terminationStatus, Self.safeDiagnostic(diagnostic))))
            }
        }
        do {
            try child.run()
            lifecycle.lock()
            ownedProcess = child
            let shouldStop = stopping
            lifecycle.unlock()
            if shouldStop { child.terminate(); finish(.failure(.stopped)); return }
        } catch {
            finish(.failure(.startupFailed(Self.safeDiagnostic(error.localizedDescription))))
            return
        }
        queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
            guard let self, self.activeID == identifier, self.readyURL == nil else { return }
            self.finish(.failure(.timeout))
        }
    }

    private func receive(_ chunk: Data, id: UUID, isError: Bool) {
        guard activeID == id, !chunk.isEmpty else { return }
        if isError {
            diagnostics.append(chunk)
            diagnostics = Data(diagnostics.suffix(4096))
            return
        }
        guard readyURL == nil else { return }  // drain later stdout without logging URL tokens
        output.append(chunk)
        guard output.count <= 8192 else { finish(.failure(.invalidReady)); return }
        guard let end = output.firstIndex(of: 10) else { return }
        do {
            let url = try Self.parseReadyLine(Data(output[..<end]))
            guard process?.isRunning == true else { finish(.failure(.invalidReady)); return }
            readyURL = url
            output.removeAll()
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0(.success(url)) }
        } catch {
            finish(.failure(.invalidReady))
        }
    }

    private func finish(_ result: Result<URL, ModelIntegrityLaunchError>) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        lifecycle.lock()
        ownedProcess = nil
        lifecycle.unlock()
        process = nil
        outputPipe = nil
        errorPipe = nil
        activeID = nil
        readyURL = nil
        output.removeAll()
        diagnostics.removeAll()
        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0(result) }
    }

    static func parseReadyLine(_ data: Data) throws -> URL {
        guard data.count <= 8192,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelIntegrityLaunchError.invalidReady
        }
        let raw: String?
        if value["event"] as? String == "ready" { raw = value["url"] as? String }
        else { raw = (value["ready"] as? [String: Any])?["url"] as? String }
        guard let raw, let parts = URLComponents(string: raw),
              parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil,
              let url = parts.url else { throw ModelIntegrityLaunchError.invalidReady }
        return url
    }

    static func defaultConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ModelIntegrityLaunchConfiguration {
        let fileManager = FileManager.default
        let stateDirectory: URL
        if let override = environment["TOKENCLOCK_MODEL_INTEGRITY_STATE_DIR"] {
            guard override.hasPrefix("/") else {
                throw ModelIntegrityLaunchError.startupFailed(L10n.shared.tr("integrity.absolutePathRequired"))
            }
            stateDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            #if os(Linux)
            let stateHome = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
            stateDirectory = stateHome.appendingPathComponent("tokenclock/model-integrity")
            #else
            stateDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TokenClock/ModelIntegrity")
            #endif
        }
        let bundled = [Bundle.main.resourceURL, Bundle.module.resourceURL].compactMap { $0 }
            .map { $0.appendingPathComponent("model-integrity-worker/worker.py") }
        let worker: URL?
        if let override = environment["TOKENCLOCK_MODEL_INTEGRITY_WORKER"] {
            guard override.hasPrefix("/"), fileManager.fileExists(atPath: override) else {
                throw ModelIntegrityLaunchError.workerUnavailable
            }
            worker = URL(fileURLWithPath: override)
        } else { worker = bundled.first { fileManager.fileExists(atPath: $0.path) } }
        if let sourceWorker = worker {
            let prepared = try ModelIntegrityRuntimeCache.prepare(worker: sourceWorker, state: stateDirectory)
            let worker = prepared.worker
            var childEnvironment = environment
            let runtime = prepared.runtime ?? sourceWorker.deletingLastPathComponent().appendingPathComponent("runtime")
            if fileManager.fileExists(atPath: runtime.appendingPathComponent("runtime-manifest.json").path) {
                childEnvironment["TOKENCLOCK_MODEL_INTEGRITY_RUNTIME"] = runtime.path
            }
            let python = try pythonExecutable(environment: childEnvironment)
            return ModelIntegrityLaunchConfiguration(executableURL: python,
                arguments: ["-B", "-I", worker.path, "serve", "--state-dir", stateDirectory.path],
                workingDirectory: worker.deletingLastPathComponent(), environment: childEnvironment)
        }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        let sourceRoot: URL? = nil
        #endif
        if let override = environment["TOKENCLOCK_MODEL_INTEGRITY_REPO"], !override.hasPrefix("/") {
            throw ModelIntegrityLaunchError.startupFailed(L10n.shared.tr("integrity.absolutePathRequired"))
        }
        let configuredRepo = environment["TOKENCLOCK_MODEL_INTEGRITY_REPO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #if DEBUG
        let repo = configuredRepo ?? sourceRoot
        #else
        guard let repo = configuredRepo ?? sourceRoot else { throw ModelIntegrityLaunchError.workerUnavailable }
        #endif
        guard fileManager.fileExists(atPath: repo.appendingPathComponent("scripts/model_integrity/l1/__main__.py").path) else {
            throw ModelIntegrityLaunchError.workerUnavailable
        }
        let python = try pythonExecutable(environment: environment)
        return ModelIntegrityLaunchConfiguration(executableURL: python,
            arguments: ["-B", "-E", "-s", "-m", "scripts.model_integrity.l1", "serve", "--state-dir", stateDirectory.path],
            workingDirectory: repo)
    }

    static func pythonExecutable(environment: [String: String], resourceRoots: [URL]? = nil) throws -> URL {
        let candidates: [String]
        if let override = environment["TOKENCLOCK_MODEL_INTEGRITY_PYTHON"] {
            candidates = override.hasPrefix("/") ? [override] : []
        } else {
            let roots = resourceRoots ?? [Bundle.main.resourceURL, Bundle.module.resourceURL].compactMap { $0 }
            var embedded = roots.map { $0.appendingPathComponent("model-integrity-worker/runtime/python/bin/python3").path }
            if let runtime = environment["TOKENCLOCK_MODEL_INTEGRITY_RUNTIME"], runtime.hasPrefix("/") {
                embedded.insert(URL(fileURLWithPath: runtime).appendingPathComponent("python/bin/python3").path, at: 0)
            }
            let configuredPaths = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
            candidates = embedded + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
                + configuredPaths.map { String($0) + "/python3" } + ["/usr/bin/python3", "/bin/python3"]
        }
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            let candidate = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: path), pythonIsSupported(candidate) { return candidate }
        }
        throw ModelIntegrityLaunchError.pythonUnavailable
    }

    static func pythonIsSupported(_ executable: URL) -> Bool {
        let probe = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        probe.executableURL = executable
        probe.arguments = ["-B", "-I", "-c", "import sys; print('%d.%d' % sys.version_info[:2])"]
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        probe.terminationHandler = { _ in done.signal() }
        do { try probe.run() } catch { return false }
        guard done.wait(timeout: .now() + 2) == .success else {
            if probe.isRunning { probe.terminate() }
            return false
        }
        guard probe.terminationStatus == 0,
              let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile().prefix(256), encoding: .utf8) else { return false }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
        return parts.count == 2 && (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 10))
    }

    private static func safeDiagnostic(_ text: String) -> String {
        var result = text
        for pattern in [#"sk-(?:or-v\d+-)?[A-Za-z0-9_-]{12,}"#,
                        #"(?i)Bearer\s+[^\s\"']+"#,
                        #"(?i)(?:api[_-]?key|Authorization)\s*[:=]\s*[^\s]+"#,
                        #"http://127\.0\.0\.1:\d+/s/[^\s/]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.suffix(600))
    }
}
