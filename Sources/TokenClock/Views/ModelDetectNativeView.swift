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
            }
        }
        .frame(minWidth: 860, idealWidth: 900, maxWidth: .infinity,
               minHeight: 390, idealHeight: model.phase == .result ? 740 : 480, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(ModelDetectPalette.accent)
        .onChange(of: model.phase) { _ in detailsExpanded = false }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Model Detect")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.phase == .result {
                Button { onExport("report.json") } label: {
                    Label(T.text("保存结果", "儲存結果", "Save result"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isBusy)
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
        case .input: return T.text("选择已有内容，或检测一个接口。", "選擇既有內容，或檢測一個介面。", "Choose existing content or inspect an API.")
        case .running: return T.text("本次检测正在进行。", "本次檢測正在進行。", "Your assessment is in progress.")
        case .result: return model.resultObjectLabel.isEmpty
            ? T.text("本次结果", "本次結果", "Assessment result") : model.resultObjectLabel
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(T.text("检测内容", "檢測內容", "Assess"), selection: edit(\.mode)) {
                Text(T.text("已有会话", "既有會話", "Existing session")).tag(ModelDetectNativeModel.Mode.session)
                Text(T.text("检测 API", "檢測 API", "API" )).tag(ModelDetectNativeModel.Mode.api)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            .accessibilityIdentifier("model-detect-mode")

            if model.mode == .session { sessionFields } else { apiFields }

            DisclosureGroup(isExpanded: $advancedExpanded) {
                advancedContent.padding(.top, 12)
            } label: {
                Text(T.text("高级设置", "進階設定", "Advanced settings")).font(.callout)
            }
            .accessibilityIdentifier("model-detect-advanced")

            if let preview = model.preview {
                confirmation(preview)
            } else {
                HStack(spacing: 12) {
                    Button(model.mode == .session && !model.assessmentEnabled
                           ? T.text("开始检测", "開始檢測", "Start assessment")
                           : T.text("确认费用", "確認費用", "Review cost")) {
                        model.prepare()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPrepare || model.isBusy)
                    .accessibilityIdentifier("model-detect-prepare")
                    Text(model.mode == .session && !model.assessmentEnabled
                         ? T.text("仅在本机处理，无模型费用。", "僅在本機處理，無模型費用。", "Local processing, without model charges.")
                         : T.text("确认范围和预算后才发送请求。", "確認範圍與預算後才傳送請求。", "Requests require confirmation of scope and budget."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
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
            Picker(T.text("检测层级", "檢測層級", "Layer"), selection: edit(\.probeDepth)) {
                Text(T.text("L2 轻量探针", "L2 輕量探針", "L2 · Light probes")).tag("l2")
                Text(T.text("L3 重型探针", "L3 重型探針", "L3 · Heavy probes")).tag("l3")
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .accessibilityIdentifier("model-detect-layer")
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
            if model.inputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.outputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(T.text("还需在高级设置中填写或读取单价，空值不按免费计算。", "還需在進階設定中填寫或讀取單價，空值不按免費計算。", "Add or retrieve pricing in Advanced settings. Blank prices are not treated as free."))
                    .font(.caption).foregroundColor(.secondary)
                    .accessibilityIdentifier("model-detect-missing-pricing")
            }
        }
        .textFieldStyle(.roundedBorder)
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
                protocolPicker(selection: edit(\.apiFormat))
                prices(input: edit(\.inputPrice), output: edit(\.outputPrice))
                HStack {
                    Button(T.text("读取型号与报价", "讀取型號與報價", "Read models and pricing")) { model.readModelCatalog() }
                    Button(T.text("保存连接到钥匙串", "儲存連線至鑰匙圈", "Save connection to Keychain")) { model.saveConnection() }
                }
                .disabled(model.isBusy)
                if !model.models.isEmpty {
                    Picker(T.text("目录型号", "目錄型號", "Catalog model"), selection: Binding(
                        get: { model.modelID }, set: { model.selectCatalogModel($0) }
                    )) {
                        if !model.models.contains(model.modelID) { Text(model.modelID.isEmpty ? T.text("选择型号", "選擇型號", "Select model") : model.modelID).tag(model.modelID) }
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                }
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
                Picker(T.text("参考家族", "參考家族", "Reference family"), selection: edit(\.advancedFamily)) {
                    Text(T.text("按明确型号匹配", "按明確型號匹配", "Match the declared model")).tag("auto")
                    Text("OpenAI").tag("openai")
                    Text("Claude").tag("anthropic")
                }
                labeled(T.text("指定题目（可选）", "指定題目（可選）", "Questions (optional)")) {
                    TextField("O07:A, C06:A", text: edit(\.taskIDs))
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
        }
        .font(.callout)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    private var assessmentAvailable: Bool {
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
                Text(preview.budgetSummary).font(.system(.body, design: .rounded).weight(.semibold))
                if !preview.summary.isEmpty { Text(preview.summary).font(.callout).foregroundColor(.secondary) }
                if let target = preview.targetSummary, !target.isEmpty {
                    Toggle(isOn: $model.targetConsent) { Text(target).font(.callout) }
                        .accessibilityIdentifier("model-detect-target-consent")
                }
                if let judge = preview.judgeSummary, !judge.isEmpty {
                    Toggle(isOn: $model.judgeConsent) { Text(judge).font(.callout) }
                        .accessibilityIdentifier("model-detect-judge-consent")
                }
                if let warning = preview.warning, !warning.isEmpty { Text(warning).font(.caption).foregroundColor(.secondary) }
                Button(T.text("确认并开始", "確認並開始", "Confirm and start")) { model.confirmStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart || model.isBusy)
                    .accessibilityIdentifier("model-detect-confirm")
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
                ForEach(Array(brief.reasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                    Label { Text(reason).textSelection(.enabled) } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundColor(.secondary)
                    }
                    .font(.system(size: 11))
                }
                if !brief.caveat.isEmpty {
                    Text(brief.caveat).font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
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
            ModelDetectEvidenceMatrixView(presentation: model.presentation)
                .id(model.currentJobID)
            if let title = model.brief?.primaryActionTitle, !title.isEmpty {
                HStack {
                    Text(T.text("继续补充依据", "繼續補充依據", "Collect more evidence")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button(title) { model.performPrimaryAction() }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("model-detect-primary-action")
                }
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button(T.text("保存结果", "儲存結果", "Save result")) { onExport("report.json") }
                        Menu(T.text("其他导出", "其他匯出", "More exports")) {
                            Button("HTML") { onExport("report.html") }
                            Button(T.text("原始观察", "原始觀察", "Observations")) { onExport("observation.json") }
                            Button(T.text("证据文件", "證據檔案", "Evidence files")) { onExport("evidence.zip") }
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    ScrollView {
                        Text(model.detailText.isEmpty ? T.text("暂无更多依据。", "暫無更多依據。", "No further details are available.") : model.detailText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
                .padding(.top, 10)
            } label: { Text(T.text("查看详情", "查看詳情", "Details")).font(.callout) }
            .accessibilityIdentifier("model-detect-details")
        }
        .accessibilityElement(children: .contain)
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
    static func text(_ simplified: String, _ traditional: String, _ english: String) -> String {
        switch L10n.shared.language {
        case .zhHans: return simplified
        case .zhHant: return traditional
        case .en: return english
        }
    }
}
#endif
