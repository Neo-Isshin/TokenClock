#if os(macOS)
import Foundation
import Combine

/// Native presentation only. The existing local worker owns probes, grading and billing.
@MainActor
final class ModelDetectNativeModel: ObservableObject {
    enum Phase { case input, running, result }
    enum Mode: String, CaseIterable { case session, api }
    struct Session: Identifiable { let id: String; let title: String; let url: URL; var model: String? = nil }
    struct ModelField: Identifiable {
        let id: String; let model: String; let scope: String; let owner: String; let location: String
    }
    struct Connection: Identifiable { let id: String; let title: String }
    struct History: Identifiable { let id: String; let title: String; let status: String; var detail: String = "" }
    struct FollowUp: Identifiable { let id: String; let title: String; let reason: String; let requestCount: Int; let reserve: String }
    struct Preview {
        let summary: String
        let targetSummary: String?
        let judgeSummary: String?
        let budgetSummary: String
        let warning: String?
        var referenceTitle: String? = nil
        var referenceSummary: String? = nil
        var followUpReason: String? = nil
    }
    struct Brief {
        let title: String
        let summary: String
        let reasons: [String]
        let caveat: String
        let primaryActionTitle: String?
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    typealias Starter = (@escaping ModelIntegrityLauncher.Completion) -> Void

    @Published var phase: Phase = .input
    @Published var mode: Mode = .session { didSet { configurationChanged() } }
    @Published var sourceURL: URL? { didSet { configurationChanged() } }
    @Published var selectedSessionID = ""
    @Published var comparisonModel = "" { didSet { configurationChanged() } }
    @Published var recentSessions: [Session] = []
    @Published var connections: [Connection] = []
    @Published var selectedConnectionID = ""
    @Published var endpoint = "" { didSet { if !restoring && oldValue != endpoint { inputPrice = ""; outputPrice = "" }; connectionEdited(); configurationChanged() } }
    @Published var modelID = "" { didSet { if !restoring && oldValue != modelID { inputPrice = ""; outputPrice = "" }; connectionEdited(); configurationChanged() } }
    @Published var apiKey = "" { didSet { if !restoring { keyBinding = identity; selectedConnectionID = "" }; configurationChanged() } }
    @Published var apiFormat = "chat_completions" { didSet { if !restoring && oldValue != apiFormat { inputPrice = ""; outputPrice = "" }; connectionEdited(); configurationChanged() } }
    @Published var inputPrice = "" { didSet { configurationChanged() } }
    @Published var outputPrice = "" { didSet { configurationChanged() } }
    @Published var budget = "1" { didSet { configurationChanged() } }
    @Published var probeDepth = "l2" { didSet { configurationChanged() } }
    @Published var heavyTask = "H01" { didSet { configurationChanged() } }
    @Published var filePurpose = "session" { didSet { configurationChanged() } }
    @Published var advancedFamily = "auto" { didSet { configurationChanged() } }
    @Published var taskIDs = "" { didSet { configurationChanged() } }
    @Published var l2Method = "numeric" { didSet { if l2Method == "numeric" { assessmentEnabled = false }; configurationChanged() } }
    @Published var assessmentEnabled = false { didSet { configurationChanged() } }
    @Published var reuseTargetForAssessment = true { didSet { configurationChanged() } }
    @Published var judgeModelID = "" { didSet { if !restoring && oldValue != judgeModelID { judgeInputPrice = ""; judgeOutputPrice = "" }; configurationChanged() } }
    @Published var judgeEndpoint = "" { didSet { if !restoring && oldValue != judgeEndpoint { judgeInputPrice = ""; judgeOutputPrice = "" }; configurationChanged() } }
    @Published var judgeKey = "" { didSet { if !restoring { judgeKeyBinding = judgeIdentity }; configurationChanged() } }
    @Published var judgeFormat = "chat_completions" { didSet { if !restoring && oldValue != judgeFormat { judgeInputPrice = ""; judgeOutputPrice = "" }; configurationChanged() } }
    @Published var judgeInputPrice = "" { didSet { configurationChanged() } }
    @Published var judgeOutputPrice = "" { didSet { configurationChanged() } }
    @Published var judgeBudget = "1" { didSet { configurationChanged() } }
    @Published var judgeImageTokens = "" { didSet { configurationChanged() } }
    @Published var judgeOutputLimit = "24576" { didSet { configurationChanged() } }
    @Published var models: [String] = []
    @Published var preview: Preview?
    @Published var targetConsent = false
    @Published var judgeConsent = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var progressTitle = "正在检测"
    @Published var progressMessage = ""
    @Published var progressFraction: Double?
    @Published var brief: Brief?
    @Published var resultObjectLabel = ""
    @Published var detailText = ""
    @Published var presentation = ModelDetectResultPresentation()
    @Published var modelFields: [ModelField] = []
    @Published var modelFieldCount = 0
    @Published var history: [History] = []
    @Published var costSummary = ""
    @Published var resultSuggestion = ""
    @Published var followUps: [FollowUp] = []
    @Published var selectedFollowUpID = ""
    @Published var historyComparison: ModelDetectJSON = .null
    @Published var selectedHistoryID = ""
    @Published var comparingHistory = false
    @Published var referenceOverview: ModelDetectJSON = .null
    @Published var referenceLoading = false
    @Published var referenceError: String?
    @Published private(set) var canReconnect = false

