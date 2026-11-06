import Foundation

/// Compiled with the actual ClaudeQuotaNetwork.swift; no XCTest or user login needed.
@main struct ClaudeQuotaProxySmoke {
    static func main() throws {
        if CommandLine.arguments.contains("--wire") {
            let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
            if let anchor = input["fixture_anchor"] as? String { ClaudeQuotaNetwork.fixtureAnchorPath = anchor }
            var request = URLRequest(url: URL(string: input["target"] as! String)!)
            request.timeoutInterval = input["timeout"] as? Double ?? 2
            request.httpMethod = "GET"
            request.setValue("Bearer SYNTHETIC-NOT-A-CREDENTIAL", forHTTPHeaderField: "Authorization")
            request.setValue("sessionKey=SYNTHETIC-NOT-A-COOKIE", forHTTPHeaderField: "Cookie")
            let route: ClaudeQuotaNetwork.Route?
            do {
                route = try ClaudeQuotaNetwork.resolve(url: request.url!,
                    environment: (input["proxy"] as? String).map { ["HTTPS_PROXY": $0] } ?? [:],
                    settings: nil, system: input["system"] as? [String:Any] ?? [:],
                    mode: input["require_proxy"] as? Bool == true ? .requireProxy : .system)
            } catch {
                print("{\"success\":false,\"blocked\":true}"); return
            }
            switch ClaudeQuotaNetwork.transfer(request, route: route) {
            case .success(let response): print("{\"success\":true,\"status\":\(response.status),\"bytes\":\(response.data.count)}")
            case .failure: print("{\"success\":false}")
            }
            return
        }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); count += 1 }
        let url = URL(string: "https://claude.ai/api/account")!
        let system: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]
        func blocked(env: [String:String] = [:], settings: Data? = nil, sys: [String:Any] = [:], mode: ClaudeQuotaNetwork.Mode = .requireProxy) {
            do { _ = try ClaudeQuotaNetwork.resolve(url: url, environment: env, settings: settings, system: sys, mode: mode); preconditionFailure("Direct/unsupported proxy admitted") }
            catch { count += 1 }
        }
        let suiteName = "tc-proxy-policy-fixture-"+UUID().uuidString
        let prefs = UserDefaults(suiteName: suiteName)!
        defer { prefs.removePersistentDomain(forName:suiteName) }
        check(ClaudeQuotaNetwork.mode(defaults:prefs) == .system)
        prefs.set(true,forKey:SettingsKey.claudeQuotaRequireProxy.rawValue)
        check(ClaudeQuotaNetwork.mode(defaults:prefs) == .requireProxy)
        prefs.set(false,forKey:SettingsKey.claudeQuotaRequireProxy.rawValue)
        check(ClaudeQuotaNetwork.mode(defaults:prefs) == .system)
        let direct = try ClaudeQuotaNetwork.resolve(url:url,environment:[:],settings:nil,system:[:])
        let tun = try ClaudeQuotaNetwork.resolve(url:url,environment:[:],settings:nil,system:["__SCOPED__":["utun8":[:]]])
        check(direct == nil); check(tun == nil)
        let directCall = try ClaudeQuotaNetwork.invocation(URLRequest(url:url),route:direct)
        check(String(decoding:directCall.configuration,as:UTF8.self).contains("proxy = \"\""))
        check(!directCall.arguments.contains("--interface")) // No restriction on OS/TUN routing.
        let excluded = try ClaudeQuotaNetwork.resolve(url:url,environment:[:],settings:nil,
            system:system.merging(["ExceptionsList":["claude.ai"]]) { _,b in b })
        check(excluded == nil)
        blocked() // Only require-proxy mode blocks absent/ordinary TUN routes.
        blocked(sys: ["__SCOPED__": ["utun8": [:]]])
        blocked(sys: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://127.0.0.1/pac"])
        blocked(sys: ["ProxyAutoDiscoveryEnable": 1])
        blocked(sys: ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890])
        blocked(sys: system.merging(["ExceptionsList": ["claude.ai"]]) { _, b in b })
        for value in ["", "127.0.0.1:7890", "file:///tmp/proxy", "http://127.0.0.1:999999", "http://proxy/path", "http://proxy?key=x", "http://proxy#fragment", "http://proxy\n"] {
            blocked(env: ["HTTPS_PROXY":value], sys: system)
            blocked(env: ["HTTPS_PROXY":value], sys: system, mode:.system)
        }
        blocked(settings: Data("not-json".utf8), sys: system)
        blocked(settings: Data(#"{"env":{"HTTPS_PROXY":false}}"#.utf8), sys: system)
        blocked(env: ["HTTPS_PROXY":"http://127.0.0.1:7890"], settings: Data(#"{"env":{"HTTPS_PROXY":"http://127.0.0.1:7891"}}"#.utf8), sys: system)
        let selected = try ClaudeQuotaNetwork.resolve(url: url, environment: [:], settings: nil, system: system)!
        check(selected.kind == .http && selected.port == 7890)
        let explicit = try ClaudeQuotaNetwork.resolve(url: url, environment: ["HTTPS_PROXY":"http://127.0.0.1:8890","NO_PROXY":"*"], settings:nil, system:system)!
        check(explicit.port == 8890) // A bypass variable never creates a direct alternative.
        let settings = try ClaudeQuotaNetwork.resolve(url: url, environment: [:], settings: Data(#"{"env":{"HTTPS_PROXY":"socks5h://127.0.0.1:7891"}}"#.utf8), system:[:])!
        check(settings.kind == .socks5 && settings.port == 7891)
        let authenticated = try ClaudeQuotaNetwork.parseProxy("https://u:p@proxy.example:8443")
        check(authenticated.kind == .https && authenticated.username == "u" && authenticated.password == "p")
        for route in [selected, explicit, settings, authenticated] {
            var request = URLRequest(url:url); request.setValue("SYNTHETIC-SECRET",forHTTPHeaderField:"Authorization")
            let call = try ClaudeQuotaNetwork.invocation(request, route: route)
            check(call.arguments.first == "-q")
            check(call.arguments[call.arguments.firstIndex(of:"--noproxy")!+1] == "")
            check(call.arguments[call.arguments.firstIndex(of:"--retry")!+1] == "0")
            check(!call.arguments.contains("--location") && !call.arguments.contains("--insecure"))
            check(!call.arguments.joined().contains("SYNTHETIC-SECRET"))
            check(call.environment.keys.allSatisfy { ["PATH","LANG"].contains($0) })
            check(String(decoding:call.configuration,as:UTF8.self).contains(route.proxyURL))
        }
        for path in ["https://claude.ai/api/account", "https://claude.ai/api/organizations", "https://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com/api/oauth/profile", "https://claude.ai/api/organizations/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/usage"] {
            check(ClaudeQuotaNetwork.allowed(URLRequest(url: URL(string:path)!)))
        }
        for path in ["http://claude.ai/api/account", "https://evil.invalid/api/account", "https://claude.ai/api/messages", "https://user@claude.ai/api/account", "https://claude.ai:8443/api/account", "https://claude.ai/api/account?key=test", "https://claude.ai/api/organizations/not-a-uuid/usage"] {
            check(!ClaudeQuotaNetwork.allowed(URLRequest(url: URL(string:path)!)))
        }
        var post = URLRequest(url: url);post.httpMethod = "POST"
        check(!ClaudeQuotaNetwork.allowed(post))
        // Require-proxy remains blocked after config removal; the default may
        // select OS routing for a NEW request, never retry a failed proxy request.
        blocked(sys: [:])
        let pinned = try ClaudeQuotaNetwork.invocation(URLRequest(url:url),route:selected)
        check(String(decoding:pinned.configuration,as:UTF8.self).contains(selected.proxyURL))
        print("{\"policy_assertions\":\(count),\"model_calls\":0}")
    }
}
