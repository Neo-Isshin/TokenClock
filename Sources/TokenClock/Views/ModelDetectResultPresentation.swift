#if os(macOS)
import Foundation

/// A projection of saved evidence, never a second grader or an identity score.
/// The 22 items exclude I01–I03 and F01 (infrastructure and synthesis).
@MainActor
struct ModelDetectResultPresentation {
    typealias T = ModelDetectNativeText
    enum State: String, CaseIterable {
        case issue, aligned, observed, limited, notRun, unavailable
        @MainActor var label: String {
            switch self {
            case .issue: return T.text("发现问题", "發現問題", "Issue")
            case .aligned: return T.text("检查符合", "檢查符合", "Check met")
            case .observed: return T.text("已有观察", "已有觀察", "Observed")
            case .limited: return T.text("资料不足", "資料不足", "Insufficient")
            case .notRun: return T.text("未检测", "未檢測", "Not checked")
            case .unavailable: return T.text("不适用", "不適用", "Not applicable")
            }
        }
        var symbol: String {
            switch self {
            case .issue: return "exclamationmark"
            case .aligned: return "checkmark"
            case .observed: return "circle.fill"
            case .limited: return "questionmark"
            case .notRun: return "minus"
            case .unavailable: return ""
            }
        }
    }
    struct Item: Identifiable {
        let id: String
        let name: String
        let english: String
        let group: Int
        let layers: Set<Int>
        @MainActor var title: String { T.text(name, name.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? name, english) }
    }
    struct Note: Equatable { let text: String; let pointer: String }
    struct Cell {
        var state: State
        var notes: [Note] = []
        var hasObservation = false
        var hasGap = false
    }
    static let items: [Item] = [
        .init(id: "S01", name: "型号声明", english: "Model claims", group: 0, layers: [1,2,3]),
        .init(id: "T01", name: "输入边界", english: "Input handling", group: 1, layers: [1,2]),
        .init(id: "T02", name: "缓存计量", english: "Cache / usage", group: 1, layers: [1,2,3]),
        .init(id: "T03", name: "流式事件", english: "Stream events", group: 1, layers: [1,2,3]),
        .init(id: "T04", name: "接口字段", english: "API fields", group: 1, layers: [1,2,3]),
        .init(id: "T05", name: "会话变化", english: "Session changes", group: 1, layers: [1,3]),
        .init(id: "P01", name: "读取覆盖", english: "Read coverage", group: 2, layers: [1,3]),
        .init(id: "P02", name: "写入范围", english: "Write scope", group: 2, layers: [1,3]),
        .init(id: "P03", name: "验证执行", english: "Verification", group: 2, layers: [1,3]),
        .init(id: "P04", name: "错误恢复", english: "Recovery", group: 2, layers: [1,3]),
        .init(id: "P05", name: "证据更新", english: "Evidence use", group: 2, layers: [1,3]),
        .init(id: "Q01", name: "交付约束", english: "Delivery claims", group: 3, layers: [1,2,3]),
        .init(id: "H01", name: "程序交付", english: "Program", group: 3, layers: [1,3]),
        .init(id: "H02", name: "交互成品", english: "Interaction", group: 3, layers: [1,3]),
        .init(id: "H03", name: "任务恢复", english: "Task recovery", group: 3, layers: [1,3]),
        .init(id: "H04", name: "空间时序", english: "Space / time", group: 3, layers: [1,3]),
        .init(id: "B01", name: "首选方案", english: "First strategy", group: 4, layers: [1,2]),
        .init(id: "B02", name: "自发补充", english: "Extra context", group: 4, layers: [1,2]),
        .init(id: "B03", name: "候选规模", english: "Alternatives", group: 4, layers: [1,2]),
        .init(id: "B04", name: "默认假设", english: "Assumptions", group: 4, layers: [1,2]),
        .init(id: "N01", name: "中性选择", english: "Neutral choice", group: 4, layers: [1,2]),
        .init(id: "R01", name: "资源投入", english: "Resources", group: 5, layers: [1,2,3]),
    ]
    static var groups: [String] { [T.text("来源", "來源", "Source"), T.text("服务处理", "服務處理", "Service"), T.text("工作轨迹", "工作軌跡", "Process"), T.text("能力交付", "能力交付", "Delivery"), T.text("行为偏好", "行為偏好", "Behavior"), T.text("资源", "資源", "Usage")] }
    var cells: [String: Cell] = [:]
    var title = ""
    var summary = ""
    var tone: State = .limited
    var isControlled = false
    var multipleSubjects = false

