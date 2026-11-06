#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct ModelDetectNativeView: View {
    @ObservedObject var model: ModelDetectNativeModel
    var onChooseFile: () -> Void
    var onExport: (String) -> Void

    @State private var advancedExpanded = false
    @State private var detailsExpanded = false
    @State private var historyExpanded = false
    @State private var connectionExpanded = false
    @State private var modelFieldsExpanded = false
    @State private var comparisonExpanded = false
    @State private var referenceExpanded = false

    private typealias T = ModelDetectNativeText

    private func edit<Value>(_ path: ReferenceWritableKeyPath<ModelDetectNativeModel, Value>) -> Binding<Value> {
        Binding(get: { model[keyPath: path] }, set: { value in
            model[keyPath: path] = value
            if !assessmentAvailable && model.assessmentEnabled { model.assessmentEnabled = false }
            if model.mode == .session && model.filePurpose == "session" && model.judgeFormat != "chat_completions" {
                model.judgeFormat = "chat_completions"
            }
            model.configurationChanged()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.phase {
                    case .input:
                        inputContent
                            .padding(18)
                            .background(RoundedRectangle(cornerRadius: 12).fill(ModelDetectPalette.card))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ModelDetectPalette.border))
                    case .running: progressContent
                    case .result: resultContent
                    }
                    if let error = model.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("model-detect-error")
                        if model.canReconnect && !model.isBusy {
                            Button(T.text("重新连接", "重新連線", "Reconnect")) { model.connect() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("model-detect-reconnect")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .id("model-detect-scroll-top")
              }
              .onChange(of: model.phase) { _ in proxy.scrollTo("model-detect-scroll-top", anchor: .top) }
              .onChange(of: model.currentJobID) { _ in proxy.scrollTo("model-detect-scroll-top", anchor: .top) }
              .onChange(of: model.brief?.title) { _ in proxy.scrollTo("model-detect-scroll-top", anchor: .top) }
            }
        }
        .environment(\.locale, Locale(identifier:L10n.shared.language.rawValue))
        .frame(minWidth: 720, idealWidth: 740, maxWidth: .infinity,
               minHeight: 390, idealHeight: model.phase == .result ? 690 : 480, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(ModelDetectPalette.accent)
        .onChange(of: model.phase) { _ in
            detailsExpanded = false
            modelFieldsExpanded = false
            comparisonExpanded = false
            if model.phase == .input { advancedExpanded = false; historyExpanded = false; connectionExpanded = false }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.shared.tr("menu.sessionAssessment"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.phase == .result {
                Button { onExport("summary.html") } label: {
                    Label(T.text("保存报告", "儲存報告", "Save report"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isBusy || model.comparingHistory)
                .accessibilityIdentifier("model-detect-save-result")
                Button(T.text("重新检测", "重新檢測", "New assessment")) {
                    advancedExpanded = false; detailsExpanded = false; model.newDetection()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("model-detect-new")
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(T.text("正在准备", "正在準備", "Preparing"))
            }
        }
    }

    private var headerSubtitle: String {
        switch model.phase {
        case .input: return T.text("选对象 → 开始检测 → 查看结论", "選物件 → 開始檢測 → 查看結論", "Choose a target → Start → Review the result")
        case .running: return T.text("本次检测正在进行。", "本次檢測正在進行。", "Your assessment is in progress.")
        case .result: return model.resultObjectLabel.isEmpty
            ? T.text("本次结果", "本次結果", "Assessment result") : model.resultObjectLabel
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(T.text("检测内容", "檢測內容", "Assess"), selection: edit(\.mode)) {
                Text(T.text("检查会话", "檢查會話", "Check a session")).tag(ModelDetectNativeModel.Mode.session)
                Text(T.text("检查 API", "檢查 API", "Check an API" )).tag(ModelDetectNativeModel.Mode.api)
                Text(T.text("本机 Codex", "本機 Codex", "Local Codex")).tag(ModelDetectNativeModel.Mode.codex)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 420)
            .accessibilityIdentifier("model-detect-mode")
            .onChange(of: model.mode) { _, value in
                if value == .codex { model.assessmentEnabled = false; model.refreshLocalCodex() }
            }

            if model.mode == .session { sessionFields } else if model.mode == .codex { localCodexFields } else { apiFields }
            if model.needsReferenceChoice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T.text("这个型号暂时没有参考", "這個型號暫時沒有參考", "No reference for this model yet")).font(.callout.weight(.semibold))
                    Text(T.text("可以检查任务是否做好，但暂时不能判断它更像哪个型号。", "可以檢查任務是否做好，但暫時不能判斷它更像哪個型號。", "Task completion can be checked; model resemblance cannot yet be compared.")).font(.caption).foregroundColor(.secondary)
                    Button(T.text("查看任务检查方案", "查看任務檢查方案", "Review a task check")) {
                        model.probeDepth = "l3"; model.heavyTask = "H01"; model.assessmentEnabled = false
                        model.prepare()
                    }.buttonStyle(.bordered)
                }.accessibilityIdentifier("model-detect-reference-missing")
            }
            Label(model.planSummary, systemImage: model.mode == .session ? "desktopcomputer" : "checklist")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .accessibilityIdentifier("model-detect-plan-summary")

            if model.mode != .codex { DisclosureGroup(isExpanded: $advancedExpanded) {
                advancedContent.padding(.top, 12)
            } label: {
                Text(T.text("高级设置", "進階設定", "Advanced settings")).font(.callout)
            }
            .accessibilityIdentifier("model-detect-advanced")
            }

            if let preview = model.preview {
                confirmation(preview)
            } else {
                HStack(spacing: 12) {
                    Button(T.text("开始检测", "開始檢測", "Start assessment")) {
                        model.prepare()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPrepare || model.isBusy)
                    .accessibilityIdentifier("model-detect-prepare")
                    Text(model.mode == .session && !model.assessmentEnabled
                         ? T.text("仅在本机处理，无模型费用。", "僅在本機處理，無模型費用。", "Local processing, without model charges.")
                         : model.mode == .codex ? T.text("点击即使用此账户额度执行上述测试。", "點擊即使用此帳戶額度執行上述測試。", "Start uses this account's allowance for the tests shown above.")
                         : T.text("确认范围和预算后才发送请求。", "確認範圍與預算後才傳送請求。", "Requests require confirmation of scope and budget."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        }
    }

    private var localCodexFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.localCodex["account_label"].string ?? T.text("读取本机登录状态", "讀取本機登入狀態", "Read local sign-in"), systemImage: "desktopcomputer")
                Spacer()
                if model.localCodexLoading { ProgressView().controlSize(.small) }
                Button(T.text("刷新", "重新整理", "Refresh")) { model.refreshLocalCodex() }
                    .disabled(model.localCodexLoading || model.isBusy)
                    .accessibilityIdentifier("model-detect-codex-refresh")
            }
            Picker(T.text("待测型号", "待測型號", "Model to test"), selection: $model.localCodexModel) {
                Text(T.text("选择型号", "選擇型號", "Choose a model")).tag("")
                ForEach(model.localCodex["models"].array.compactMap { $0["id"].string }, id: \.self) { name in Text(name).tag(name) }
            }.accessibilityIdentifier("model-detect-codex-model")
            Text(T.text("复用 Codex 已有登录，无需填写 Key。每份回答使用新会话，不带入原聊天。", "重用 Codex 既有登入，無需填寫 Key。每份回答使用新會話，不帶入原聊天。", "Uses your existing Codex sign-in. Each answer starts a fresh thread, without your chat history."))
                .font(.caption).foregroundColor(.secondary)
            DisclosureGroup(T.text("测试方式与范围", "測試方式與範圍", "Test method and scope")) {
                Text((model.localCodex["provider"].string ?? "Codex") + " · " + (model.localCodex["home"].string ?? ""))
                    .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Picker(T.text("题包", "題組", "Questions"), selection: $model.localCodexMethod) {
                    Text(T.text("数字指纹 · 3 次回答", "數字指紋 · 3 次回答", "Numeric fingerprint · 3 answers")).tag("numeric")
                    Text(T.text("轻量行为 · 6 次回答", "輕量行為 · 6 次回答", "Short behavior probes · 6 answers")).tag("behavior")
                }
                Text(T.text("最多运行 15 分钟；不会自动重发题目。使用订阅或 API 额度，美元费用未知。可能保留 Codex 自带及个人指令，目前保存观察，不直接确认型号或给出身份概率。", "最多執行 15 分鐘；不會自動重發題目。使用訂閱或 API 額度，美元費用未知。可能保留 Codex 自帶及個人指令，目前儲存觀察，不直接確認型號或給出身分機率。", "Up to 15 minutes, without resending questions. Uses subscription or API allowance; dollar cost is unknown. Codex and personal instructions may remain, so this path records observations without confirming identity or assigning an identity probability."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }.disabled(model.isBusy)
    }

    private var sessionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sourceURL?.lastPathComponent ?? T.text("尚未选择文件", "尚未選擇檔案", "No file selected"))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.sourceURL?.path ?? "")
                    Text(T.text("会话日志或已有作品，最多 64 MiB。", "會話日誌或既有作品，最多 64 MiB。", "Session log or existing artifact, up to 64 MiB."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(T.text("选择文件…", "選擇檔案…", "Choose file…"), action: onChooseFile)
                    .accessibilityIdentifier("model-detect-choose-file")
            }
            if !model.recentSessions.isEmpty {
                HStack {
                    Picker(T.text("最近会话", "最近會話", "Recent session"), selection: Binding(
                        get: { model.selectedSessionID }, set: { model.selectSession(id: $0) }
                    )) {
                        Text(T.text("选择会话", "選擇會話", "Choose a session")).tag("")
                        ForEach(recentChoices) { session in Text(session.title).tag(session.id) }
                    }
                    .accessibilityIdentifier("model-detect-recent-session")
                    Button { model.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                        .help(T.text("刷新", "重新整理", "Refresh"))
                        .disabled(model.isBusy)
                }
            }
            if model.filePurpose == "session" {
                if model.isCodexSession {
                    Button(T.text("用本机 Codex 新建测试", "用本機 Codex 新建測試", "Start a fresh test with local Codex")) { model.useLocalCodex() }
                        .accessibilityIdentifier("model-detect-from-codex-session")
                }
                labeled(T.text("比较型号（可选）", "比較型號（可選）", "Expected model (optional)")) {
                    TextField("gpt-6-astra", text: edit(\.comparisonModel))
                        .accessibilityIdentifier("model-detect-comparison-model")
                }
                Text(T.text("会话列表可能预填此项，请核对精确型号；日志原有声明保持不变。", "會話清單可能預填此項，請核對精確型號；日誌原有聲明保持不變。", "This may be prefilled from the session list. Check the exact model; original declarations are preserved."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var recentChoices: [ModelDetectNativeModel.Session] {
        var choices = Array(model.recentSessions.prefix(12))
        if !model.selectedSessionID.isEmpty, !choices.contains(where: { $0.id == model.selectedSessionID }),
           let selected = model.recentSessions.first(where: { $0.id == model.selectedSessionID }) {
            choices.append(selected)
        }
        return choices
    }

    private var apiFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.connections.isEmpty {
                Picker(T.text("连接", "連線", "Connection"), selection: Binding(
                    get: { model.selectedConnectionID }, set: { model.selectConnection(id: $0) }
                )) {
                    Text(T.text("手动填写", "手動填寫", "Enter manually")).tag("")
                    ForEach(model.connections) { connection in Text(connection.title).tag(connection.id) }
                }
                .accessibilityIdentifier("model-detect-connection")
            }
            if model.selectedConnectionID.isEmpty {
                endpointFields
            } else {
                DisclosureGroup(isExpanded: $connectionExpanded) {
                    endpointFields.padding(.top, 8)
                } label: {
                    Text(T.text("连接信息", "連線資訊", "Connection details"))
                }
            }
            labeled(T.text("任务预算（美元）", "任務預算（美元）", "Task budget (USD)")) {
                TextField("1.00", text: edit(\.budget))
                    .frame(maxWidth: 160)
                    .accessibilityIdentifier("model-detect-budget")
            }
            if model.selectedConnectionID.isEmpty {
                connectionOptions
            } else {
                Text(T.text("已使用这条连接保存的协议与单价。", "已使用這條連線儲存的協定與單價。", "Using this connection's saved protocol and prices."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var connectionOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            protocolPicker(selection: edit(\.apiFormat))
            HStack {
                Button(T.text("读取型号与报价", "讀取型號與報價", "Read models and pricing")) { model.readModelCatalog() }
                    .accessibilityIdentifier("model-detect-read-catalog")
                if !model.models.isEmpty {
                    Picker(T.text("选择型号", "選擇型號", "Select model"), selection: Binding(get: { model.modelID }, set: { model.selectCatalogModel($0) })) {
                        if !model.models.contains(model.modelID) { Text(model.modelID.isEmpty ? "—" : model.modelID).tag(model.modelID) }
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }.disabled(model.isBusy)
            prices(input: edit(\.inputPrice), output: edit(\.outputPrice))
            Text(T.text("首次填写单价后可保存连接；后续检测直接复用。", "首次填寫單價後可儲存連線；後續檢測直接重用。", "Save this connection after entering prices to reuse it next time."))
                .font(.caption).foregroundColor(.secondary)
            Button(T.text("保存连接到钥匙串", "儲存連線至鑰匙圈", "Save connection to Keychain")) { model.saveConnection() }
                .disabled(model.isBusy)
        }
        .font(.callout).textFieldStyle(.roundedBorder).controlSize(.small)
    }

    private var endpointFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            labeled(T.text("API 地址", "API 位址", "API URL")) {
                TextField("https://…", text: edit(\.endpoint))
                    .accessibilityIdentifier("model-detect-endpoint")
            }
            labeled(T.text("型号 ID", "型號 ID", "Model ID")) {
                TextField(T.text("接口支持的精确型号", "介面支援的精確型號", "Exact model ID"), text: edit(\.modelID))
                    .accessibilityIdentifier("model-detect-model")
            }
            labeled(T.text("API 密钥", "API 金鑰", "API key")) {
                SecureField(T.text("本次密钥或保存的连接", "本次金鑰或儲存的連線", "Current key or saved connection"), text: edit(\.apiKey))
                    .accessibilityIdentifier("model-detect-key")
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.mode == .session {
                Picker(T.text("已有内容类型", "既有內容類型", "Content type"), selection: edit(\.filePurpose)) {
                    Text(T.text("会话记录", "會話記錄", "Session log")).tag("session")
                    Text(T.text("短题回答包", "短題回答包", "Collected short answers")).tag("answers")
                    Text(T.text("已有作品", "既有作品", "Existing artifact")).tag("artifact")
                    Text(T.text("服务记录", "服務記錄", "Service records")).tag("diagnostics")
                }
            } else {
                Picker(T.text("检测方案", "檢測方案", "Assessment plan"), selection: edit(\.probeDepth)) {
                    Text(T.text("快速检测（默认）", "快速檢測（預設）", "Quick check (default)")).tag("l2")
                    Text(T.text("深入检测：交付任务", "深入檢測：交付任務", "Deeper check: delivery task")).tag("l3")
                }
                .accessibilityIdentifier("model-detect-layer")
                if !model.selectedConnectionID.isEmpty { connectionOptions }
            }
            if (model.mode == .api && model.probeDepth == "l3") || (model.mode == .session && model.filePurpose == "artifact") {
                Picker(T.text("任务类型", "任務類型", "Task"), selection: edit(\.heavyTask)) {
                    Text(T.text("费用结算程序", "費用結算程式", "Expense settlement program")).tag("H01")
                    Text(T.text("多步交互网页", "多步互動網頁", "Multi-step interactive page")).tag("H02")
                    Text(T.text("构建与工具过程", "建置與工具過程", "Build and tool process")).tag("H03")
                    Text(T.text("SVG 空间关系", "SVG 空間關係", "SVG spatial relationships")).tag("H04")
                    Text(T.text("ASCII 多帧动作", "ASCII 多幀動作", "ASCII animation frames")).tag("H04:ascii")
                }
            }
            if model.mode == .api && model.probeDepth == "l2" || model.mode == .session && model.filePurpose == "answers" {
                Picker(T.text("轻量检测方法", "輕量檢測方法", "Lightweight method"), selection: edit(\.l2Method)) {
                    Text(T.text("数字指纹（默认）", "數字指紋（預設）", "Numeric fingerprint (default)")).tag("numeric")
                    Text(T.text("多题行为对照", "多題行為對照", "Behavior comparison")).tag("behavior")
                }.accessibilityIdentifier("model-detect-l2-method")
                if model.l2Method != "numeric" {
                Picker(T.text("参考家族", "參考家族", "Reference family"), selection: edit(\.advancedFamily)) {
                    Text(T.text("按明确型号匹配", "按明確型號匹配", "Match the declared model")).tag("auto")
                    Text("OpenAI").tag("openai")
                    Text("Claude").tag("anthropic")
                }
                labeled(T.text("指定题目（可选）", "指定題目（可選）", "Questions (optional)")) {
                    TextField("O07:A, C06:A", text: edit(\.taskIDs))
                }
                } else {
                    Text(T.text("三份回答，在本机与外部参考库比较。", "三份回答，在本機與外部參考庫比較。", "Three answers, compared locally against the external reference bank.")).font(.caption).foregroundColor(.secondary)
                }
            }
            if assessmentAvailable {
                Divider()
                Toggle(T.text("使用模型补充解析", "使用模型補充解析", "Use model-assisted interpretation"), isOn: edit(\.assessmentEnabled))
                    .accessibilityIdentifier("model-detect-assessment-enabled")
                if model.assessmentEnabled { assessmentFields }
            }
            DisclosureGroup(isExpanded: $historyExpanded) {
                historyContent.padding(.top, 8)
            } label: { Text(T.text("历史结果", "歷史結果", "Previous results")) }
            DisclosureGroup(isExpanded: $referenceExpanded) {
                referenceContent.padding(.top, 8)
            } label: { Text(T.text("参考资料与验证进度", "參考資料與驗證進度", "References and validation")) }
            .onChange(of: referenceExpanded) { open in if open { model.refreshReferenceOverview() } }
            .accessibilityIdentifier("model-detect-reference-overview")
        }
        .font(.callout)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    private var referenceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.referenceLoading { ProgressView().controlSize(.small) }
            if let error = model.referenceError { Text(error).font(.caption).foregroundColor(.secondary) }
            if let title = model.referenceOverview["title"].string {
                Text(title).font(.callout.weight(.semibold))
                Text("\(model.referenceOverview["models"].array.count) 个型号 · \(Int(model.referenceOverview["original_behavior_answers"].number ?? 0)) 份原始短题回答").font(.caption)
                Text(model.referenceOverview["summary"].string ?? "").font(.caption).foregroundColor(.secondary)
                Text("校验日期：" + (model.referenceOverview["verified_on"].string ?? "—")).font(.caption).foregroundColor(.secondary)
                if let title = model.referenceOverview["external_numeric"]["title"].string {
                    Divider()
                    Text(title).font(.callout.weight(.semibold))
                    Text("\(Int(model.referenceOverview["external_numeric"]["models"].number ?? 0)) 个外部参考型号 · 本机评分").font(.caption)
                    Text(model.referenceOverview["external_numeric"]["limitation"].string ?? "").font(.caption).foregroundColor(.secondary)
                }
                Divider()
                ForEach(Array(model.referenceOverview["candidate_summary"].array.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text((row["title"].string ?? "") + " · " + (row["status"].string ?? "")).font(.caption.weight(.medium))
                        Text(row["reason"].string ?? "").font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(model.referenceOverview["note"].string ?? "").font(.caption).foregroundColor(.secondary)
                DisclosureGroup(T.text("版本详情", "版本詳情", "Version details")) {
                    Text(model.referenceOverview["release_id"].string ?? "").font(.caption.monospaced())
                    Text(model.referenceOverview["models"].array.compactMap(\.string).joined(separator: " · ")).font(.caption)
                    Text(model.referenceOverview["update_policy"].string ?? "").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private var assessmentAvailable: Bool {
        if model.probeDepth == "l2" && model.l2Method == "numeric" && (model.mode == .api || model.filePurpose == "answers") { return false }
        if model.mode == .api { return model.probeDepth == "l2" || model.heavyTask == "H03" || model.heavyTask.hasPrefix("H04") }
        return model.filePurpose == "session" || model.filePurpose == "answers" || (model.filePurpose == "artifact" && model.heavyTask.hasPrefix("H04"))
    }

    private var assessmentFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if (model.mode == .api && model.probeDepth == "l3" || model.mode == .session && model.filePurpose == "artifact") && model.heavyTask.hasPrefix("H04") {
                Text(T.text("视觉解析包含对象与动作关系的语义判断，不只是格式检查。", "視覺解析包含物件與動作關係的語義判斷，不只是格式檢查。", "Visual interpretation includes semantic judgments about objects and actions, beyond format checks."))
                    .font(.caption).foregroundColor(.secondary)
            }
            if model.mode == .api {
                Toggle(T.text("复用待测 API", "重用待測 API", "Reuse the target API"), isOn: edit(\.reuseTargetForAssessment))
                Text(T.text("解析费用另设上限，结果不反馈给待测过程。", "解析費用另設上限，結果不回饋至待測過程。", "Interpretation has its own budget and is not fed back to the target."))
                    .font(.caption).foregroundColor(.secondary)
            }
            if model.mode == .session || !model.reuseTargetForAssessment {
                labeled(T.text("解析接口", "解析介面", "Interpreter API")) { TextField("https://…", text: edit(\.judgeEndpoint)) }
                labeled(T.text("解析密钥", "解析金鑰", "Interpreter key")) { SecureField("", text: edit(\.judgeKey)) }
                if model.mode == .api || model.filePurpose != "session" { protocolPicker(selection: edit(\.judgeFormat)) }
                else { Text("Chat Completions").font(.caption).foregroundColor(.secondary) }
            }
            labeled(T.text("解析型号", "解析型號", "Interpreter model")) { TextField("", text: edit(\.judgeModelID)) }
            prices(input: edit(\.judgeInputPrice), output: edit(\.judgeOutputPrice))
            labeled(T.text("解析预算（美元）", "解析預算（美元）", "Interpretation budget (USD)")) {
                TextField("", text: edit(\.judgeBudget)).frame(maxWidth: 160)
            }
            DisclosureGroup(T.text("解析限额", "解析限額", "Interpretation limits")) {
                VStack(alignment: .leading, spacing: 9) {
                    labeled(T.text("输出 token 上限", "輸出 token 上限", "Output token limit")) {
                        TextField("24576", text: edit(\.judgeOutputLimit))
                    }
                    if model.heavyTask.hasPrefix("H04") && (model.probeDepth == "l3" && model.mode == .api || model.filePurpose == "artifact" && model.mode == .session) {
                        labeled(T.text("每张图像计量上限", "每張影像計量上限", "Tokens per image")) {
                            TextField(T.text("未登记型号需填写", "未登記型號需填寫", "Required for unregistered models"), text: edit(\.judgeImageTokens))
                        }
                        Text(T.text("填写渠道规定的最大计费 token，不确定时不发送图像。", "填寫渠道規定的最大計費 token，不確定時不傳送影像。", "Use the provider's maximum image token charge. Images are not sent without an adequate bound."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.top, 8)
            }
        }
        .accessibilityIdentifier("model-detect-assessment-fields")
    }

    private func confirmation(_ preview: ModelDetectNativeModel.Preview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(T.text("确认本次检测", "確認本次檢測", "Confirm this assessment")).font(.headline)
                if model.mode == .api {
                    Text(model.targetDescription).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if let title = preview.referenceTitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(title, systemImage: "books.vertical").font(.callout.weight(.semibold))
                        Text(preview.referenceSummary ?? "").font(.caption).foregroundColor(.secondary)
                    }.accessibilityIdentifier("model-detect-reference-readiness")
                }
                if let reason = preview.followUpReason {
                    Text(reason).font(.callout).accessibilityIdentifier("model-detect-followup-purpose")
                }
                Text(preview.budgetSummary).font(.system(.body, design: .rounded).weight(.semibold))
                if !preview.summary.isEmpty { Text(preview.summary).font(.callout).foregroundColor(.secondary) }
                if let target = preview.targetSummary, !target.isEmpty {
                    Text(target).font(.callout)
                        .accessibilityIdentifier("model-detect-target-consent")
                }
                if let judge = preview.judgeSummary, !judge.isEmpty {
                    Text(judge).font(.callout)
                        .accessibilityIdentifier("model-detect-judge-consent")
                }
                if let warning = preview.warning, !warning.isEmpty { Text(warning).font(.caption).foregroundColor(.secondary) }
                if let hint = model.credentialHint { Text(hint).font(.caption).foregroundColor(.secondary) }
                Text(T.text("点击下方按钮，即同意按以上范围发送内容并使用所列预算。", "點擊下方按鈕，即同意按以上範圍傳送內容並使用所列預算。", "Confirm to send the listed content within the displayed budgets."))
                    .font(.caption).foregroundColor(.secondary)
                Button(T.text("确认预算并开始", "確認預算並開始", "Confirm budget and start")) { model.confirmReviewedStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirmReviewed || model.isBusy)
                    .accessibilityIdentifier("model-detect-confirm")
                if model.canReturnToResult {
                    Button(T.text("返回原结果", "返回原結果", "Back to the result")) { model.returnToResult() }
                        .buttonStyle(.bordered).accessibilityIdentifier("model-detect-back-to-result")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("model-detect-preview")
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.progressTitle.isEmpty ? T.text("正在检测", "正在檢測", "Assessing") : model.progressTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            if let value = model.progressFraction, value.isFinite {
                ProgressView(value: min(1, max(0, value)))
            } else { ProgressView().progressViewStyle(.linear) }
            Text(model.progressMessage).font(.callout).foregroundColor(.secondary)
            if !model.costSummary.isEmpty { Text(model.costSummary).font(.caption).foregroundColor(.secondary) }
            Button(T.text("停止检测", "停止檢測", "Stop assessment")) { model.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("model-detect-cancel")
        }
        .padding(.vertical, 22)
        .accessibilityIdentifier("model-detect-progress")
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let brief = model.brief {
              VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: model.presentation.tone == .issue ? "exclamationmark.circle.fill" : model.presentation.tone == .aligned ? "checkmark.circle.fill" : "text.magnifyingglass")
                    Text(T.text("本次结论", "本次結論", "Assessment conclusion"))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ModelDetectPalette.color(model.presentation.tone))
                Text(brief.title).font(.system(size: 22, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("model-detect-result-title")
                Text(brief.summary).font(.system(size: 12)).foregroundColor(.secondary).textSelection(.enabled)
                if !brief.caveat.isEmpty {
                    Text(brief.caveat).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(18)
              .background(RoundedRectangle(cornerRadius: 12).fill(ModelDetectPalette.card))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(ModelDetectPalette.color(model.presentation.tone).opacity(0.22)))
            } else {
                Text(T.text("暂时无法读取结果", "暫時無法讀取結果", "The result is unavailable"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Button(T.text("重试", "重試", "Retry")) { model.retry() }
            }
            ModelDetectRadarView(presentation: model.presentation)
                .id(model.currentJobID)
            if !model.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T.text("建议下一步", "建議下一步", "Suggested next step")).font(.callout.weight(.semibold))
                    if model.followUps.count > 1 {
                        Picker(T.text("补测方案", "補測方案", "Follow-up"), selection: $model.selectedFollowUpID) {
                            ForEach(model.followUps) { row in Text(row.title).tag(row.id) }
                        }.accessibilityIdentifier("model-detect-followup-choice")
                    } else if let row = model.selectedFollowUp { Text(row.title).font(.callout) }
                    if let row = model.selectedFollowUp {
                        Text(row.reason).font(.caption).foregroundColor(.secondary)
                        HStack {
                            Text("\(row.requestCount) 次请求 · 最多预留 \(row.reserve)").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button(T.text("查看补测方案", "查看補測方案", "Review follow-up")) { model.performPrimaryAction() }
                                .buttonStyle(.bordered).disabled(model.isBusy)
                                .accessibilityIdentifier("model-detect-primary-action")
                        }
                    }
                }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(ModelDetectPalette.card))
            } else if !model.resultSuggestion.isEmpty || model.brief?.primaryActionTitle != nil {
                HStack(spacing: 12) {
                    Text(model.resultSuggestion).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    if let title = model.brief?.primaryActionTitle, !title.isEmpty {
                        Button(title) { model.performPrimaryAction() }
                            .buttonStyle(.bordered).disabled(model.isBusy)
                            .accessibilityIdentifier("model-detect-primary-action")
                    }
                }
            }
            if model.canCompareHistory && !model.comparisonCandidates.isEmpty {
                DisclosureGroup(isExpanded: $comparisonExpanded) {
                    historyComparisonContent.padding(.top, 10)
                } label: { Text(T.text("与历史结果对比", "與歷史結果對比", "Compare with history")).font(.callout) }
                .accessibilityIdentifier("model-detect-history-comparison")
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if let brief = model.brief {
                        ForEach(Array(brief.reasons.enumerated()), id: \.offset) { _, reason in
                            Text(reason).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ModelDetectEvidenceMatrixView(presentation: model.presentation)
                    if !model.modelFields.isEmpty { sourceFieldsContent }
                    if !model.costSummary.isEmpty { Text(model.costSummary).font(.caption).foregroundColor(.secondary) }
                    Menu(T.text("导出完整依据", "匯出完整依據", "Export evidence")) {
                        Button(T.text("完整报告 HTML", "完整報告 HTML", "Full HTML report")) { onExport("report.html") }
                        Button("JSON") { onExport("report.json") }
                        Button(T.text("原始观察", "原始觀察", "Observations")) { onExport("observation.json") }
                        Button(T.text("证据文件", "證據檔案", "Evidence files")) { onExport("evidence.zip") }
                    }.controlSize(.small).disabled(model.isBusy)
                    DisclosureGroup(T.text("原始数据", "原始資料", "Raw data")) {
                        ScrollView {
                            Text(model.detailText.isEmpty ? T.text("暂无更多依据。", "暫無更多依據。", "No further details are available.") : model.detailText)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 220)
                    }
                }.padding(.top, 10)
            } label: { Text(T.text("查看依据与全部检查", "查看依據與全部檢查", "Evidence and all checks")).font(.callout) }
            .accessibilityIdentifier("model-detect-details")
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceFieldsContent: some View {
        DisclosureGroup(isExpanded: $modelFieldsExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(model.modelFields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Text(fieldLabel(field)).font(.caption).foregroundColor(.secondary).frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.model).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            Text(field.location).font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if model.modelFieldCount > model.modelFields.count {
                    Text("显示最近 \(model.modelFields.count) 条；全部 \(model.modelFieldCount) 条已分析，完整依据可导出。").font(.caption).foregroundColor(.secondary)
                }
            }.padding(.top, 10)
        } label: { Text(T.text("型号字段与原始位置", "型號欄位與原始位置", "Model fields and source locations")).font(.callout.weight(.medium)) }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(ModelDetectPalette.card))
        .accessibilityIdentifier("model-detect-source-fields")
    }

    private var historyComparisonContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(T.text("选择历史结果", "選擇歷史結果", "Earlier result"), selection: Binding(get: { model.selectedHistoryID }, set: { model.compareHistory(with: $0) })) {
                Text(T.text("选择一份已完成的结果", "選擇一份已完成的結果", "Choose a completed result")).tag("")
                ForEach(model.comparisonCandidates) { row in Text(row.title + " · " + row.detail).tag(row.id) }
            }.disabled(model.comparingHistory).accessibilityIdentifier("model-detect-history-select")
            if model.comparingHistory { ProgressView().controlSize(.small) }
            if let title = model.historyComparison["title"].string {
                Text(title).font(.callout.weight(.semibold))
                Text(model.historyComparison["summary"].string ?? "").font(.caption).foregroundColor(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    comparisonSummary("left", label: T.text("历史结果", "歷史結果", "Earlier"))
                    comparisonSummary("right", label: T.text("本次结果", "本次結果", "Current"))
                }
                if !model.historyComparison["changes"].array.isEmpty {
                    DisclosureGroup(T.text("查看差别", "查看差別", "Changes")) {
                        ForEach(Array(model.historyComparison["changes"].array.enumerated()), id: \.offset) { _, row in
                            Text(row["text"].string ?? "").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Text(T.text("仅比较已有记录，不会再次调用模型。", "僅比較既有紀錄，不會再次呼叫模型。", "Uses saved records only. No new model calls.")).font(.caption).foregroundColor(.secondary)
        }
    }
    private func comparisonSummary(_ key: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(model.historyComparison[key]["title"].string ?? "").font(.callout)
            Text(model.historyComparison[key]["summary"].string ?? "").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fieldLabel(_ field: ModelDetectNativeModel.ModelField) -> String {
        let owner = ["main":"主会话", "child":"子任务", "compaction":"压缩任务"][field.owner] ?? "归属未明"
        let scope = ["request":"请求", "response":"响应声明", "session_default":"会话默认", "child_request":"子任务配置", "compaction":"压缩配置"][field.scope] ?? "元数据"
        return owner + " · " + scope
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.history.isEmpty {
                Text(T.text("还没有检测记录。", "還沒有檢測記錄。", "No assessments yet.")).foregroundColor(.secondary)
            }
            ForEach(Array(model.history.prefix(10))) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Text(historyStatus(item.status)).font(.caption).foregroundColor(.secondary)
                        if !item.detail.isEmpty { Text(item.detail).font(.caption2).foregroundColor(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button(T.text("查看", "查看", "View")) { model.showHistory(id: item.id) }
                        .disabled(model.isBusy)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func historyStatus(_ status: String) -> String {
        switch status {
        case "completed": return T.text("已完成", "已完成", "Completed")
        case "running": return T.text("正在检测", "正在檢測", "Running")
        case "queued": return T.text("等待开始", "等待開始", "Queued")
        case "cancelling": return T.text("正在停止", "正在停止", "Stopping")
        case "cancelled": return T.text("已停止", "已停止", "Stopped")
        case "failed": return T.text("未完成", "未完成", "Incomplete")
        case "interrupted": return T.text("上次中断", "上次中斷", "Interrupted")
        case "action_required": return T.text("需要重新配置", "需要重新設定", "Configuration required")
        default: return T.text("状态待确认", "狀態待確認", "Status unavailable")
        }
    }

    private func protocolPicker(selection: Binding<String>) -> some View {
        Picker(T.text("接口协议", "介面協定", "Protocol"), selection: selection) {
            Text("Chat Completions").tag("chat_completions")
            Text("Responses").tag("responses")
            Text("Anthropic Messages").tag("messages")
        }
    }

    private func prices(input: Binding<String>, output: Binding<String>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(T.text("输入单价 / 百万 token", "輸入單價 / 百萬 token", "Input price / million tokens")).font(.caption).foregroundColor(.secondary)
                TextField("", text: input)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(T.text("输出单价 / 百万 token", "輸出單價 / 百萬 token", "Output price / million tokens")).font(.caption).foregroundColor(.secondary)
                TextField("", text: output)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.callout).foregroundColor(.secondary).frame(width: 128, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
enum ModelDetectNativeText {
    nonisolated static func localized(_ simplified: String, _ english: String) -> String {
        switch L10n.shared.language {
        case .zhHans: return simplified
        case .zhHant: return simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
        case .en: return english
        }
    }
    static func text(_ simplified: String, _ traditional: String, _ english: String) -> String {
        switch L10n.shared.language {
        case .zhHans: return simplified
        case .zhHant: return traditional
        case .en: return english
        }
    }
}
#endif
