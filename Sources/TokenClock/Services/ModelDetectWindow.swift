#if os(macOS)
import AppKit
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Some WebKit builds return nil for a new frame's documented `request` property
/// despite its nonnull annotation. Read the Objective-C value before bridging it.
@MainActor
enum ModelDetectWebRequest {
    static func request(from owner: NSObject?) -> NSURLRequest? {
        guard let owner, owner.responds(to: #selector(getter: WKFrameInfo.request)) else { return nil }
        return owner.value(forKey: #keyPath(WKFrameInfo.request)) as? NSURLRequest
    }

    static func sourceURL(for action: WKNavigationAction) -> URL? {
        let frame = action.value(forKey: #keyPath(WKNavigationAction.sourceFrame)) as? WKFrameInfo
        return request(from: frame)?.url
    }
}

/// The ready URL is an in-memory capability, not a general localhost allowlist.
struct ModelDetectNavigationPolicy: Sendable {
    enum Destination: Equatable { case workbench, report, download, external, denied }
    let baseURL: URL
    let prefix: String
    private let port: Int
    private let token: String

    init(baseURL: URL) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.range(of: #"^/s/[A-Za-z0-9_-]{16,256}/$"#, options: .regularExpression) != nil else {
            throw ModelIntegrityLaunchError.invalidReady
        }
        self.baseURL = baseURL
        self.port = port
        self.prefix = parts.percentEncodedPath
        self.token = String(prefix.dropFirst(3).dropLast())
    }

    func relativeRoute(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == port,
              parts.user == nil, parts.password == nil,
              !parts.percentEncodedPath.contains("%"), !parts.path.contains("\\"),
              parts.path.hasPrefix(prefix) else { return nil }
        let route = String(parts.path.dropFirst(prefix.count))
        guard !route.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return route
    }

    func isTrustedPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        let decision = destination(for: url, userInitiated: false)
        return decision == .workbench || decision == .report
    }

    func isTrustedBlob(_ url: URL) -> Bool {
        guard url.scheme == "blob", let inner = URL(string: String(url.absoluteString.dropFirst(5))),
              let parts = URLComponents(url: inner, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "http" && parts.host == "127.0.0.1" && parts.port == port
            && parts.user == nil && parts.password == nil
    }

    func destination(for url: URL, userInitiated: Bool, requestedDownload: Bool = false,
                     fromTrustedPage: Bool = false) -> Destination {
        if let route = relativeRoute(url) {
            if route.isEmpty || route == "index.html" { return requestedDownload ? .denied : .workbench }
            let report = #"^reports/job-[a-f0-9]{32}/(report\.html|report\.json|observation\.json|evidence\.zip)$"#
            if route.range(of: report, options: .regularExpression) != nil {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if route.hasSuffix("/report.html") && !requestedDownload && !query.contains(where: { $0.name == "download" && $0.value == "1" }) { return .report }
                return .download
            }
            if route.range(of: #"^partial-evidence/job-[a-f0-9]{32}$"#, options: .regularExpression) != nil { return .download }
            if route.range(of: #"^support/job-[a-f0-9]{32}$"#, options: .regularExpression) != nil { return .download }
            return .denied // Never render a candidate HTML/SVG or arbitrary API reply here.
        }
        if requestedDownload && fromTrustedPage && isTrustedBlob(url) { return .download }
        guard userInitiated, fromTrustedPage, ["http", "https"].contains(url.scheme ?? ""),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil,
              parts.user == nil, parts.password == nil else { return .denied }
        var value = url.absoluteString
        for _ in 0..<3 { value = value.removingPercentEncoding ?? value }
        guard !value.contains(token) else { return .denied }
        return .external
    }

    func homeURL() -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "native", value: "1")]
        return parts.url!
    }

    static func safeFilename(_ suggested: String) -> String {
        let cleaned = suggested.replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? ""
        let value = cleaned.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." || value.hasPrefix(".")
            ? "ModelDetect-download" : String(value.prefix(180))
    }
}

@MainActor
final class ModelDetectWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    enum Phase: Equatable { case idle, starting, loading, ready, failed(String) }
    typealias Starter = (@escaping ModelIntegrityLauncher.Completion) -> Void
    private let starter: Starter
    private let openExternal: (URL) -> Bool
    private(set) var phase: Phase = .idle
    private(set) var webView: WKWebView!
    private(set) var policy: ModelDetectNavigationPolicy?
    private var pendingSourcePath: String?
    private var generation = UUID()
    private var loadingTimeout: Task<Void, Never>?
    private var statusView: NSStackView!
    private var statusTitle: NSTextField!
    private var statusMessage: NSTextField!
    private var spinner: NSProgressIndicator!
    private var retryButton: NSButton!
    private var homeButton: NSButton!
    private var reloadButton: NSButton!
    private var lastExternal: (url: URL, time: TimeInterval)?
    private struct DownloadContext { var sourceURL: URL; var intendedURL: URL?; var temporaryURL: URL? }
    private var downloads: [ObjectIdentifier: DownloadContext] = [:]
    private var downloadObjects: [ObjectIdentifier: WKDownload] = [:]
    private var downloadDirectory: URL?
    private var sourcePicker: NSOpenPanel?