    init(report: ModelDetectJSON = .null) {
        for item in Self.items {
            for layer in 1...3 { cells[Self.key(item.id, layer)] = Cell(state: item.layers.contains(layer) ? .notRun : .unavailable) }
        }
        consume(report, prefix: "", depth: 0)
        let brief = report["user_summary"]["brief"]
        multipleSubjects = report["user_summary"]["synthesis"]["subjects"].array.count > 1
        conclusion(brief)
    }
    static func key(_ item: String, _ layer: Int) -> String { "L\(layer).\(item)" }
    func cell(_ item: String, _ layer: Int) -> Cell { cells[Self.key(item, layer)] ?? Cell(state: .notRun) }
    var observedCount: Int { Self.items.filter { item in (1...3).contains { cell(item.id, $0).hasObservation } }.count }
    var issueCount: Int { Self.items.filter { item in (1...3).contains { cell(item.id, $0).state == .issue } }.count }
    func observedCount(layer: Int) -> Int { Self.items.filter { cell($0.id, layer).hasObservation }.count }
    var firstCell: String {
        for state in [State.issue, .limited, .observed, .aligned] {
            for item in Self.items { for layer in 1...3 where cell(item.id, layer).state == state { return Self.key(item.id, layer) } }
        }
        return "L1.S01"
    }

    private mutating func add(_ id: String, _ layer: Int, _ state: State, _ note: String, _ pointer: String) {
        let key = Self.key(id, layer)
        guard var cell = cells[key], cell.state != .unavailable else { return }
        let previous = cell.state
        cell.hasObservation = cell.hasObservation || [.issue, .aligned, .observed].contains(state)
        cell.hasGap = cell.hasGap || state == .limited
        // A pass alongside missing checks is partial; an explicit issue remains visible.
        if cell.state == .issue || state == .issue { cell.state = .issue }
        else if cell.hasGap { cell.state = .limited }
        else if cell.state == .observed || state == .observed { cell.state = .observed }
        else { cell.state = state }
        let entry = Note(text: note, pointer: pointer)
        if !cell.notes.contains(entry) {
            if state == .issue && previous != .issue || state == .limited && ![.issue, .limited].contains(previous) {
                cell.notes.insert(entry, at: 0)
                cell.notes = Array(cell.notes.prefix(8))
            } else if cell.notes.count < 8 { cell.notes.append(entry) }
        }
        cells[key] = cell
    }

