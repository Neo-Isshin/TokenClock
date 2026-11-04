#if os(macOS)
import AppKit
import WebKit
import SwiftUI

enum NetworkLeakEndpoint {
    static let host = "www.ailyre.com"
    static let path = "/tokenclock/network-check/"

    static func url(language: String, embedded: Bool) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "lang", value: language)]
        if embedded {
            parts.queryItems?.append(URLQueryItem(name: "embedded", value: "1"))
            // Only the explicit launcher click creates a view with this fragment.
            parts.fragment = "run"
        }
        return parts.url!
    }

    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == host && (url.port == nil || url.port == 443)
            && (url.path == path || url.path == String(path.dropLast())) && url.user == nil && url.password == nil
    }

    @MainActor static var title: String {
        L10n.shared.language.rawValue.hasPrefix("zh") ? "网络泄漏检测" : "Network Check"
    }
}

/// Created lazily by the Glass launcher. No WebKit process or probe at app startup.
@MainActor
final class NetworkLeakWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var browser: WKWebView?
    private let presentation = NetworkToolboxPresentation()
    var probeView: WKWebView? { browser }
    var presentedCards:[NetworkToolboxPresentation.Card] { presentation.cards }
    var presentedSummary:String { presentation.summary }
    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticFetcher: NetworkDiagnosticFetcher?
    private var diagnosticRunID: String?
    var hasActiveProbe: Bool { browser != nil }

    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 790),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            panel.title = toolboxText("网络工具箱", "Network Toolbox")
            panel.minSize = NSSize(width: 440, height: 480)
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.delegate = self
            panel.level = .floating
            panel.center()
            window = panel
        }
        if browser == nil { loadProbe() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func loadProbe() {
        presentation.running = true
        presentation.status = toolboxText("正在连接检测服务…", "Connecting…")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakNetworkDiagnosticHandler(owner: self), name: "networkDiagnostics")
        configuration.userContentController.add(WeakNetworkDiagnosticHandler(owner: self), name: "networkPresentation")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = NSColor.windowBackgroundColor
        let content = NSHostingView(rootView: NetworkToolboxView(model: presentation,
            onRun: { [weak self] in self?.restartProbe() },
            onStop: { [weak self] in self?.stopProbe() },
            onBrowser: { NSWorkspace.shared.open(NetworkLeakEndpoint.url(language: L10n.shared.language.rawValue, embedded: false)) },
            onOptions: { [weak self] in self?.updateOptions() }))
        let size = window?.contentLayoutRect.size ?? NSSize(width:780,height:790)
        let container = NSView(frame:NSRect(origin:.zero,size:size))
        content.frame=container.bounds
        content.autoresizingMask=[.width,.height]
        view.frame=NSRect(x:0,y:0,width:1,height:1)
        view.alphaValue=0.01
        container.addSubview(view)
        container.addSubview(content)
        window?.contentView=container
        browser=view
        view.load(URLRequest(url: NetworkLeakEndpoint.url(language: L10n.shared.language.rawValue, embedded: true),
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
    }

    func windowWillClose(_ notification: Notification) {
        stopDiagnostics()
        // Navigation teardown cancels fetches and destroys RTCPeerConnections,
        // including when the page is unresponsive and cannot execute stop().
        browser?.evaluateJavaScript("window.TokenClockLeak?.stop()", completionHandler: nil)
        browser?.stopLoading()
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        browser?.configuration.userContentController.removeScriptMessageHandler(forName: "networkDiagnostics")
        browser?.configuration.userContentController.removeScriptMessageHandler(forName: "networkPresentation")
        browser?.loadHTMLString("", baseURL: nil)
        window?.contentView = nil
        browser = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "tokenclock-network-browser" {
            decisionHandler(.cancel)
            // The external page remains idle until its own Start button is clicked.
            NSWorkspace.shared.open(NetworkLeakEndpoint.url(language: L10n.shared.language.rawValue, embedded: false))
        } else if url.scheme == "tokenclock-network-retry" {
            decisionHandler(.cancel)
            stopDiagnostics()
            browser?.stopLoading()
            browser = nil
            loadProbe()
        } else {
            decisionHandler(NetworkLeakEndpoint.permits(url) || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    private func stopProbe() {
        browser?.evaluateJavaScript("window.TokenClockLeak?.stop()", completionHandler:nil)
        if browser?.isLoading == true { browser?.stopLoading() }
        stopDiagnostics()
        presentation.running=false
        presentation.status=toolboxText("已停止", "Stopped")
    }

    private func restartProbe() {
        stopDiagnostics()
        browser?.evaluateJavaScript("window.TokenClockLeak?.stop()", completionHandler: nil)
        browser?.stopLoading()
        browser = nil
        presentation.status = toolboxText("正在连接检测服务…", "Connecting…")
        presentation.running = true
        loadProbe()
    }

    private func updateOptions() {
        let value = (try? String(data: JSONEncoder().encode(presentation.expectedDNS), encoding: .utf8)) ?? "\"\""
        browser?.evaluateJavaScript("var e=document.getElementById('expected');if(e){e.value=\(value);e.oninput?.();}var p=document.getElementById('ipv4Only');if(p){p.checked=\(presentation.ipv4Only ? "true" : "false");p.onchange?.();}", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browser, let url = webView.url, NetworkLeakEndpoint.permits(url) else { return }
        updateOptions()
        webView.evaluateJavaScript("""
        (()=>{let queued=false;const send=()=>{queued=false;
        const cards=['exit','dns','rtc','consistency','ipv6','ai','doh'].map(id=>({id,title:document.getElementById(id+'Title')?.textContent||'',status:document.getElementById(id+'Badge')?.textContent||'',state:document.getElementById(id+'Badge')?.dataset.state||'',text:(()=>{const e=document.getElementById(id+'Addresses');if(!e)return '';const rows=Array.from(e.querySelectorAll('.address,.diagnostic-row'));return rows.length?rows.map(r=>(r.classList.contains('diagnostic-row')?[r.querySelector('.diagnostic-name'),r.querySelector('code'),r.querySelector('small')]:Array.from(r.children)).filter(Boolean).map(c=>(c.textContent||'').trim().replace(/\\n/g,' · ')).filter(Boolean).join(' · ')).join('\\n'):(e.textContent||'');})()}));
        window.webkit.messageHandlers.networkPresentation.postMessage({status:document.getElementById('idle')?.textContent||'',summary:document.getElementById('overallSummary')?.textContent||'',running:!!document.getElementById('start')?.disabled,cards});};
        new MutationObserver(()=>{if(!queued){queued=true;queueMicrotask(send);}}).observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true});send();})();
        """, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(webView, error: error)
    }

    private func showLoadError(_ view: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, view === browser else { return }
        stopDiagnostics()
        presentation.running = false
        presentation.status = toolboxText("检测服务暂不可用，请重试。", "Check service unavailable. Retry when connected.")
        let zh = L10n.shared.language.rawValue.hasPrefix("zh")
        let title = zh ? "检测页面暂时无法连接" : "The check could not connect"
        let message = zh ? "本次没有得到检测结果。请检查网络后重试。" : "No result is available. Check your connection and try again."
        let retry = zh ? "重试" : "Retry"
        view.loadHTMLString("""
        <!doctype html><meta name="color-scheme" content="light dark"><style>
        body{font:14px -apple-system,sans-serif;padding:42px;color:CanvasText;background:Canvas}
        h1{font-size:21px}p{opacity:.65;line-height:1.6}a{display:inline-block;margin-top:12px;
        padding:10px 16px;border-radius:9px;background:#2b7e97;color:white;text-decoration:none}
        </style><h1>\(title)</h1><p>\(message)</p><a href="tokenclock-network-retry://retry">\(retry)</a>
        """, baseURL: nil)
    }

    fileprivate func receiveDiagnostics(_ message: WKScriptMessage) {
        if message.name == "networkPresentation" {
            guard message.webView === browser, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == NetworkLeakEndpoint.host,
                  message.frameInfo.securityOrigin.protocol == "https", message.webView === browser,
                  let body = message.body as? [String: Any] else { return }
            presentation.update(body)
            return
        }
        guard message.webView === browser, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == NetworkLeakEndpoint.host,
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              let url = browser?.url, NetworkLeakEndpoint.permits(url),
              let body = message.body as? [String: Any],
              let runID = body["runID"] as? String, NetworkDiagnosticParser.runID(runID) else { return }
        if body["action"] as? String == "cancel" {
            if runID == diagnosticRunID { stopDiagnostics() }
            return
        }
        guard body["action"] as? String == "start", runID != diagnosticRunID else { return }
        stopDiagnostics()
        let fetcher = NetworkDiagnosticFetcher()
        diagnosticFetcher = fetcher
        diagnosticRunID = runID
        let baseline = NetworkDiagnosticParser.address(body["baselineIP"] as? String)
        let dnsToken = (body["dnsToken"] as? String).flatMap { $0.range(of:"^[a-f0-9]{32}$", options:.regularExpression) != nil ? $0 : nil }
        diagnosticsTask = Task { [weak self] in
            let result = await NetworkDiagnostics.run(runID: runID, baselineIP: baseline, fetcher: fetcher, dnsToken: dnsToken)
            fetcher.cancel()
            guard !Task.isCancelled, let self, self.diagnosticRunID == runID,
                  let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) else { return }
            self.browser?.evaluateJavaScript("window.TokenClockLeak?.receiveDiagnostics(\(json))", completionHandler: nil)
            self.diagnosticFetcher = nil
            self.diagnosticsTask = nil
            self.diagnosticRunID = nil
        }
    }

    private func stopDiagnostics() {
        diagnosticsTask?.cancel(); diagnosticsTask = nil
        diagnosticFetcher?.cancel(); diagnosticFetcher = nil
        diagnosticRunID = nil
    }
}

@MainActor
private final class WeakNetworkDiagnosticHandler: NSObject, WKScriptMessageHandler {
    weak var owner: NetworkLeakWindow?
    init(owner: NetworkLeakWindow) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveDiagnostics(message)
    }
}
#endif