    init(starter: @escaping Starter = { ModelIntegrityLauncher.shared.start(completion: $0) },
         openExternal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.starter = starter
        self.openExternal = openExternal
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(starter:openExternal:)") }

    override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Model Detect"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        let container = NSView()
        window.contentView = container
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        homeButton = NSButton(title: "Model Detect", target: self, action: #selector(showHome))
        homeButton.bezelStyle = .rounded
        reloadButton = NSButton(title: "", target: self, action: #selector(retry))
        reloadButton.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: L10n.shared.tr("modelDetect.localWorkspace"))
        hint.textColor = .secondaryLabelColor
        toolbar.addArrangedSubview(homeButton)
        toolbar.addArrangedSubview(reloadButton)
        toolbar.addArrangedSubview(hint)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = "TokenClockModelDetect/1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        statusView = NSStackView()
        statusView.orientation = .vertical
        statusView.alignment = .centerX
        statusView.spacing = 16
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        statusTitle = NSTextField(labelWithString: "")
        statusTitle.font = .boldSystemFont(ofSize: 20)
        statusMessage = NSTextField(wrappingLabelWithString: "")
        statusMessage.alignment = .center
        statusMessage.textColor = .secondaryLabelColor
        statusMessage.preferredMaxLayoutWidth = 560
        retryButton = NSButton(title: "", target: self, action: #selector(retry))
        retryButton.bezelStyle = .rounded
        [spinner!, statusTitle!, statusMessage!, retryButton!].forEach { statusView.addArrangedSubview($0) }
        [toolbar, webView!, statusView!].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; container.addSubview($0) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor), toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor), webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusView.centerXAnchor.constraint(equalTo: container.centerXAnchor), statusView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        self.window = window
        refreshLocalization()
        updatePhase(.idle)
    }

    /// Source selection is an in-memory event, never a URL query or automatic job start.
    func show(sourcePath: String? = nil, activate: Bool = true) {
        // init(window: nil) is considered loaded by some AppKit versions; build explicitly.
        if webView == nil { loadWindow() }
        if let sourcePath, !sourcePath.isEmpty { pendingSourcePath = sourcePath }
        refreshLocalization()
        if activate { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        switch phase {
        case .ready:
            if pendingSourcePath != nil {
                if policy?.relativeRoute(webView.url ?? URL(string: "about:blank")!) == "" { sendPrefill() }
                else { showHome() }
            }
        case .starting, .loading: break
        case .idle, .failed: beginStartup()
        }
    }

    /// Row actions may prefill an exact log source, but never infer one from a model or ID.
    /// Selecting a file only opens the local workbench; analysis still requires its preview/start.
    func showSession(sourcePath: String?, activate: Bool = true) {
        if let path = ModelDetectSessionSource.usablePath(sourcePath) {
            show(sourcePath: path, activate: activate)
            return
        }
        show(activate: activate)
        guard sourcePicker == nil, let window else { return }
        let picker = NSOpenPanel()
        sourcePicker = picker
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.resolvesAliases = false
        picker.allowedContentTypes = ["json", "jsonl", "txt"].compactMap { UTType(filenameExtension: $0) }
        picker.message = L10n.shared.tr("modelDetect.selectSessionLog")
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.sourcePicker = nil
            guard response == .OK, let url = picker.url else { return }
            guard let path = ModelDetectSessionSource.usablePath(url.path) else {
                self.showNotice(L10n.shared.tr("modelDetect.fileLimit"))
                return
            }
            self.show(sourcePath: path)
        }
    }

    func refreshLocalization() {
        window?.title = "Model Detect"
        retryButton?.title = L10n.shared.tr("modelDetect.retry")
        reloadButton?.title = L10n.shared.tr("modelDetect.refresh")
    }