    private mutating func consume(_ report: ModelDetectJSON, prefix: String, depth: Int) {
        guard depth < 3, !report.object.isEmpty else { return }
        let result = report["result"], workflow = report["workflow_mode"].string ?? "l1"
        if workflow == "combined" {
            for (index, part) in result["components"].array.prefix(12).enumerated() {
                consume(part["report"], prefix: prefix + "/result/components/\(index)/report", depth: depth + 1)
            }
            return
        }
        let source = result["source"]["kind"].string ?? ""
        isControlled = isControlled || report["scope"]["synthetic"].bool == true || result["scope"]["synthetic"].bool == true || ["scripted_demo", "synthetic_fixture", "controlled_variant"].contains(source) || result["source_scope"].string == "scripted_demo"
        // Imported short answers and artifacts are passive observations, not new probe calls.
        let imported = result["source_scope"].string == "imported_answers" || source == "artifact" || source == "original_artifact"
        let active = ["live_probe", "replay_record"].contains(source) || ["new_live_requests", "recorded_response_replay", "scripted_demo"].contains(result["source_scope"].string ?? "") || ["live_target", "replayed_or_scripted_target_actions"].contains(result["execution"]["action_origin"].string ?? "")
        let layer = !imported && (active || result["attempted_requests"].number.map { $0 > 0 } == true) ? (workflow == "l2" ? 2 : workflow == "l3" ? 3 : 1) : 1
        for (index, fact) in report["facts"].array.enumerated() { factCell(fact, layer: 1, path: prefix + "/facts/\(index)") }
        for (index, unknown) in report["unknowns"].array.enumerated() {
            let code = unknown["code"].string ?? ""
            let mapping = ["source.unbound_model_claims": "S01", "process.read_coverage_incomplete": "P01", "process.test_result_unknown": "P03", "process.test_execution_not_observed": "P03", "resource.usage_missing": "T02", "resource.stream_timing_unknown": "T03", "delivery.semantic_review_not_implemented": "Q01"]
            if let id = mapping[code] { add(id, 1, .limited, T.text("现有记录缺少此项核验所需信息。", "現有記錄缺少此項核驗所需資訊。", "The record lacks information needed for this check."), prefix + "/unknowns/\(index)") }
        }
        for (index, group) in report["verification_history"]["groups"].array.enumerated() {
            let path = prefix + "/verification_history/groups/\(index)"
            if group["state"].string == "recovered_checks" { add("P04", 1, .observed, T.text("同项检查由失败转为通过，早期失败记录保留。", "同項檢查由失敗轉為通過，早期失敗記錄保留。", "The same check later passed; its earlier failure is retained."), path) }
            if group["last_result"].string == "fail" { add("P03", 1, .issue, T.text("最近的同项检查仍未通过。", "最近的同項檢查仍未通過。", "The latest result of this check still fails."), path) }
        }
        diagnostics(result["task_id"].string == "diagnostics" ? result : result["diagnostics"], layer: layer, path: prefix + (result["task_id"].string == "diagnostics" ? "/result" : "/result/diagnostics"))
        for (index, sample) in result["samples"].array.enumerated() {
            let task = String((sample["task_id"].string ?? "").prefix(3)), path = prefix + "/result/samples/\(index)"
            let item = ["O07":"B01", "C06":"B02", "O05":"B02", "C02":"B04", "O06":"B03", "O09":"B03", "O10":"B04", "O08":"B04", "C04":"B04"] [task] ?? (task.hasPrefix("N") ? "N01" : "Q01")
            let features = sample["extracted"]["features"].object
            let incomplete = sample["metadata"]["completed"].bool != true || sample["metadata"]["truncated"].bool == true || ["failed", "limited", "noncompliant"].contains(sample["extracted"]["status"].string ?? "")
            let valid = features.contains { key, value in key != "extraction_category" && value != .null && !["UNKNOWN", "UNCLASSIFIED"].contains(value.string ?? "") }
            add(item, layer, incomplete || !valid ? .limited : .observed,
                incomplete ? T.text("此题未完整完成或未遵守题意，不作能力失败。", "此題未完整完成或未遵守題意，不作能力失敗。", "Incomplete or noncompliant response; not an ability failure.") : valid ? T.text("已从回答提取特征；偏好本身不代表正确或错误。", "已從回答提取特徵；偏好本身不代表正確或錯誤。", "Answer features extracted; preferences are not pass/fail judgments.") : T.text("已取得回答，但尚未提取可用特征。", "已取得回答，但尚未提取可用特徵。", "An answer is present, but no usable features were extracted."), path + "/extracted")
            if !incomplete {
                for (feature, value) in features where value != .null && !["UNKNOWN", "UNCLASSIFIED"].contains(value.string ?? "") {
                    if let module = Self.featureModules[feature] {
                        add(module, layer, .observed, T.text("已提取回答特征", "已提取回答特徵", "Extracted answer feature") + " · " + feature, path + "/extracted/features/" + feature)
                    }
                }
            }
        }
        let task = String((result["task_id"].string ?? "").prefix(3))
        if ["H01", "H02", "H03", "H04"].contains(task) {
            let limited = result["checks"].array.contains { $0["id"].string == "generation.complete" && $0["status"].string != "pass" }
            if limited {
                add(task, layer, .limited, T.text("生成未完整完成；交付能力不计失败。", "生成未完整完成；交付能力不計失敗。", "Generation was incomplete; delivery ability is not marked failed."), prefix + "/result/checks")
            } else {
                for (index, check) in result["checks"].array.enumerated() where check["id"].string != "generation.complete" {
                    let state: State = check["status"].string == "fail" ? .issue : check["status"].string == "pass" ? .aligned : .limited
                    add(task, layer, state, T.text("本地判据", "本地判據", "Local criterion") + " · " + (check["id"].string ?? task) + " · " + state.label, prefix + "/result/checks/\(index)")
                }
                if result["checks"].array.isEmpty { add(task, layer, .limited, T.text("报告缺少本地检查结果。", "報告缺少本地檢查結果。", "The report contains no local check results."), prefix + "/result") }
            }
        }
        for (index, event) in result["trajectory"]["events"].array.enumerated() where event["actor"].string == "target" {
            let id = ["read_file":"P01", "write_file":"P02", "run_checks":"P03"][event["action"].string ?? ""]
            if let id { add(id, layer, .observed, T.text("已记录目标模型的实际工具事件。", "已記錄目標模型的實際工具事件。", "A tool event attributed to the target was recorded."), prefix + "/result/trajectory/events/\(index)") }
        }
        if result["trajectory"]["observed_recovery_chains"].array.contains(where: { $0["actor"].string == "target" }) { add("P04", layer, .observed, T.text("已记录同项检查的恢复过程。", "已記錄同項檢查的恢復過程。", "A same-check recovery chain was recorded."), prefix + "/result/trajectory/observed_recovery_chains") }
    }

