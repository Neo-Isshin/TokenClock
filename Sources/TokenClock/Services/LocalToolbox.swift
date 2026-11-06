#if os(macOS)
import Foundation
import AppKit
import Network

struct LocalToolRoot: Sendable { let name: String; let path: String }
enum LocalToolPaths {
    static func roots() -> [LocalToolRoot] {
        let values: [(String, [String])] = [
            ("Codex", [PathConfig.codexHome()] + PathConfig.codexCandidates()),
            ("Claude Code", [PathConfig.claudeCodeHome()] + PathConfig.claudeCodeCandidates().filter { !$0.hasSuffix("/Claude") }),
            ("Gemini", [PathConfig.geminiHome()] + PathConfig.geminiCandidates()),
            ("OpenClaw", [PathConfig.openclawHome()] + PathConfig.openclawCandidates()),
            ("Hermes", [PathConfig.hermesHome()] + PathConfig.hermesCandidates()),
            ("OpenCode", [PathConfig.opencodeHome()] + PathConfig.opencodeCandidates() + [NSHomeDirectory()+"/.config/opencode"]),
            ("Qwen", [PathConfig.qwenHome()] + PathConfig.qwenCandidates()),
            ("Copilot", [PathConfig.copilotHome()] + PathConfig.copilotCandidates()),
            ("Grok", [PathConfig.grokHome()] + PathConfig.grokCandidates()),
            ("Aider", [PathConfig.aiderHome()] + PathConfig.aiderCandidates()),
            ("Antigravity", [PathConfig.antigravityHome()] + PathConfig.antigravityCandidates()),
            ("Cline", [PathConfig.clineHome()] + PathConfig.clineCandidates()),
            ("Continue", [PathConfig.continueHome()] + PathConfig.continueCandidates()),
            ("Cursor Agent", [PathConfig.cursorAgentHome()] + PathConfig.cursorAgentCandidates()),
            ("ZCode", [PathConfig.zcodeHome()] + PathConfig.zcodeCandidates()),
            ("Kiro", [(PathConfig.kiroSessionsHome() as NSString).deletingLastPathComponent])]
        var seen = Set<String>()
        return values.flatMap { name, paths in paths.compactMap { path in
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            return seen.insert(p).inserted ? LocalToolRoot(name: name, path: p) : nil
        }}
    }
    static func configFiles(roots: [LocalToolRoot]) -> [(String, String)] {
        let names = ["settings.json","settings.local.json","config.json","config.toml","auth.json",".env","settings.yaml","config.yaml","opencode.json","opencode.jsonc"]
        return roots.flatMap { r in names.map { (r.name, r.path + "/" + $0) } }
            + [("Shell",NSHomeDirectory()+"/.zshrc"),("Shell",NSHomeDirectory()+"/.zprofile"),("Shell",NSHomeDirectory()+"/.bash_profile"),("Shell",NSHomeDirectory()+"/.profile")]
    }
}
struct LocalFinding: Identifiable, Sendable, Codable {
    var id = UUID(); let title: String; let detail: String; var path: String? = nil
}
struct LocalLogFile: Identifiable, Sendable, Codable {
    var id: String { path }; let tool: String; let path: String; let size: Int64; let modified: Date; var fileID: String = ""
    var eligible: Bool { modified < Date().addingTimeInterval(-30 * 86400) && ["jsonl","log"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}
struct APIProbeCredential: Sendable {
    let source: String; let provider: String; let key: String; let base: String; let model: String?
    var masked: String { key.count > 12 ? String(key.prefix(4)) + "••••••" + String(key.suffix(4)) : "••••••••" }
}
struct APIProbeResult: Identifiable, Sendable, Codable { var id = UUID(); let source: String; let endpoint: String; let masked: String; let status: String }

enum LocalToolboxResultText {
    private static let phrases: [String:String] = [
        "尚未检查":"Not checked", "上次完整结果":"Last completed check",
        "已停止，保留上次结果":"Stopped; last results kept", "正在更新，保留上次结果…":"Updating; last results kept…",
        "检查完成":"Complete", "读取失败":"Read failed", "扫描未完成":"Scan incomplete", "正则无效":"Invalid regular expression",
        "结果已截断":"Results truncated", "日志未检查":"Log not checked", "已取消":"Cancelled",
        "目录不可读，结果不完整":"Directory unreadable; results are incomplete",
        "文件较多，请缩小路径后重试":"Too many files; narrow the paths and retry",
        "请检查自定义表达式":"Check the custom expression",
        "达到 2000 条，请按工具缩小扫描范围":"Reached 2,000 findings; narrow the tool scope",
        "文件不可读取":"File unreadable", "表达式耗时过长，部分内容未完成":"Expression timed out; some content was not checked",
        "匹配内容已隐藏，仅保留文件与行号":"Matching content hidden; only the file and line are kept",
        "读取中断，结果不完整":"Read interrupted; results are incomplete",
        "NTP 未完成":"NTP incomplete", "NTP 不可达":"NTP unreachable", "NTP 超时":"NTP timed out",
        "请求失败，未更改系统时钟":"Request failed; the system clock was not changed",
        "回包不可验证，不能据此判断时钟异常":"Reply could not be verified; clock drift cannot be determined",
        "UDP 可能被阻止，未更改系统时钟":"UDP may be blocked; the system clock was not changed",
        "未获取到可信回包，未更改系统时钟":"No verified reply; the system clock was not changed",
        "接口可用":"Accepted", "余额/额度不足":"Billing / quota", "区域拒绝":"Region denied",
        "凭据失效":"Invalid credentials", "限流，稍后重试":"Rate limited",
        "权限拒绝，未确认失效":"Permission denied; validity unknown", "未能确认":"Inconclusive",
        "连接失败 / 超时":"Connection failed / timed out"
    ]
    static func localized(_ raw: String) -> String {
        let english = L10n.shared.language == .en
        if let text = phrases[raw] { return english ? text : raw }
        if !english, let pair = phrases.first(where: { $0.value == raw }) { return pair.key }
        var result = raw
        if english {
            result = result.replacingOccurrences(of:#"疑似密钥 · 第 (\d+) 行"#,with:"Suspected key · line $1",options:.regularExpression)
                .replacingOccurrences(of:" · 多处值不同",with:" · Conflicting values")
                .replacingOccurrences(of:#"时钟偏差 ([+\-0-9.]+) 秒"#,with:"Clock offset $1 s",options:.regularExpression)

        } else {
            result = result.replacingOccurrences(of:#"^(.*) · (\d+) files$"#,with:"$1 · $2 个文件",options:.regularExpression)
        }
        if english && raw.hasPrefix("NTP · ") { result = result.replacingOccurrences(of:"仅检测，不校时",with:"Check only; clock unchanged") }
        return result
    }
    static func status(_ raw: String) -> String {
        var result = raw
        let english = L10n.shared.language == .en
        for (cn,en) in phrases.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of:english ? cn : en,with:english ? en : cn)
        }
        if english {
            result = result.replacingOccurrences(of:#"扫描 (\d+) 个文件 · 复用 (\d+) 个文件"#,with:"Scanned $1 files · reused $2",options:.regularExpression)
        } else {
            result = result.replacingOccurrences(of:#"Scanned (\d+) files · reused (\d+)"#,with:"扫描 $1 个文件 · 复用 $2 个文件",options:.regularExpression)
        }
        return result
    }
}
extension LocalFinding {
    var localizedTitle: String { LocalToolboxResultText.localized(title) }
    var localizedDetail: String { LocalToolboxResultText.localized(detail) }
}
extension APIProbeResult {
    var localizedStatus: String { LocalToolboxResultText.status(status) }
}

enum LocalConfigReader {
    static func read(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 2 * 1024 * 1024, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func assignments(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\"([^\"\n]*)\"|'([^'\n]*)'|([^\s#]+))"#, options: [.anchorsMatchLines])
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let index = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) {
                result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: index))
            }
        }
        return result
    }
    static func credentials(text: String, source: String, label: String, environment: [String:String] = ProcessInfo.processInfo.environment, defaultBase: String? = nil, defaultModel: String? = nil) -> [APIProbeCredential] {
        var result: [APIProbeCredential] = []
        let defaults: [String: (String,String)] = ["OPENAI_API_KEY":("openai","https://api.openai.com/v1"),"ANTHROPIC_API_KEY":("anthropic","https://api.anthropic.com/v1"),"GEMINI_API_KEY":("gemini","https://generativelanguage.googleapis.com/v1beta"),"GOOGLE_API_KEY":("gemini","https://generativelanguage.googleapis.com/v1beta"),"DEEPSEEK_API_KEY":("openai","https://api.deepseek.com/v1"),"OPENROUTER_API_KEY":("openrouter","https://openrouter.ai/api/v1")]
        func add(_ key: String, provider: String, base: String, model: String?) {
            var value = key
            if value.hasPrefix("{env:"), value.hasSuffix("}") { value = environment[String(value.dropFirst(5).dropLast())] ?? "" }
            else if value.hasPrefix("env:") { value = environment[String(value.dropFirst(4))] ?? "" }
            else if value.hasPrefix("${"), value.hasSuffix("}") { value = environment[String(value.dropFirst(2).dropLast())] ?? "" }
            guard value.count >= 12, !value.contains("${"), !value.contains("\n"), value.count <= 4096, value.utf8.allSatisfy({(33...126).contains($0)}),
                  let url = URL(string: base), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  ["https","http"].contains(url.scheme ?? ""), !host.isEmpty else { return }
            result.append(.init(source: source, provider: provider, key: value, base: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")), model: model))
        }
        func walk(_ dict: [String:Any], context: String) {
            if dict["type"] as? String == "oauth" { return }
            let base = (dict["baseURL"] ?? dict["baseUrl"] ?? dict["base_url"] ?? dict["apiBase"] ?? dict["apiBaseUrl"] ?? dict["api_base"]) as? String
            let model = dict["model"] as? String
            for (name, value) in dict {
                if let key = value as? String, let (provider, fallback) = defaults[name] {
                    add(key, provider: provider, base: (dict[name.replacingOccurrences(of:"API_KEY",with:"BASE_URL")] as? String) ?? base ?? defaultBase ?? fallback, model: model ?? defaultModel)
                } else if ["apiKey","api_key","apikey"].contains(name) || (name == "key" && dict["type"] as? String == "api") {
                    let hint = ((dict["api"] as? String) ?? context).lowercased()
                    let provider = hint.contains("anthropic") || label.contains("Claude") ? "anthropic" : hint.contains("gemini") || hint == "google" || label == "Gemini" ? "gemini" : hint == "openrouter" ? "openrouter" : hint.contains("responses") ? "responses" : "openai"
                    let known: [String:String] = ["openai":"https://api.openai.com/v1","responses":"https://api.openai.com/v1","anthropic":"https://api.anthropic.com/v1","google":"https://generativelanguage.googleapis.com/v1beta","gemini":"https://generativelanguage.googleapis.com/v1beta","deepseek":"https://api.deepseek.com/v1","openrouter":"https://openrouter.ai/api/v1","xai":"https://api.x.ai/v1","moonshot":"https://api.moonshot.ai/v1","zai":"https://api.z.ai/api/paas/v4"]
                    let fallback = known[hint] ?? known[provider]!
                    if let key = value as? String, base != nil || defaultBase != nil || ["Codex","Claude Code","Gemini"].contains(label) || known[hint] != nil {
                        add(key, provider: provider, base: base ?? defaultBase ?? fallback, model: model ?? defaultModel)
                    }
                }
                if let nested = value as? [String:Any] { walk(nested, context: name == "options" ? (dict["npm"] as? String ?? context) : name) }
                if let nested = value as? [[String:Any]] { for item in nested { walk(item, context: context) } }
            }
        }
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String:Any] { walk(object, context: label) }
        // Continue and other harnesses also keep model entries in simple YAML.
        // Parse scalar fields only: never evaluate tags, anchors or shell syntax.
        if source.hasSuffix(".yaml") || source.hasSuffix(".yml") {
            var block: [String:Any] = [:]
            func flush() { if !block.isEmpty { walk(block,context:block["provider"] as? String ?? label);block=[:] } }
            for raw in text.components(separatedBy:.newlines) {
                let line=raw.trimmingCharacters(in:.whitespaces)
                if line.hasPrefix("- ") { flush() }
                let field=line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                guard let colon=field.firstIndex(of:":") else { continue }
                let key=String(field[..<colon]);var value=String(field[field.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                guard ["provider","model","apiKey","api_key","apiBase","baseURL","baseUrl"].contains(key),!value.isEmpty else {continue}
                if value.first == "\"" || value.first == "'" {let quote=value.first!;value=String(value.dropFirst().prefix{$0 != quote})}
                else {value=value.components(separatedBy:" #")[0]}
                guard !value.hasPrefix("!"),!value.hasPrefix("*"),!value.hasPrefix("&") else {continue}
                block[key]=value
            }
            flush()
        }
        let values = assignments(text)
        for (name, item) in defaults {
            if let key = values[name] {
                let base = values[name.replacingOccurrences(of: "API_KEY", with: "BASE_URL")] ?? defaultBase ?? item.1
                add(key, provider: item.0, base: base, model: values["model"] ?? values["OPENAI_MODEL"])
            }
        }
        // Codex's selected provider: take env_key only from that section.
        if let selected = values["model_provider"] {
            let header = "[model_providers.\(selected)]"
            if let range = text.range(of: header) {
                let section = String(text[range.upperBound...].prefix { $0 != "[" })
                let fields = assignments(section)
                if let variable = fields["env_key"], let key = environment[variable], let base = fields["base_url"] {
                    add(key, provider: fields["wire_api"] == "responses" ? "responses" : "openai", base: base, model: values["model"])
                }
            }
        }
        return result
    }
    static func classify(status: Int?, body: Data) -> String {
        let message = String(decoding: body.prefix(16384), as: UTF8.self).lowercased()
        if status == 200 { return "✅ " + toolboxText("接口可用", "Accepted") }
        if status == 402 || message.contains("insufficient_quota") || message.contains("credit balance") || message.contains("insufficient balance") || message.contains("insufficient_balance") || message.contains("payment_required") { return "💸 " + toolboxText("余额/额度不足", "Billing / quota") }
        if message.contains("unsupported_country") || message.contains("country_not_supported") || message.contains("region is not supported") || message.contains("not available in your region") || message.contains("user location is not supported") { return "🌍 " + toolboxText("区域拒绝", "Region denied") }
        if status == 401 || message.contains("invalid_api_key") || message.contains("api_key_invalid") || message.contains("api key not valid") { return "❌ " + toolboxText("凭据失效", "Invalid credentials") }
        if status == 429 { return toolboxText("限流，稍后重试", "Rate limited") }
        if status == 403 { return toolboxText("权限拒绝，未确认失效", "Permission denied; validity unknown") }
        return status.map { "HTTP \($0) · " + toolboxText("未能确认", "Inconclusive") } ?? toolboxText("连接失败 / 超时", "Connection failed / timed out")
    }
    static func probe(_ credential: APIProbeCredential, transport: NetworkDiagnosticFetcher = NetworkDiagnosticFetcher()) async -> APIProbeResult {
        defer { transport.cancel() }
        let suffix = credential.provider == "openrouter" ? "/auth/key" : "/models"
        let base = credential.base
        let normalized = URL(string: base)!.path.isEmpty ? base + (credential.provider == "gemini" ? "/v1beta" : "/v1") : base
        var request = URLRequest(url: URL(string: normalized + suffix)!)
        if credential.provider == "anthropic" {
            request.setValue(credential.key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if credential.provider == "gemini" { request.setValue(credential.key, forHTTPHeaderField: "x-goog-api-key") }
        else { request.setValue("Bearer " + credential.key, forHTTPHeaderField: "Authorization") }
        var reply = await transport.fetch(request)
        var usedToken = false
        if [404,405].contains(reply.status ?? 0), let model = credential.model, !model.isEmpty, !Task.isCancelled, credential.provider != "openrouter" {
            let endpoint = credential.provider == "anthropic" ? "/messages" : credential.provider == "responses" ? "/responses" : "/chat/completions"
            if credential.provider != "gemini" {
                request.url = URL(string: normalized + endpoint); request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String:Any] = credential.provider == "responses" ? ["model":model,"input":".","max_output_tokens":1]
                    : ["model":model,"messages":[["role":"user","content":"."]],"max_tokens":1]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                reply = await transport.fetch(request); usedToken = true
            }
        }
        return APIProbeResult(source: credential.source, endpoint: normalized.replacingOccurrences(of: credential.key, with: "••••••••"), masked: credential.masked,
            status: classify(status: reply.status, body: reply.data) + (usedToken ? " · 1-token" : ""))
    }
}

enum LocalLogScanner {
    static func inventory(roots: [LocalToolRoot], cancelled: @Sendable () -> Bool) -> ([LocalLogFile], [LocalFinding]) {
        var files: [LocalLogFile] = []; var notes: [LocalFinding] = []; var seen = Set<String>(); var visited = 0
        let expanded = roots + roots.flatMap { r in ["sessions","projects","tasks"].compactMap { name -> LocalToolRoot? in
            let url = URL(fileURLWithPath:r.path+"/"+name);guard (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true else {return nil};return LocalToolRoot(name:r.name,path:url.resolvingSymlinksInPath().path)
        }}
        for root in expanded {
            guard !cancelled() else { break }
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root.path).resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey], options: [.skipsHiddenFiles], errorHandler: { url,_ in notes.append(.init(title: "读取失败", detail: "目录不可读，结果不完整", path: url.path)); return true }) else { continue }
            for case let url as URL in enumerator {
                if cancelled() { break }
                visited += 1
                if visited > 250000 { notes.append(.init(title: "扫描未完成", detail: "文件较多，请缩小路径后重试")); return (files,notes) }
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey]) else { continue }
                if v.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if ["node_modules",".git","Cache","Caches","GPUCache","webview","browser","vendor"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard v.isRegularFile == true, ["jsonl","log","json","db","sqlite"].contains(url.pathExtension.lowercased()), seen.insert(url.standardizedFileURL.path).inserted else { continue }
                // Configuration/authentication files are never cleanup candidates or log-scan inputs.
                guard !["auth.json","auth-profiles.json","credentials.json","oauth_creds.json","settings.json","settings.local.json","config.json"].contains(url.lastPathComponent) else { continue }
                files.append(.init(tool: root.name, path: url.path, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? Date(), fileID: String(describing:v.fileResourceIdentifier)))
            }
        }
        return (files,notes)
    }
    static func leaks(files: [LocalLogFile], pattern: String, cancelled: @Sendable () -> Bool) -> [LocalFinding] {
        let builtins = #"sk-[A-Za-z0-9_-]{16,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern.isEmpty ? builtins : "(?:"+builtins+")|(?:"+pattern+")") else { return [.init(title: "正则无效", detail: "请检查自定义表达式")] }
        var findings: [LocalFinding] = []
        for file in files where ["jsonl","log","json"].contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()) {
            if cancelled() { break }
            if URL(fileURLWithPath:file.path).pathExtension.lowercased() == "json", !["/sessions/","/projects/","/tasks/","/logs/"].contains(where:{file.path.contains($0)}) { continue }
            if findings.count >= 2000 { findings.append(.init(title:"结果已截断",detail:"达到 2000 条，请按工具缩小扫描范围"));break }
            guard let handle = FileHandle(forReadingAtPath: file.path) else { findings.append(.init(title:"日志未检查",detail:"文件不可读取",path:file.path));continue }
            defer { try? handle.close() }
            var carry = Data(); var line = 1
            func scan(_ bytes: Data) {
                let text = String(decoding: bytes, as: UTF8.self); let began = Date(); var hit = false; var expired = false
                regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match,_,stop in
                    if cancelled() || Date().timeIntervalSince(began) > 0.1 { expired = true; stop.pointee = true }
                    if match != nil { hit = true; stop.pointee = true }
                }
                if expired && !cancelled() { findings.append(.init(title: "日志未检查", detail: "表达式耗时过长，部分内容未完成", path: file.path)) }
                if hit { findings.append(.init(title: "疑似密钥 · 第 \(line) 行", detail: "匹配内容已隐藏，仅保留文件与行号", path: file.path)) }
            }
            while !cancelled(), findings.count < 2000 {
                let data: Data
                do { data = try handle.read(upToCount: 65536) ?? Data() }
                catch { findings.append(.init(title: "日志未检查", detail: "读取中断，结果不完整", path: file.path)); break }
                if data.isEmpty { if !carry.isEmpty { scan(carry) }; break }
                carry.append(data)
                while let newline = carry.firstIndex(of: 10) {
                    let segment = carry.prefix(upTo: newline)
                    for offset in stride(from: 0, to: segment.count, by: 8064) { scan(Data(segment.dropFirst(offset).prefix(8192))) }
                    carry.removeSubrange(...newline); line += 1
                }
                while carry.count > 8192 { scan(carry.prefix(8192)); carry.removeFirst(8064) }
            }
        }
        return findings
    }
    static func recycle(_ file: LocalLogFile) throws {
        let url = URL(fileURLWithPath: file.path)
        let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey])
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path, file.eligible, !file.fileID.isEmpty, String(describing:v.fileResourceIdentifier) == file.fileID, v.isSymbolicLink != true, v.isRegularFile == true, v.fileSize == Int(file.size), v.contentModificationDate == file.modified else { throw CocoaError(.fileWriteFileExists) }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    }
}