    private func updatePhase(_ value: Phase) {
        phase = value
        guard isWindowLoaded else { return }
        statusView.isHidden = value == .ready
        webView.isHidden = value != .ready
        switch value {
        case .idle, .starting:
            statusTitle.stringValue = L10n.shared.tr("modelDetect.starting")
            statusMessage.stringValue = L10n.shared.tr("modelDetect.backgroundWork")
        case .loading:
            statusTitle.stringValue = L10n.shared.tr("modelDetect.loading")
            statusMessage.stringValue = L10n.shared.tr("modelDetect.backgroundWork")
        case .failed(let message):
            statusTitle.stringValue = L10n.shared.tr("modelDetect.failed")
            statusMessage.stringValue = safeMessage(message)
        case .ready: break
        }
        if case .failed = value { spinner.stopAnimation(nil); retryButton.isHidden = false }
        else if value == .ready { spinner.stopAnimation(nil); retryButton.isHidden = true }
        else { spinner.startAnimation(nil); retryButton.isHidden = true }
    }

    private func beginStartup() {
        generation = UUID()
        let requestedGeneration = generation
        updatePhase(.starting)
        starter { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == requestedGeneration else { return }
                switch result {
                case .success(let url):
                    do { self.policy = try ModelDetectNavigationPolicy(baseURL: url); self.showHome() }
                    catch { self.updatePhase(.failed(L10n.shared.tr("integrity.invalidReady"))) }
                case .failure(let error): self.updatePhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    @objc func retry() {
        webView?.stopLoading()
        loadingTimeout?.cancel()
        beginStartup() // shared launcher reuses its running instance; no task cancellation
    }

    @objc private func showHome() {
        guard let policy else { beginStartup(); return }
        updatePhase(.loading)
        webView.load(URLRequest(url: policy.homeURL(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        loadingTimeout?.cancel()
        loadingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .loading else { return }
            self.webView.stopLoading()
            self.updatePhase(.failed(L10n.shared.tr("modelDetect.loadTimeout")))
        }
    }

    private func sendPrefill() {
        guard let path = pendingSourcePath, policy?.isTrustedPage(webView.url) == true,
              policy?.relativeRoute(webView.url!) == "" || policy?.relativeRoute(webView.url!) == "index.html" else { return }
        let payload = ["source_path": path, "workflow_mode": "l1"]
        webView.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('tokenclock:model-detect-prefill', {detail: prefill}));",
                                   arguments: ["prefill": payload], in: nil, in: .page) { [weak self] result in
            if case .success = result, self?.pendingSourcePath == path { self?.pendingSourcePath = nil }
        }
    }

    private func safeMessage(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"https?://127\.0\.0\.1:\d+/s/[A-Za-z0-9_-]+/?"#,
                                              with: L10n.shared.tr("modelDetect.localWorkspace"), options: .regularExpression)
        if let prefix = policy?.prefix { value = value.replacingOccurrences(of: prefix, with: "[workspace]/") }
        return String(value.prefix(1000))
    }

    private func external(_ url: URL) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastExternal, lastExternal.url == url, now - lastExternal.time < 0.5 { return }
        lastExternal = (url, now)
        if !openExternal(url) { showNotice(L10n.shared.tr("integrity.browserFailed")) }
    }

    private func showNotice(_ message: String) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = "Model Detect"
        alert.informativeText = safeMessage(message)
        alert.beginSheetModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        // Preserve server jobs and the reusable window. AppDelegate owns shutdown.
        if phase != .ready { webView?.stopLoading(); loadingTimeout?.cancel(); generation = UUID(); updatePhase(.idle) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard policy?.isTrustedPage(webView.url) == true else { return }
        loadingTimeout?.cancel(); updatePhase(.ready); sendPrefill()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loadingTimeout?.cancel(); updatePhase(.failed(error.localizedDescription))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { updatePhase(.failed(L10n.shared.tr("modelDetect.webProcessStopped"))) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = ModelDetectWebRequest.request(from: action)?.url, let policy else { decisionHandler(.cancel); return }
        let decision = policy.destination(for: url, userInitiated: action.navigationType == .linkActivated,
                                          requestedDownload: action.shouldPerformDownload,
                                          fromTrustedPage: policy.isTrustedPage(ModelDetectWebRequest.sourceURL(for: action)))
        switch decision {
        case .workbench, .report: decisionHandler(.allow)
        case .download: decisionHandler(.download)
        case .external: decisionHandler(.cancel); external(url)
        case .denied: decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard let url = response.response.url, let policy else { decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            decisionHandler(.cancel)
            if response.isForMainFrame { updatePhase(.failed(L10n.shared.tr("modelDetect.responseFailed") + " (\(http.statusCode))")) }
            return
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        let decision = policy.destination(for: url, userInitiated: false, requestedDownload: attachment)
        switch decision {
        case .workbench, .report:
            guard response.response.mimeType?.lowercased() == "text/html", response.canShowMIMEType else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        case .download: decisionHandler(.download)
        default: decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let request = ModelDetectWebRequest.request(from: action), let url = request.url, let policy,
              policy.isTrustedPage(ModelDetectWebRequest.sourceURL(for: action)) else { return nil }
        switch policy.destination(for: url, userInitiated: true, requestedDownload: action.shouldPerformDownload, fromTrustedPage: true) {
        case .workbench, .report: webView.load(request as URLRequest)
        case .external: external(url)
        case .download: webView.startDownload(using: request as URLRequest) { [weak self] download in self?.register(download, sourceURL: url) }
        case .denied: break
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard frame.isMainFrame, policy?.isTrustedPage(ModelDetectWebRequest.request(from: frame)?.url) == true, let window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowedContentTypes = ["json", "jsonl", "txt", "py", "html", "svg"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.shared.tr("modelDetect.chooseFile")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { completionHandler(nil); return }
            let urls = panel.urls
            let acceptable = urls.allSatisfy { url in
                guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
                return values.isRegularFile == true && (values.fileSize ?? Int.max) <= 64 * 1024 * 1024
            }
            if acceptable { completionHandler(urls) }
            else { completionHandler(nil); self?.showNotice(L10n.shared.tr("modelDetect.fileLimit")) }
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let url = ModelDetectWebRequest.request(from: navigationAction)?.url else { download.cancel { _ in }; return }
        register(download, sourceURL: url)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let url = navigationResponse.response.url else { download.cancel { _ in }; return }
        register(download, sourceURL: url)
    }
    private func register(_ download: WKDownload, sourceURL: URL) {
        let id = ObjectIdentifier(download)
        downloads[id] = DownloadContext(sourceURL: sourceURL)
        downloadObjects[id] = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard let context = downloads[id], let policy, let window,
              policy.destination(for: context.sourceURL, userInitiated: false, requestedDownload: true, fromTrustedPage: true) == .download else { completionHandler(nil); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ModelDetectNavigationPolicy.safeFilename(suggestedFilename)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { completionHandler(nil); return }
            do {
                if self.downloadDirectory == nil {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenClock-ModelDetect-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    self.downloadDirectory = folder
                }
                let temporary = self.downloadDirectory!.appendingPathComponent(UUID().uuidString + ".download")
                self.downloads[id]?.intendedURL = destination
                self.downloads[id]?.temporaryURL = temporary
                completionHandler(temporary)
            } catch { completionHandler(nil); self.showNotice(L10n.shared.tr("modelDetect.downloadFailed")) }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        guard let url = request.url, policy?.destination(for: url, userInitiated: false, requestedDownload: true) == .download else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        defer { cleanupDownload(id) }
        guard let record = downloads[id], let temporary = record.temporaryURL, let intended = record.intendedURL else { return }
        let sibling = intended.deletingLastPathComponent().appendingPathComponent(".ModelDetect-" + UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: sibling) }
        do {
            try FileManager.default.copyItem(at: temporary, to: sibling)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sibling.path)
            if FileManager.default.fileExists(atPath: intended.path) { _ = try FileManager.default.replaceItemAt(intended, withItemAt: sibling) }
            else { try FileManager.default.moveItem(at: sibling, to: intended) }
        } catch { showNotice(L10n.shared.tr("modelDetect.downloadFailed")) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        cleanupDownload(ObjectIdentifier(download))
        if (error as NSError).code != NSURLErrorCancelled { showNotice(L10n.shared.tr("modelDetect.downloadFailed")) }
    }
    private func cleanupDownload(_ id: ObjectIdentifier) {
        if let temporary = downloads[id]?.temporaryURL { try? FileManager.default.removeItem(at: temporary) }
        downloads.removeValue(forKey: id); downloadObjects.removeValue(forKey: id)
        if downloads.isEmpty, let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory); self.downloadDirectory = nil }
    }
}
#endif
