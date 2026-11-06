#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// This isolated first-party profile is created only by an explicit Connect
/// action. Cookies stay in WebKit storage, never copied to preferences, logs,
/// or application-managed plaintext cookie files.
@MainActor
final class ClaudeConnectionController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = ClaudeConnectionController()
    static let enabledKey = "TC_claudeWebConnectionEnabled"
    static let organizationKey = "TC_claudeWebOrganizationID"
    static let accountKey = "TC_claudeWebAccountID"
    private static let profileID = UUID(uuidString: "60f9fdb2-6b68-41e6-a386-3a5b179e518c")!
    @Published var busy = false
    @Published var message = ""
    @Published var host = "claude.ai"
    @Published var organizations: [ClaudeWebOrganization] = []
    @Published var selectedOrganization = ""
    private var window: NSWindow?
    private var webView: WKWebView?
    private var completion: ((ClaudeQuotaSnapshot) -> Void)?
    private var connectionTask: Task<Void, Never>?

    static var isSelected: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var selectedIdentity: String? { isSelected ? UserDefaults.standard.string(forKey: accountKey) : nil }
    private lazy var store: WKWebsiteDataStore = {
        if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: Self.profileID) }
        // Normal also supports macOS 13, which has no public named profiles.
        // Keep that login in memory rather than share another WebView's jar.
        return .nonPersistent()
    }()

    func currentSession() async -> ClaudeAppSession? {
        guard Self.isSelected, window == nil,
              let expected = UserDefaults.standard.string(forKey: Self.accountKey) else { return nil }
        var value = await session(organization: UserDefaults.standard.string(forKey: Self.organizationKey))
        value?.expectedIdentity = expected
        return value
    }

    private func session(organization: String?) async -> ClaudeAppSession? {
        let cookies = await store.httpCookieStore.allCookies()
        let valid = cookies.filter {
            ["claude.ai", ".claude.ai"].contains($0.domain) && $0.isSecure
                && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        let keys = Set(valid.filter { $0.name == "sessionKey" }.map(\.value))
        guard keys.count == 1, let key = keys.first, ClaudeAppSession.validKey(key) else { return nil }
        let cookieOrgs = Set(valid.filter { $0.name == "lastActiveOrg" }.map(\.value))
        guard cookieOrgs.count <= 1 else { return nil }
        return ClaudeAppSession(key: key, organizationID: organization?.isEmpty == false ? organization : cookieOrgs.first, connected: true)
    }

    func show(onConnected: @escaping (ClaudeQuotaSnapshot) -> Void) {
        completion = onConnected
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        message = ""; selectedOrganization = ""; organizations = []
        let config = WKWebViewConfiguration(); config.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        self.webView = web
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.shared.tr("quota.claudeConnect")
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: (NSApp.keyWindow?.level.rawValue ?? NSWindow.Level.floating.rawValue) + 1)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClaudeConnectionView(controller: self, webView: web))
        window.center(); self.window = window
        web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func verify() {
        guard !busy else { return }
        busy = true; message = ""
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            guard var credential = await self.session(organization: self.selectedOrganization) else {
                self.message = L10n.shared.tr("quota.claudeConnectRequired"); return
            }
            if !self.selectedOrganization.isEmpty { credential.organizationID = self.selectedOrganization }
            let savedCredential = credential
            let result = await Task.detached(priority: .utility) { ClaudeAppQuotaService().fetch(savedCredential) }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let snapshot):
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                // Only persist the verified org, never the session secret.
                let suffix = snapshot.account?.id.split(separator: ":").last.map(String.init)
                UserDefaults.standard.set(suffix, forKey: Self.organizationKey)
                UserDefaults.standard.set(snapshot.account?.id, forKey: Self.accountKey)
                self.completion?(snapshot)
                self.close()
            case .failure(let error):
                if case .chooseOrganization(let choices) = error { self.organizations = choices }
                self.message = L10n.shared.tr(error.messageKey)
            }
        }
    }

    func close() {
        let closing = window
        window = nil
        connectionTask?.cancel(); connectionTask = nil
        closing?.close(); closing?.contentView = nil
        webView?.stopLoading(); webView = nil; completion = nil
    }
    func windowWillClose(_ notification: Notification) {
        connectionTask?.cancel(); connectionTask = nil
        webView?.stopLoading(); webView = nil; window = nil; completion = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? "claude.ai"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https" || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel); return
        }
        if let destination = url.host { host = destination }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct ClaudeConnectionView: View {
    @ObservedObject var controller: ClaudeConnectionController
    let webView: WKWebView
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "lock.shield")
                Text(controller.host).font(.system(size: 12, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 12)
            Text(L10n.shared.tr("quota.claudeConnectPrivacy"))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16)
            ClaudeConnectionWebView(web: webView)
            if !controller.organizations.isEmpty {
                Picker(L10n.shared.tr("quota.claudeChooseOrganization"), selection: $controller.selectedOrganization) {
                    Text("—").tag("")
                    ForEach(controller.organizations) { Text($0.name).tag($0.id) }
                }.padding(.horizontal, 16)
            }
            if !controller.message.isEmpty {
                Text(controller.message).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            HStack {
                Button(L10n.shared.tr("quota.claudeConnectCancel")) { controller.close() }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
                Button(L10n.shared.tr("quota.claudeVerifyConnection")) { controller.verify() }
                    .buttonStyle(.borderedProminent).disabled(controller.busy)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }.frame(minWidth: 640, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ClaudeConnectionWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