@MainActor final class LocalToolboxModel: ObservableObject {
    @Published var busy = false
    @Published var status = ""
    @Published var findings: [LocalFinding] = []
    @Published var files: [LocalLogFile] = []
    @Published var keys: [APIProbeResult] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var selectedMode = "environment"
    @Published private(set) var cacheError = ""
    private let resultsURL: URL
    private let secretCacheURL: URL
    private var snapshots: [String: LocalToolboxSnapshot] = [:]
    private var task: Task<Void,Never>?
    private var runID: UUID?
    init(directory: URL = URL(fileURLWithPath: NSHomeDirectory()+"/.tokenclock")) {
        resultsURL = directory.appendingPathComponent("local-toolbox-results.json")
        secretCacheURL = directory.appendingPathComponent("local-toolbox-secrets.json")
        if let data = try? Data(contentsOf: resultsURL), let saved = try? JSONDecoder().decode(LocalToolboxResults.self, from: data) {
            snapshots = saved.snapshots; selectedMode = saved.selectedMode
        }
        selectMode(selectedMode)
    }
    func selectMode(_ mode: String) {
        stop(); selectedMode = mode
        let saved = snapshots[mode]
        checkedAt = saved?.checkedAt; findings = saved?.findings ?? []; files = saved?.files ?? []; keys = saved?.keys ?? []
        status = saved == nil ? toolboxText("尚未检查", "Not checked") : toolboxText("上次完整结果", "Last completed check")
    }
    func stop() {
        task?.cancel(); task = nil; runID = nil
        if busy { status = toolboxText("已停止，保留上次结果", "Stopped; last results kept") }
        busy = false
    }
    func run(_ mode: String, pattern: String = "", full: Bool = false) {
        if mode != selectedMode { selectMode(mode) }
        stop(); busy = true; cacheError = ""; status = toolboxText("正在更新，保留上次结果…", "Updating; last results kept…")
        let id = UUID(); runID = id
        task = Task {
            var nextFindings: [LocalFinding] = [], nextFiles: [LocalLogFile] = [], nextKeys: [APIProbeResult] = []
            var scanDetail = ""
            let roots = LocalToolPaths.roots()
            if mode == "keys" {
                let collection = Task.detached { () -> [APIProbeCredential] in
                    var all: [APIProbeCredential] = []; var seen = Set<String>()
                    for (label,path) in LocalToolPaths.configFiles(roots: roots) {
                        if Task.isCancelled { break }
                        if let text = LocalConfigReader.read(path) {
                            var base: String?, model: String?
                            if label == "Codex", let config=LocalConfigReader.read((path as NSString).deletingLastPathComponent+"/config.toml") {
                                let values=LocalConfigReader.assignments(config); model=values["model"]
                                if let selected=values["model_provider"],let start=config.range(of:"[model_providers.\(selected)]") {
                                    let fields=LocalConfigReader.assignments(String(config[start.upperBound...].prefix{$0 != "["}));base=fields["base_url"]
                                }
                            }
                            all += LocalConfigReader.credentials(text: text, source: path, label: label, defaultBase:base, defaultModel:model)
                        }
                    }
                    let env = ProcessInfo.processInfo.environment
                    let text = env.filter { $0.key.hasSuffix("API_KEY") || $0.key.hasSuffix("BASE_URL") }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: "\n")
                    all += LocalConfigReader.credentials(text: text, source: "Current process", label: "Environment")
                    return all.filter { seen.insert($0.provider+"|"+$0.base+"|"+$0.key).inserted }
                }
                let entries = await withTaskCancellationHandler { await collection.value } onCancel: { collection.cancel() }
                guard !Task.isCancelled else { return }
                await withTaskGroup(of: APIProbeResult.self) { group in
                    var next = 0
                    while next < min(3,entries.count) { let e=entries[next]; group.addTask { await LocalConfigReader.probe(e) }; next += 1 }
                    for await result in group {
                        if Task.isCancelled { group.cancelAll(); break }
                        nextKeys.append(result)
                        if next < entries.count { let e=entries[next]; group.addTask { await LocalConfigReader.probe(e) }; next += 1 }
                    }
                }
            } else if mode == "environment" {
                let job = Task.detached { Self.environment(roots: roots) }
                let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled else { return }; nextFindings = result
            } else if mode == "clock" {
                let result = await NTPClockCheck.check()
                guard !Task.isCancelled else { return }; nextFindings = [result]
            } else {
                let job = Task.detached { LocalLogScanner.inventory(roots: roots, cancelled: { Task.isCancelled }) }
                let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled else { return }
                nextFiles = result.0
                if mode == "secrets" {
                    let logs = nextFiles
                    let cacheURL = self.secretCacheURL
                    let job = Task.detached { LocalSecretCache.scan(files: logs, pattern: pattern, full: full, url: cacheURL, cancelled: { Task.isCancelled }) }
                    let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                    guard !Task.isCancelled else { return }; nextFindings = result.findings
                    scanDetail = toolboxText("扫描 \(result.scanned) 个文件 · 复用 \(result.reused) 个文件", "Scanned \(result.scanned) files · reused \(result.reused)")
                } else {
                    nextFindings = Dictionary(grouping: nextFiles, by: \.tool).map { name,logs in
                        LocalFinding(title: name, detail: ByteCountFormatter.string(fromByteCount: logs.reduce(0){$0+$1.size}, countStyle: .file)+" · \(logs.count) files")
                    }.sorted { $0.title < $1.title }
                }
                nextFindings += result.1
            }
            guard !Task.isCancelled, runID == id else { return }
            findings = nextFindings; files = nextFiles; keys = nextKeys; checkedAt = Date()
            snapshots[mode] = .init(checkedAt: checkedAt!, findings: findings, files: files, keys: keys)
            do { try LocalToolboxPersistence.save(LocalToolboxResults(selectedMode: mode, snapshots: snapshots), to: resultsURL) }
            catch { cacheError = toolboxText("结果已显示，但本次未能保存到磁盘。", "Results shown, but could not save this check.") }
            busy = false; runID = nil; task = nil
            status = toolboxText("检查完成", "Complete") + (scanDetail.isEmpty ? "" : " · " + scanDetail)
            if mode == "keys" && keys.isEmpty { status += toolboxText(" · 未发现 API Key（订阅登录不属于 API Key）", " · No API keys found (subscription logins are excluded)") }
        }
    }
    nonisolated private static func safeValue(_ value: String) -> String {
        if var parts=URLComponents(string:value),parts.host != nil {parts.user=nil;parts.password=nil;parts.query=nil;parts.fragment=nil;return String((parts.string ?? "[URL]").prefix(300))}
        return String(value.prefix(300))
    }
    nonisolated private static func environment(roots: [LocalToolRoot]) -> [LocalFinding] {
        var values: [String:[(String,String)]] = [:]
        for (_,path) in LocalToolPaths.configFiles(roots: roots) {
            if Task.isCancelled { break }
            guard let text = LocalConfigReader.read(path) else { continue }
            var fields = LocalConfigReader.assignments(text)
            if let data=text.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let env=object["env"] as? [String:String] { fields.merge(env){_,v in v} }
            for (key,value) in fields where key.hasSuffix("BASE_URL") || key.hasSuffix("API_KEY") || ["model","model_provider","base_url"].contains(key) { values[key,default:[]].append((path,value)) }
        }
        for (key,value) in ProcessInfo.processInfo.environment where key.hasSuffix("BASE_URL") || key.hasSuffix("API_KEY") { values[key,default:[]].append(("TokenClock process",value)) }
        // launchctl getenv is read-only: never source shell profiles or set env.
        for key in ["ANTHROPIC_BASE_URL","OPENAI_BASE_URL","ANTHROPIC_API_KEY","OPENAI_API_KEY"] {
            if Task.isCancelled { break }
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/launchctl");p.arguments=["getenv",key];let pipe=Pipe();p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
            if (try? p.run()) != nil { let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();if let v=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),!v.isEmpty { values[key,default:[]].append(("launchd",v)) } }
        }
        return values.keys.sorted().map { key in
            let entries=values[key]!;let unique=Set(entries.map(\.1));let secret=key.hasSuffix("KEY")
            let detail=entries.map { source,value in source+" → "+(secret ? "•••••••• [variant \(Array(unique.sorted()).firstIndex(of:value)!+1)]" : safeValue(value)) }.joined(separator:"\n")
            return LocalFinding(title:key+(unique.count>1 ? " · 多处值不同" : ""),detail:detail)
        }
    }
}
#endif