    private(set) var currentJobID: String?
    private(set) var revision = 0
    private var restoring = false
    private var service: (any ModelDetectNativeServing)?
    private let starter: Starter
    private let serviceFactory: (URL) throws -> any ModelDetectNativeServing
    private let pollInterval: UInt64
    private var polling: Task<Void, Never>?
    private var reconnecting = false
    private var preparedRevision: Int?
    private var preparedConfiguration: ModelDetectJSON?
    private var preparedResult: ModelDetectJSON?
    private var resumeID: String?
    private var lineageOrigin: String?
    private var lineageAction: String?
    private var lineageBinding: ModelDetectJSON?
    private var lineageLimit: Decimal?
    private var lastReport: ModelDetectJSON = .null
    private var lastJob: ModelDetectJSON = .null
    private var profiles: [String: ModelDetectJSON] = [:]
    private var catalog: [String: ModelDetectJSON] = [:]
    private var keyBinding = ""
    private var judgeKeyBinding = ""
    private var profileBinding = ""
    private var submissionUncertain = false
    private var historySelection = UUID()
    private var comparisonSelection = UUID()

    var comparisonCandidates: [History] { history.filter { $0.status == "completed" && $0.id != currentJobID } }
    var selectedFollowUp: FollowUp? { followUps.first { $0.id == selectedFollowUpID } }
    var canCompareHistory: Bool { phase == .result && lastJob["status"].string == "completed" && !lastReport.object.isEmpty }
    var needsReferenceChoice: Bool { mode == .api && probeDepth == "l2" && l2Method != "numeric" && advancedFamily == "auto" && !modelID.isEmpty && (try? resolvedFamily()) == nil }
    var credentialHint: String? {
        if mode == .api && !hasTargetCredential { return "请先填写这个接口的密钥，或选择已保存的连接。" }
        if assessmentEnabled && !hasJudgeCredential { return "请补充解析所用连接的密钥。" }
        return nil
    }
    var canReturnToResult: Bool { phase == .input && lineageOrigin != nil && !isBusy }
    func returnToResult() {
        guard canReturnToResult, let origin = lineageOrigin else { return }
        configurationChanged(); showHistory(id: origin)
    }

    init(service: (any ModelDetectNativeServing)? = nil,
         starter: @escaping Starter = { ModelIntegrityLauncher.shared.start(completion: $0) },
         serviceFactory: @escaping (URL) throws -> any ModelDetectNativeServing = { try ModelDetectNativeClient(baseURL: $0) },
         pollInterval: UInt64 = 1_000_000_000) {
        self.service = service; self.starter = starter; self.serviceFactory = serviceFactory; self.pollInterval = pollInterval
    }
    deinit { polling?.cancel() }

    private var identity: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + apiFormat }
    private var judgeIdentity: String { judgeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + judgeFormat }
    private var fullIdentity: String { identity + "|" + modelID }
    private var hasTargetCredential: Bool {
        let state = profiles[selectedConnectionID]?["credential_state"].string ?? ""
        return (!selectedConnectionID.isEmpty && profileBinding == fullIdentity && ["session", "system_store"].contains(state)) || (!apiKey.isEmpty && keyBinding == identity)
    }
    private var hasJudgeCredential: Bool {
        mode == .api && reuseTargetForAssessment ? hasTargetCredential : !judgeKey.isEmpty && judgeKeyBinding == judgeIdentity
    }
    private var wantsExternal: Bool { mode == .api || assessmentEnabled }
    var canPrepare: Bool { service != nil && !isBusy && phase == .input && (mode == .api || sourceURL != nil || resumeID != nil) }
    var canStart: Bool {
        guard !isBusy, phase == .input, let preparedRevision, preparedRevision == revision, let p = preparedResult, p["valid"].bool == true else { return false }
        let roles = p["roles"].array
        if wantsExternal {
            guard p["local_only"].bool == false,
                  mode != .api || roles.contains(where: { $0["role"].string == "target" }),
                  !assessmentEnabled || roles.contains(where: { $0["role"].string == "judge" }) else { return false }
        } else if p["local_only"].bool != true || !roles.isEmpty { return false }
        for role in roles {
            if role["role"].string == "target" { if !targetConsent || !hasTargetCredential { return false } }
            else if !judgeConsent || !hasJudgeCredential { return false }
        }
        return true
    }

    var canConfirmReviewed: Bool {
        guard !isBusy, phase == .input, preparedRevision == revision,
              let p = preparedResult, p["valid"].bool == true else { return false }
        let roles = p["roles"].array
        let expectedRoles: Set<String> = Set((mode == .api ? ["target"] : []) + (assessmentEnabled ? ["judge"] : []))
        guard Set(roles.compactMap { $0["role"].string }) == expectedRoles, roles.count == expectedRoles.count else { return false }
        if wantsExternal {
            guard p["local_only"].bool == false,
                  mode != .api || (hasTargetCredential && roles.contains { $0["role"].string == "target" }),
                  !assessmentEnabled || (hasJudgeCredential && roles.contains { $0["role"].string == "judge" }) else { return false }
        } else if p["local_only"].bool != true || !roles.isEmpty { return false }
        return true
    }
    /// Called only by the explicit button below the displayed scope and cost.
    func confirmReviewedStart() {
        guard canConfirmReviewed else { return }
        let roles = preparedResult?["roles"].array ?? []
        targetConsent = roles.contains { $0["role"].string == "target" }
        judgeConsent = roles.contains { $0["role"].string == "judge" }
        confirmStart()
    }
    var planSummary: String {
        if mode == .session {
            return filePurpose == "session" ? "快速检测 · 型号记录、工作过程与可见异常 · 本地处理" : "核验已有内容 · 不生成新的待测回答"
        }
        if probeDepth == "l3" { return "深入检测 · 一项交付任务 · 开始前确认费用" }
        if l2Method == "numeric" { return "数字指纹 · 3 次独立请求 · 本机自动判断型号，无需模型评分" }
        let count = taskIDs.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return "快速检测 · \(count == 0 ? 3 : count) 道短题，各独立重复 2 次 · 原始型号字段同步核对"
    }
    var targetDescription: String {
        let url = URL(string: endpoint)
        let host = (url?.host ?? "未填写接口") + (url?.port.map { ":\($0)" } ?? "")
        return (modelID.isEmpty ? "未选择型号" : modelID) + " · " + host
    }