    private mutating func factCell(_ fact: ModelDetectJSON, layer: Int, path: String) {
        let code = fact["code"].string ?? ""
        let rows: [String: (String, State, String)] = [
            "source.model_claim_difference": ("S01", .issue, "同次调用的请求与响应型号声明不同。"),
            "source.billing_claim_difference": ("S01", .issue, "计费与调用型号声明不同。"),
            "source.binding_collision": ("S01", .issue, "同一记录标识对应不同内容。"),
            "source.model_claim_consistent": ("S01", .aligned, "可见请求与响应的型号声明一致；这不认证后端。"),
            "source.display_model": ("S01", .observed, "只有显示型号声明，不能确认后端。"),
            "source.context_model_label": ("S01", .observed, "已有上下文型号标签，尚非逐调用证明。"),
            "source.provider_change": ("T05", .observed, "供应商字段发生变化，不等于换了型号。"),
            "process.read_visible": ("P01", .observed, "记录包含实际返回的文件内容；读取不等于理解。"),
            "process.edit_path": ("P02", .observed, "已记录写入路径。"),
            "process.artifact_content_changed": ("P02", .observed, "已有文件内容变化的记录。"),
            "process.edit_outside_explicit_scope": ("P02", .issue, "写入超出任务明确允许的范围。"),
            "process.test_result": ("P03", .observed, "已记录实际检查结果；前后结果分别保留。"),
            "process.test_exit_mismatch": ("P03", .issue, "记录中存在检查退出码与返回内容不一致。"),
            "process.unverified_completion_claim": ("Q01", .limited, "完成声明没有对应的可见核验记录。"),
            "process.latest_change_unverified": ("P03", .limited, "最近修改后没有对应的可见复验记录。"),
            "resource.reasoning_reported": ("R01", .observed, "已记录接口报告的推理用量，未推断内部步骤。"),
            "resource.elapsed_seconds": ("R01", .observed, "已记录耗时，包含网络与排队等影响。"),
            "resource.stream_observed": ("T03", .observed, "已记录客户端可见的流式事件。"),
            "resource.usage_conflict_details": ("T02", .issue, "计量字段不符合所声明的计量规则。"),
            "semantic.explicit_candidate_set": ("B03", .observed, "已提取明确列出的候选项。"),
            "semantic.hypothesis_revision": ("P05", .observed, "已提取带原文依据的结论修订；不保证修订正确。"),
        ]
        if let (id, state, note) = rows[code] {
            add(id, layer, state, T.text(note, note.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? note, note), path)
        }
        if code == "resource.usage_consistency" { add("T02", layer, fact["value"].bool == true ? .aligned : fact["value"].bool == false ? .issue : .limited, "已核对可见用量字段的计量关系，不推断缓存来源。", path) }
    }
    private mutating func diagnostics(_ value: ModelDetectJSON, layer: Int, path: String) {
        for (index, check) in value["checks"].array.enumerated() {
            let name = (check["id"].string ?? "").components(separatedBy: ":").first ?? ""
            guard let item = ["model_declaration":"S01", "binding":"S01", "usage":"T02", "stream_clock_order":"T03"][name] else { continue }
            let state: State = check["status"].string == "fail" ? .issue : check["status"].string == "pass" ? .aligned : .limited
            add(item, layer, state, T.text("按记录中的字段与规则核验", "按記錄中的欄位與規則核驗", "Checked against the recorded fields and rules") + " · " + state.label, path + "/checks/\(index)")
        }
        for (index, row) in value["observations"].array.enumerated() {
            let kind = row["type"].string ?? ""
            guard let item = ["explicit_text_stage_comparison":"T01", "api_field_surface":"T04", "source_fields":"T04", "visible_response_headers":"T04", "request_failure":"T04", "completion":"T04", "session_visible_field_change":"T05", "client_stream_shape":"T03", "controller_call_status":"R01", "reasoning_usage_field":"R01"][kind] else { continue }
            let missing = kind == "reasoning_usage_field" && row["state"].string != "reported" || kind == "explicit_text_stage_comparison" && row["status"].string != "observed"
            add(item, layer, missing ? .limited : .observed, T.text("已保留可见服务记录；不将服务特征直接归因为型号。", "已保留可見服務記錄；不將服務特徵直接歸因為型號。", "Visible service records retained; service traits do not establish model identity."), path + "/observations/\(index)")
        }
    }
    private static let featureModules = [
        "strategy":"B01", "explicit_final_recommendation":"B01", "answer_forms":"B01", "primary_negation_form":"B01", "first_allocation":"B01", "first_stated_rule":"B01", "primary_recommendation":"B01", "recommended_names":"B01",
        "independent_lists_contrast":"B02", "nested_rebinding_contrast":"B02", "immutable_element_rebinding_contrast":"B02", "capacity_caveat":"B02", "staleness_caveat":"B02", "code_example":"B02", "elaborated_reason":"B02", "symbolic_group_size_derivation":"B02", "offers_example":"B02", "mentions_connectivity":"B02",
        "distinct_presented_strategies":"B03", "candidate_count":"B03", "candidate_names":"B03", "deliverable_count":"B03", "full_rewrite_variants":"B03", "methods_offered":"B03", "allocation_modes_offered":"B03",
        "asks_rule":"B04", "premise_handling":"B04", "event_model":"B04", "asks_target":"B04", "asks_for_code":"B04", "adds_horizon_assumption":"B04", "asks_context":"B04", "selection_mode":"B04",
    ]
    private mutating func conclusion(_ brief: ModelDetectJSON) {
        title = brief["title"].string ?? T.text("资料不足，无法判定型号", "資料不足，無法判定型號", "Insufficient evidence to identify the model")
        summary = brief["summary"].string ?? ""
        switch brief["status"].string {
        case "source_conflict": title = T.text("型号声明或调用记录不一致", "型號聲明或呼叫記錄不一致", "Model claims or call records conflict"); tone = .issue
        case "local_deviation_signal": title = T.text("已测特征偏离申报型号", "已測特徵偏離申報型號", "Measured traits diverge from the declared model"); tone = .issue
        case "local_declared_alignment": title = T.text("已测特征更接近申报型号", "已測特徵更接近申報型號", "Measured traits favor the declared model"); tone = .aligned
        case "mixed_local_directions": title = T.text("检测项给出了相反方向", "檢測項給出了相反方向", "Checks point in opposing directions"); tone = .observed
        case "delivery_issue": title = T.text("交付检查未通过", "交付檢查未通過", "Delivery checks failed"); tone = .issue
        case "insufficient_evidence": title = T.text("资料不足，无法判定型号", "資料不足，無法判定型號", "Insufficient evidence to identify the model"); tone = .limited
        case "observations_only":
            tone = issueCount > 0 ? .issue : .observed
            if title == "已有一些局部观察，暂不能判断型号" {
                title = issueCount > 0 ? T.text("发现记录或交付检查问题", "發現記錄或交付檢查問題", "Record or delivery checks found issues") : T.text("已有观察，缺少可比型号参考", "已有觀察，缺少可比型號參考", "Observations recorded; comparable references missing")
                if issueCount > 0, let item = Self.items.first(where: { item in (1...3).contains { cell(item.id, $0).state == .issue } }), let layer = (1...3).first(where: { cell(item.id, $0).state == .issue }) {
                    summary = cell(item.id, layer).notes.first?.text ?? summary
                }
            }
            if title == "本次交付检查已通过" { tone = .aligned }
        default: break
        }
        if isControlled && brief["status"].string != "source_conflict" {
            title = T.text("演示记录：仅展示检测流程", "演示記錄：僅展示檢測流程", "Demonstration records — workflow preview"); tone = .observed
        }
    }
}
#endif