    func configurationChanged() {
        guard !restoring else { return }
        revision += 1; preview = nil; preparedConfiguration = nil; preparedResult = nil; preparedRevision = nil
        targetConsent = false; judgeConsent = false
    }
    private func connectionEdited() {
        if !restoring && profileBinding != fullIdentity { selectedConnectionID = "" }
    }
    private func restored(_ block: () -> Void) { let old = restoring; restoring = true; block(); restoring = old }
    private func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "本地检测未能完成，请检查配置后重试。" }
    private func request(_ route: String, body: ModelDetectJSON? = nil) async throws -> ModelDetectJSON {
        guard let service else { throw Failure(message: "检测服务尚未就绪。") }
        do { return try await service.request(route, body: body) }
        catch {
            if let error = error as? ModelDetectNativeClientError {
                switch error { case .transportUnavailable, .invalidReadyURL, .unexpectedOrigin: canReconnect = true; default: break }
            }
            throw error
        }
    }

    func connect() { Task { await connectNow() } }
    func connectNow() async {
        guard !reconnecting else { return }; reconnecting = true
        defer { reconnecting = false }
        do {
            if canReconnect { service = nil }
            if service == nil {
                isBusy = true
                let url: URL = try await withCheckedThrowingContinuation { continuation in starter { continuation.resume(with: $0.mapError { $0 as Error }) } }
                service = try serviceFactory(url)
                canReconnect = false
                isBusy = false
            }
            errorMessage = nil
            await refreshSessionsNow(); await refreshConnectionsNow(); await refreshHistoryNow()
            if phase == .running, let id = currentJobID { beginPolling(id) }
        } catch { isBusy = false; canReconnect = true; errorMessage = message(error) }
    }
    func refreshSessions() { Task { await refreshSessionsNow(); await refreshHistoryNow() } }
    func refreshReferenceOverview() {
        guard !referenceLoading else { return }; referenceLoading = true; referenceError = nil; referenceOverview = .null
        Task {
            defer { referenceLoading = false }
            do {
                let info = try await request("api/info")["references"]
                guard info["schema"].string == "tokenclock-reference-overview/v1", info["status"].string == "verified" else { throw Failure(message: "参考资料暂时无法核对，请检查应用版本。") }
                referenceOverview = info
            } catch { referenceOverview = .null; referenceError = message(error) }
        }
    }
    func refreshSessionsNow() async {
        do {
            recentSessions = try await request("api/sessions")["sessions"].array.compactMap { row in
                guard let path = row["path"].string, (path as NSString).isAbsolutePath, !path.contains("\0") else { return nil }
                let url = URL(fileURLWithPath: path)
                return Session(id: path, title: row["title"].string ?? row["name"].string ?? url.lastPathComponent, url: url, model: row["raw_model"].string)
            }
        } catch { errorMessage = message(error) }
    }
    private func refreshConnectionsNow() async {
        do {
            let rows = try await request("api/connections")["profiles"].array
            profiles = [:]; connections = []
            for row in rows {
                if let id = row["id"].string {
                    profiles[id] = row
                    let name = row["name"].string ?? row["model"].string ?? "已保存连接"
                    let url = row["endpoint"].string.flatMap(URL.init(string:))
                    let host = url?.host.map { " · " + $0 + (url?.port.map { ":\($0)" } ?? "") } ?? ""
                    connections.append(Connection(id: id, title: name + host))
                }
            }
        } catch { errorMessage = message(error) }
    }
    private func refreshHistoryNow() async {
        do {
            history = try await request("api/jobs")["jobs"].array.compactMap { row in
                guard let id = row["id"].string else { return nil }
                let p = row["semantic_config"]["provider"]
                let host = p["endpoint"].string.flatMap(URL.init(string:))?.host
                let date = (row["completed_at"].string ?? row["created_at"].string).map(Self.historyDate)
                return History(id: id, title: row["input_name"].string ?? p["model"].string ?? "本地检测", status: row["status"].string ?? "unknown", detail: [date, p["model"].string, host].compactMap { $0 }.joined(separator: " · "))
            }
        } catch { errorMessage = message(error) }
    }
    private static func historyDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: raw) }
        return date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? raw
    }
    func selectSession(id: String) { if let row = recentSessions.first(where: { $0.id == id }) { prefillSource(row.url, expectedModel: row.model) } }
    func prefillSource(_ url: URL, expectedModel: String? = nil) {
        guard phase != .running else { errorMessage = "当前检测仍在进行，请先等待或停止。"; return }
        guard url.isFileURL, let path = ModelDetectSessionSource.usablePath(url.path) else {
            sourceURL = nil; selectedSessionID = ""; comparisonModel = ""; currentJobID = nil; phase = .input
            errorMessage = "请选择可读取且不超过64 MiB的普通文件。"; return
        }
        polling?.cancel(); currentJobID = nil
        clearHistoryComparison(); historySelection = UUID()
        resumeID = nil; lineageOrigin = nil; lineageAction = nil; lineageBinding = nil; lineageLimit = nil
        sourceURL = URL(fileURLWithPath: path); selectedSessionID = path; phase = .input; errorMessage = nil
        let expected = expectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        comparisonModel = ["", "unknown", "未知", "—", "-"].contains(expected.lowercased()) ? "" : expected
    }
    func selectConnection(id: String) {
        guard let row = profiles[id] else { selectedConnectionID = ""; configurationChanged(); return }
        restored {
            endpoint = row["endpoint"].string ?? ""; modelID = row["model"].string ?? ""; apiFormat = row["api_format"].string ?? "chat_completions"
            inputPrice = valueText(row["input_usd_per_million"]); outputPrice = valueText(row["output_usd_per_million"])
            apiKey = ""; keyBinding = ""; selectedConnectionID = id; profileBinding = fullIdentity
        }
        configurationChanged()
    }
    func readModelCatalog() {
        Task {
            let original = endpoint
            do {
                let response = try await request("api/model-catalog", body: .object(["endpoint": .string(original)]))
                guard endpoint == original else { return }
                catalog = [:]; models = []
                for row in response["models"].array { if let id = row["id"].string { catalog[id] = row; models.append(id) } }
                if let row = catalog[modelID], row["pricing_available"].bool == true { applyCatalogPrice(row) }
            } catch { errorMessage = message(error) }
        }
    }
    func selectCatalogModel(_ id: String) { modelID = id; if let row = catalog[id] { applyCatalogPrice(row) } }
    private func applyCatalogPrice(_ row: ModelDetectJSON) {
        restored { inputPrice = valueText(row["input_usd_per_million"]); outputPrice = valueText(row["output_usd_per_million"]) }; configurationChanged()
    }
    func saveConnection() {
        Task {
            do {
                guard !apiKey.isEmpty, keyBinding == identity else { throw Failure(message: "请为当前接口填写密钥。") }
                var p = try targetProvider(secrets: true).object
                p["name"] = .string(modelID); p["secret_storage"] = .string("keychain")
                let saved = try await request("api/connections", body: .object(p))
                await refreshConnectionsNow()
                if let id = saved["profile"]["id"].string { selectConnection(id: id) }
            } catch { errorMessage = message(error) }
        }
    }

    private func valueText(_ value: ModelDetectJSON) -> String { value.string ?? value.number.map { String($0) } ?? "" }
    private func dollars(_ value: ModelDetectJSON) -> String { let text = valueText(value); return text.isEmpty ? "待确定" : "$" + text }
    private func reservedDollars(_ value: ModelDetectJSON) -> String {
        guard let amount = Decimal(string: valueText(value), locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else { return "待确定" }
        let rounded = NSDecimalNumber(decimal: amount).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .up, scale: 2, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return "$" + rounded.stringValue
    }
    private func requiredMoney(_ text: String, label: String, positive: Bool = false) throws -> ModelDetectJSON {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 64, value.range(of: #"^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
              let n = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: n).doubleValue.isFinite, n >= 0, n <= 1_000_000, (!positive || n > 0) else { throw Failure(message: "请填写有效的" + label + "。") }
        return .string(NSDecimalNumber(decimal: n).stringValue)
    }
    private func targetProvider(secrets: Bool) throws -> ModelDetectJSON {
        guard !endpoint.isEmpty, !modelID.isEmpty else { throw Failure(message: "请填写接口地址与准确型号。") }
        var p: [String: ModelDetectJSON] = ["endpoint": .string(endpoint), "api_format": .string(apiFormat), "model": .string(modelID),
            "input_usd_per_million": try requiredMoney(inputPrice, label: "输入单价"), "output_usd_per_million": try requiredMoney(outputPrice, label: "输出单价"),
            "max_cost_usd": try requiredMoney(budget, label: "本次预算", positive: true), "reasoning_effort": .string(probeDepth == "l2" && l2Method == "numeric" ? "low" : "high"), "stream": .bool(true), "wall_seconds": .number(900)]
        if !selectedConnectionID.isEmpty && profileBinding == fullIdentity { p["connection_id"] = .string(selectedConnectionID) }
        else if secrets {
            guard hasTargetCredential else { throw Failure(message: "接口已改变或缺少密钥，请重新填写或选择对应连接。") }
            p["api_key"] = .string(apiKey)
        }
        return .object(p)
    }
    private func reviewerProvider(secrets: Bool, shared: Bool) throws -> ModelDetectJSON {
        let sameModel = shared && (judgeModelID.isEmpty || judgeModelID == modelID)
        var p: [String: ModelDetectJSON] = ["model": .string(sameModel ? modelID : judgeModelID),
            "input_usd_per_million": try requiredMoney(sameModel ? inputPrice : judgeInputPrice, label: "解析输入单价"),
            "output_usd_per_million": try requiredMoney(sameModel ? outputPrice : judgeOutputPrice, label: "解析输出单价"),
            "max_cost_usd": try requiredMoney(judgeBudget, label: "解析预算", positive: true), "reasoning_effort": .string("high")]
        guard let limit = Int(judgeOutputLimit), (256...262144).contains(limit) else { throw Failure(message: "解析输出上限无效。") }
        p["max_output_tokens"] = .number(Double(limit))
        if !judgeImageTokens.isEmpty {
            guard let n = Int(judgeImageTokens), (1...1_000_000).contains(n) else { throw Failure(message: "每张图像的计费上界无效。") }
            p["image_tokens_upper_per_image"] = .number(Double(n)); p["image_detail"] = .string("high")
        }
        if !shared {
            guard !judgeEndpoint.isEmpty, !judgeModelID.isEmpty else { throw Failure(message: "请填写解析接口与型号。") }
            p["endpoint"] = .string(judgeEndpoint); p["api_format"] = .string(judgeFormat)
            if secrets { guard hasJudgeCredential else { throw Failure(message: "请为当前解析接口重新填写密钥。") }; p["api_key"] = .string(judgeKey) }
        }
        return .object(p)
    }
    private func resolvedFamily() throws -> String {
        if ["openai", "anthropic"].contains(advancedFamily) { return advancedFamily }
        let known = ["gpt-5.5", "gpt-5.6-sol", "gpt-6-astra", "claude-opus-5", "claude-sonnet-5", "claude-fable-5"]
        let name = modelID.components(separatedBy: "/").last ?? modelID
        let namespace = name.hasPrefix("claude-") ? "anthropic/" : "openai/"
        guard known.contains(name), modelID == name || modelID == namespace + name else { throw Failure(message: "这个型号暂时没有已登记的参考。可以改做任务检查，或在高级设置中手动选择题包，只记录回答。") }
        return name.hasPrefix("claude-") ? "anthropic" : "openai"
    }
    func configuration(secrets: Bool, authorized: Bool) throws -> ModelDetectJSON {
        var c: [String: ModelDetectJSON] = [:]
        let lane = mode == .api ? probeDepth : ["session": "l1", "answers": "l2", "artifact": "l3", "diagnostics": "diagnostics"][filePurpose] ?? "l1"
        c["workflow_mode"] = .string(lane); c["mode"] = .string("local")
        if mode == .api {
            c["transport_mode"] = .string("live"); c["provider"] = try targetProvider(secrets: secrets)
            if authorized { c["allow_live"] = .bool(true) }
            if lane == "l2" {
                c["l2_method"] = .string(l2Method)
                if l2Method != "numeric" {
                c["family"] = .string(try resolvedFamily()); c["repeats"] = .number(2)
                let ids = taskIDs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !ids.isEmpty { c["task_ids"] = .array(ids.map(ModelDetectJSON.string)) }
                }
            }
        } else if lane == "l2" || lane == "l3" { c["transport_mode"] = .string("artifact") }
        if lane == "l2" && mode == .session { c["l2_method"] = .string(l2Method) }
        if lane == "l3" { c["task_id"] = .string(heavyTask) }
        if assessmentEnabled {
            if lane == "l2" && l2Method == "numeric" { throw Failure(message: "数字指纹在本地评分，无需模型辅助解析。") }
            guard lane == "l1" || lane == "l2" || (lane == "l3" && (heavyTask.hasPrefix("H04") || heavyTask == "H03" && mode == .api)) else {
                throw Failure(message: "该任务由本地检查完成，请关闭模型辅助解析。")
            }
            if lane == "l1" {
                guard judgeFormat == "chat_completions" else { throw Failure(message: "会话语义解析当前使用 Chat Completions 接口。") }
                var p = try reviewerProvider(secrets: secrets, shared: false).object; p["enabled"] = .bool(true); c["external"] = .object(p); c["mode"] = .string("external")
            } else {
                let shared = mode == .api && reuseTargetForAssessment
                var a: [String: ModelDetectJSON] = ["enabled": .bool(true), "transport_mode": .string("live"), "connection_source": .string(shared ? "target" : "separate"),
                    "repeats": .number(1), "batch_once": .bool(lane == "l2"), "provider": try reviewerProvider(secrets: secrets, shared: shared)]
                if authorized { a["allow_live"] = .bool(true) }
                c["assessment"] = .object(a)
            }
        }
        if let binding = lineageBinding {
            guard endpoint == binding["endpoint"].string, modelID == binding["model"].string, apiFormat == binding["api_format"].string else { throw Failure(message: "后续检测必须使用原报告对应的接口与型号。") }
            if let limit = lineageLimit, let chosen = Decimal(string: budget), chosen > limit { throw Failure(message: "不能超过原任务剩余预算。") }
        }
        return .object(c)
    }
    private func body(_ config: ModelDetectJSON) -> ModelDetectJSON {
        var value: [String: ModelDetectJSON] = ["semantic_config": config]
        if mode == .session && filePurpose == "session" && !comparisonModel.isEmpty { value["comparison_model"] = .string(comparisonModel) }
        if mode == .session, let sourceURL { value["source_path"] = .string(sourceURL.path); value["input_name"] = .string(sourceURL.lastPathComponent) }
        if let resumeID { value["resume_job_id"] = .string(resumeID) }
        if let lineageOrigin, let lineageAction {
            value["recommendation_origin_job_id"] = .string(lineageOrigin)
            value["recommendation_action_id"] = .string(lineageAction)
        }
        return .object(value)
    }

    func prepare() { Task { await prepareNow() } }
    func prepareNow() async {
        guard canPrepare else { return }; isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let stamp = revision; let config = try configuration(secrets: false, authorized: false)
            let p = try await request("api/preview", body: body(config))
            guard revision == stamp else { throw Failure(message: "配置已经改变，请重新确认。") }
            guard p["valid"].bool == true else { throw Failure(message: p["errors"].array.compactMap(\.string).joined(separator: "\n")) }
            preparedConfiguration = config; preparedResult = p; preparedRevision = stamp; targetConsent = false; judgeConsent = false
            let roles = p["roles"].array
            func description(_ row: ModelDetectJSON) -> String {
                let count = row["max_requests"].number.map { "，最多 \(Int($0)) 次请求" } ?? ""
                return row["sends"].array.compactMap(\.string).joined(separator: "、") + count + "；费用上限 " + dollars(row["budget_usd"])
            }
            let estimate = p["total_upper_usd"].string != nil ? "本方案最多预留 " + reservedDollars(p["total_upper_usd"]) + "，实际用量可能更少。" : "仅在你确认后发送本次内容。"
            preview = Preview(summary: p["local_only"].bool == true ? "仅在本机处理，无模型费用。" : estimate,
                targetSummary: roles.first(where: { $0["role"].string == "target" }).map(description),
                judgeSummary: roles.first(where: { $0["role"].string != "target" }).map(description),
                budgetSummary: (lineageOrigin == nil ? "本次费用上限 " : "原任务剩余预算 ") + dollars(p["total_budget_usd"]), warning: p["warnings"].array.compactMap(\.string).joined(separator: "\n"),
                referenceTitle: p["reference_readiness"]["title"].string, referenceSummary: p["reference_readiness"]["summary"].string,
                followUpReason: p["follow_up"]["reason"].string)
            if p["local_only"].bool == true && roles.isEmpty && !wantsExternal { try await submitPrepared(external: false) }
        } catch { errorMessage = message(error) }
    }
    func confirmStart() { Task { await confirmStartNow() } }
    func confirmStartNow() async {
        guard canStart else { return }; isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await submitPrepared(external: wantsExternal) } catch { errorMessage = message(error) }
    }
    private func submitPrepared(external: Bool) async throws {
        guard preparedRevision == revision, preparedConfiguration != nil else { throw Failure(message: "请重新确认配置与费用。") }
        if external {
            if mode == .api && !targetConsent { throw Failure(message: "请确认待测请求的发送范围。") }
            if assessmentEnabled && !judgeConsent { throw Failure(message: "请确认解析请求的发送范围。") }
        }
        let config = try configuration(secrets: external, authorized: external)
        var payload = body(config).object; payload["allow_external"] = .bool(external)
        if let lineageOrigin, let lineageAction { payload["recommendation_origin_job_id"] = .string(lineageOrigin); payload["recommendation_action_id"] = .string(lineageAction) }
        let route = resumeID.map { "api/jobs/" + $0 + "/resume" } ?? "api/jobs"
        // A lost response may still have created a job. Never reuse the same
        // preview or consent for a second POST after an uncertain submission.
        preview = nil; preparedConfiguration = nil; preparedRevision = nil; preparedResult = nil
        targetConsent = false; judgeConsent = false; submissionUncertain = true
        let job: ModelDetectJSON
        do { job = try await request(route, body: .object(payload)) }
        catch {
            await refreshHistoryNow()
            throw Failure(message: "未能确认提交结果。请先在历史记录中核对是否已创建任务，避免重复提交；再次检测须重新确认费用。")
        }
        guard let id = job["id"].string else { throw Failure(message: "本地服务没有返回有效的任务记录。") }
        submissionUncertain = false; currentJobID = id; lastJob = job; resumeID = nil; phase = .running
        preview = nil; preparedConfiguration = nil; preparedRevision = nil; preparedResult = nil; targetConsent = false; judgeConsent = false
        applyProgress(job); beginPolling(id)
    }
    private func beginPolling(_ id: String) {
        polling?.cancel()
        polling = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.currentJobID == id else { return }
                do {
                    let job = try await self.request("api/jobs/" + id)
                    guard !Task.isCancelled, self.currentJobID == id else { return }
                    failures = 0; self.lastJob = job; self.applyProgress(job)
                    if ["completed", "failed", "cancelled", "interrupted", "action_required"].contains(job["status"].string ?? "") {
                        await self.finish(job); return
                    }
                } catch {
                    failures += 1
                    if failures >= 3 { self.canReconnect = true; self.errorMessage = "暂时无法读取进度；原任务可能仍在运行。请重新连接查看，未启动新的付费请求。"; return }
                }
                do { try await Task.sleep(nanoseconds: self.pollInterval) } catch { return }
            }
        }
    }
    private func applyProgress(_ job: ModelDetectJSON) {
        progressTitle = job["status"].string == "cancelling" ? "正在停止" : "正在检测"
        progressMessage = job["progress"]["message"].string ?? "正在整理本次观察。"
        progressFraction = job["progress"]["fraction"].number
        let totals = job["probe_billing"]["totals"].object.isEmpty ? job["semantic_billing"]["totals"] : job["probe_billing"]["totals"]
        if !totals.object.isEmpty { costSummary = "已报告 " + dollars(totals["reported_actual_cost_usd"]) + " · 估算 " + dollars(totals["estimated_only_cost_usd"]) + " · 待结 " + dollars(totals["pending_reserved_cost_usd"]) }
        else { costSummary = "" }
    }
    private func finish(_ job: ModelDetectJSON) async {
        if job["status"].string == "completed", let id = job["id"].string {
            do { try await loadReport(id); await refreshHistoryNow(); return }
            catch { guard currentJobID == id else { return }; errorMessage = message(error) }
        }
        phase = .result
        presentation = ModelDetectResultPresentation()
        resultSuggestion = ""
        followUps = []; selectedFollowUpID = ""
        modelFields = []; modelFieldCount = 0
        let complete = job["status"].string == "completed"
        if !complete { lastReport = .null }
        brief = Brief(title: complete ? "结果已保存，暂无法显示摘要" : job["status"].string == "cancelled" ? "检测已停止" : "本次检测未完成",
            summary: complete ? "可以保存原始报告查看；原任务不会重新执行。" : "已有记录与费用会保留。", reasons: [],
            caveat: complete ? "重新读取不会再次调用模型。" : "停止不代表模型有问题。再次测试前会确认剩余费用。", primaryActionTitle: complete ? "重新读取结果" : "查看继续方案")
        detailText = jsonText(complete && !lastReport.object.isEmpty ? lastReport : job)
    }
    private func loadReport(_ id: String) async throws {
        let report = try await request("reports/" + id + "/report.json")
        guard currentJobID == id else { return }
        lastReport = report
        let value = report["user_summary"]["brief"]
        guard let title = value["title"].string else { throw Failure(message: "此报告缺少简要结论，可保存原件查看。") }
        lastReport = report; currentJobID = id; phase = .result
        presentation = ModelDetectResultPresentation(report: report)
        let fields = report["model_declarations"]
        modelFieldCount = fields["total"].number.map(Int.init) ?? 0
        modelFields = fields["entries"].array.suffix(12).compactMap { row in
            guard let id = row["record_id"].string, let name = row["model"].string else { return nil }
            let pointer = row["source_pointer"]
            let file = pointer["path"].string.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let line = pointer["line"].number.map { ":\(Int($0))" } ?? ""
            return ModelField(id: id, model: name, scope: row["scope"].string ?? "unknown", owner: row["owner"].string ?? "unknown",
                              location: file + line + " " + (pointer["json_pointer"].string ?? row["field"].string ?? ""))
        }
        resultObjectLabel = lastJob["input_name"].string ?? report["result"]["subject"]["label"].string ?? "本次结果"
        let human = value["display"]
        let action = human["next_action"].object.isEmpty ? value["next_action"] : human["next_action"]
        resultSuggestion = human["suggestion"].string ?? ""
        let recommendation = report["user_summary"]["recommendation"]
        followUps = recommendation["status"].string == "recommended" && action["kind"].string == "recommendation" ? recommendation["actions"].array.compactMap { row in
            guard let id = row["id"].string else { return nil }
            return FollowUp(id: id, title: row["title"].string ?? "补充检查", reason: row["reason"].string ?? "", requestCount: Int(row["request_count"].number ?? 0), reserve: reservedDollars(row["estimated_reserve_usd"]))
        } : []
        selectedFollowUpID = action["id"].string ?? ""
        brief = Brief(title: presentation.title.isEmpty ? title : presentation.title, summary: presentation.summary, reasons: Array(value["reasons"].array.compactMap(\.string).prefix(3)), caveat: human["note"].string ?? value["caveat"].string ?? "", primaryActionTitle: action["kind"].string == "none" ? nil : action["label"].string)
        detailText = jsonText(report)
    }
    private func jsonText(_ value: ModelDetectJSON) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }.map {
            String($0.prefix(200_000)) + ($0.count > 200_000 ? "\n\n（此处显示前200000字符，可导出完整原件。）" : "")
        } ?? ""
    }
    func cancel() { Task { await cancelNow() } }
    func cancelNow() async {
        guard let id = currentJobID, phase == .running else { return }
        do { let job = try await request("api/jobs/" + id + "/cancel", body: .object([:])); lastJob = job; applyProgress(job) }
        catch { errorMessage = message(error) }
    }
    func newDetection() {
        guard phase != .running else { errorMessage = "请先等待或停止当前检测。"; return }
        polling?.cancel(); currentJobID = nil; resumeID = nil; lineageOrigin = nil; lineageAction = nil; lineageBinding = nil; lineageLimit = nil
        phase = .input; brief = nil; detailText = ""; presentation = ModelDetectResultPresentation(); errorMessage = nil; costSummary = ""; resultSuggestion = ""; configurationChanged()
        modelFields = []; modelFieldCount = 0
        followUps = []; selectedFollowUpID = ""; clearHistoryComparison(); historySelection = UUID()
    }
    func showHistory(id: String) {
        guard phase != .running else { errorMessage = "请先等待或停止当前检测。"; return }
        clearHistoryComparison(); let selection = UUID(); historySelection = selection
        Task {
            let stamp = revision
            do { let job = try await request("api/jobs/" + id); guard stamp == revision, historySelection == selection else { return }; currentJobID = id; lastJob = job; submissionUncertain = false; applyProgress(job)
                if ["queued", "running", "cancelling"].contains(job["status"].string ?? "") { phase = .running; beginPolling(id) }
                else { await finish(job) }
            } catch { if historySelection == selection && stamp == revision { errorMessage = message(error) } }
        }
    }
    private func clearHistoryComparison() {
        comparisonSelection = UUID(); historyComparison = .null; selectedHistoryID = ""; comparingHistory = false
    }
    func compareHistory(with id: String) {
        guard let current = currentJobID, phase == .result, id != current, !comparingHistory,
              comparisonCandidates.contains(where: { $0.id == id }) else { return }
        let selection = UUID(); comparisonSelection = selection; selectedHistoryID = id
        historyComparison = .null; comparingHistory = true
        Task {
            defer { if comparisonSelection == selection { comparingHistory = false } }
            do {
                let value = try await request("api/history/compare", body: .object(["left_job_id":.string(id),"right_job_id":.string(current)]))
                guard currentJobID == current, comparisonSelection == selection, phase == .result else { return }
                historyComparison = value
            } catch { if currentJobID == current && comparisonSelection == selection { errorMessage = message(error) } }
        }
    }
    func retry() {
        if let id = currentJobID, lastJob["status"].string == "completed" {
            Task { do { try await loadReport(id); errorMessage = nil } catch { errorMessage = message(error) } }
            return
        }
        guard let id = currentJobID, ["failed", "cancelled", "interrupted", "action_required"].contains(lastJob["status"].string ?? "") else { return }
        let config = lastJob["semantic_config"]
        restoreConfiguration(config)
        resumeID = id; phase = .input; configurationChanged(); errorMessage = "请重新确认连接和费用。原调用费用不会清零。"
    }
    private func restoreConfiguration(_ config: ModelDetectJSON) {
        restored {
            let p = config["provider"]; let lane = config["workflow_mode"].string ?? "l1"
            mode = config["transport_mode"].string == "live" ? .api : .session
            filePurpose = ["l1":"session", "l2":"answers", "l3":"artifact", "diagnostics":"diagnostics"][lane] ?? "session"
            probeDepth = lane == "l3" ? "l3" : "l2"; heavyTask = config["task_id"].string ?? "H04"; advancedFamily = config["family"].string ?? "auto"
            taskIDs = config["task_ids"].array.compactMap(\.string).joined(separator: ","); l2Method = config["l2_method"].string ?? "behavior"
            if !p.object.isEmpty { endpoint = p["endpoint"].string ?? ""; modelID = p["model"].string ?? ""; apiFormat = p["api_format"].string ?? "chat_completions"; inputPrice = valueText(p["input_usd_per_million"]); outputPrice = valueText(p["output_usd_per_million"]); budget = valueText(p["max_cost_usd"]) }
            let a = config["assessment"]; let j = lane == "l1" ? config["external"] : a["provider"]
            assessmentEnabled = lane == "l1" ? config["external"]["enabled"].bool == true : a["enabled"].bool == true
            reuseTargetForAssessment = a["connection_source"].string == "target"
            judgeEndpoint = j["endpoint"].string ?? ""; judgeModelID = j["model"].string ?? ""; judgeFormat = j["api_format"].string ?? "chat_completions"
            judgeInputPrice = valueText(j["input_usd_per_million"]); judgeOutputPrice = valueText(j["output_usd_per_million"]); judgeBudget = valueText(j["max_cost_usd"])
            judgeOutputLimit = j["max_output_tokens"].number.map { String(Int($0)) } ?? "24576"; judgeImageTokens = j["image_tokens_upper_per_image"].number.map { String(Int($0)) } ?? ""
            apiKey = ""; judgeKey = ""; selectedConnectionID = ""; keyBinding = ""; judgeKeyBinding = ""
        }
    }
    func performPrimaryAction() {
        if lastReport["user_summary"]["brief"]["title"].string == nil { retry(); return }
        let next = lastReport["user_summary"]["brief"]["next_action"]
        if next["kind"].string == "configure" {
            let suggested = comparisonModel.isEmpty ? lastReport["model_declarations"]["latest_main_request_model"].string ?? "" : comparisonModel
            newDetection(); mode = .api; probeDepth = "l2"
            if modelID.isEmpty { modelID = suggested }
            return
        }
        guard next["kind"].string == "recommendation", let id = selectedFollowUp?.id ?? next["id"].string,
              let action = lastReport["user_summary"]["recommendation"]["actions"].array.first(where: { $0["id"].string == id }), let parent = currentJobID else { return }
        let rec = lastReport["user_summary"]["recommendation"]; let binding = rec["target_binding"]
        guard rec["status"].string == "recommended", !binding.object.isEmpty else { return }
        guard let remaining = rec["remaining_budget_usd"].string, let limit = Decimal(string: remaining), limit > 0 else { errorMessage = "原任务已无可用预算。"; return }
        if endpoint != binding["endpoint"].string || modelID != binding["model"].string || apiFormat != binding["api_format"].string {
            restoreConfiguration(lastJob["semantic_config"])
            restored { endpoint = binding["endpoint"].string ?? ""; modelID = binding["model"].string ?? ""; apiFormat = binding["api_format"].string ?? "responses"
                inputPrice = valueText(lastJob["semantic_config"]["provider"]["input_usd_per_million"]); outputPrice = valueText(lastJob["semantic_config"]["provider"]["output_usd_per_million"])
            }
            let matching = profiles.filter { _, p in p["endpoint"].string == endpoint && p["model"].string == modelID && p["api_format"].string == apiFormat }
            if matching.count == 1, let id = matching.keys.first { selectConnection(id: id) }
        }
        let patch = action["configuration_patch"]
        restored { mode = .api; probeDepth = patch["workflow_mode"].string ?? "l2"; l2Method = patch["l2_method"].string ?? "behavior"; heavyTask = patch["task_id"].string ?? "H04"; advancedFamily = patch["family"].string ?? "auto"; taskIDs = patch["task_ids"].array.compactMap(\.string).joined(separator: ","); budget = remaining; assessmentEnabled = false }
        lineageOrigin = parent; lineageAction = id; lineageBinding = binding; lineageLimit = limit
        resumeID = nil; phase = .input; errorMessage = nil; configurationChanged()
        Task { await prepareNow() }
    }
    func export(kind: String, destination: URL) {
        guard let id = currentJobID, ["summary.html","report.json","report.html","observation.json","evidence.zip"].contains(kind), destination.isFileURL else { return }
        if kind == "summary.html" {
            guard let brief else { return }
            let html = ModelDetectReadableReport.render(brief: brief, presentation: presentation, target: resultObjectLabel, suggestion: resultSuggestion, cost: costSummary, comparison: historyComparison)
            do { try Data(html.utf8).write(to: destination, options: .atomic) }
            catch { errorMessage = "无法保存报告，请检查目标位置是否可写。" }
            return
        }
        Task {
            do { guard let service else { return }; let bytes = try await service.download("reports/" + id + "/" + kind); try bytes.write(to: destination, options: .atomic) }
            catch { errorMessage = "无法保存此文件，请检查报告是否完整及目标位置是否可写。" }
        }
    }
}
#endif
