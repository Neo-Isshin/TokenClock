#if os(macOS)
import SwiftUI
import AppKit

struct LocalToolboxView: View {
    @ObservedObject var model: LocalToolboxModel
    @State private var mode = "environment"
    @State private var pattern = ""
    @State private var fullScan = false
    @State private var selected = Set<String>()
    @State private var confirmTrash = false
    @State private var trashStatus = ""
    private let modes = ["environment","disk","secrets","clock","keys"]
    private func title(_ value: String) -> String {
        switch value {
        case "disk":return toolboxText("磁盘与清理", "Disk & Cleanup")
        case "secrets":return toolboxText("日志泄密", "Log Secrets")
        case "clock":return toolboxText("时钟偏差", "Clock")
        case "keys":return "API Key"
        default:return toolboxText("环境冲突", "Environment")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(toolboxText("本地工具箱", "Local Toolbox")).font(.system(size:19,weight:.bold,design:.rounded))
                    Text(toolboxText("本地检查；仅 Key 验活和 NTP 会联网", "Local scans; only key checks and NTP use the network")).font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {Button(toolboxText("停止", "Stop")){model.stop()}}
                else {Button(mode == "keys" ? toolboxText("一键收集并验活", "Collect & Check Keys") : toolboxText("开始检查", "Run Check")){ selected=[];trashStatus="";model.run(mode,pattern:pattern,full:fullScan) }}
            }.buttonStyle(.bordered).padding(.horizontal,20).padding(.vertical,16)
            Divider()
            Picker("",selection:$mode){ForEach(modes,id:\.self){Text(title($0)).tag($0)}}.pickerStyle(.segmented).padding(16).disabled(model.busy)
            HStack {if model.busy {ProgressView().controlSize(.mini)};Text(LocalToolboxResultText.status(model.status)).font(.system(size:11)).foregroundStyle(.secondary);Spacer()}.padding(.horizontal,20)
            if let checked = model.checkedAt {
                HStack { Text(toolboxText("上次检查：", "Last checked: ") + checked.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Locale(identifier:L10n.shared.language.rawValue)))); Spacer() }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,20).padding(.top,4)
            }
            if !model.cacheError.isEmpty { Text(model.cacheError).font(.system(size:10)).foregroundStyle(.orange).padding(.horizontal,20) }
            if mode == "secrets" {
                HStack {
                    Picker(toolboxText("检查方式", "Scan"), selection:$fullScan) {
                        Text(toolboxText("增量检查", "Incremental")).tag(false)
                        Text(toolboxText("全面检查", "Full")).tag(true)
                    }.pickerStyle(.segmented).frame(width:230).disabled(model.busy)
                    Text(toolboxText("增量复用未变化文件；规则变化后重新检查", "Reuse unchanged files; changed rules trigger a rescan")).font(.system(size:10)).foregroundStyle(.secondary)
                }.padding(.horizontal,20).padding(.vertical,8)
            }
            if mode == "secrets" {TextField(toolboxText("可选：自定义正则（内置规则始终启用）", "Optional custom regex; built-in checks remain enabled"),text:$pattern).textFieldStyle(.roundedBorder).padding(.horizontal,20).onChange(of:pattern){_ in if pattern.count>160 {pattern=String(pattern.prefix(160))}}}
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if mode == "keys" {
                        Text(toolboxText("优先使用模型列表；若不支持，仅对配置中已有模型尝试 1-token 请求。列表成功不保证所有模型可用。OAuth/订阅登录不作 API Key 验证。", "Prefer model listing; only configured models may get a 1-token fallback. Listing success does not guarantee all model access. OAuth/subscription sessions are excluded.")).font(.system(size:10)).foregroundStyle(.secondary)
                        HStack {
                            Text(toolboxText("Key / 来源", "Key / Source")).frame(width:200,alignment:.leading)
                            Text(toolboxText("接口", "Endpoint")).frame(maxWidth:.infinity,alignment:.leading)
                            Text(toolboxText("结果", "Result")).frame(width:135,alignment:.leading)
                        }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,14)
                        ForEach(model.keys) { row in
                            HStack(alignment:.top,spacing:10) {
                                VStack(alignment:.leading,spacing:4){Text(row.masked).font(.system(size:12,design:.monospaced));Text(row.source).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(2)}.frame(width:200,alignment:.leading).instantHint(row.source)
                                Text(row.endpoint).font(.system(size:10)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                Text(row.localizedStatus).font(.system(size:11,weight:.semibold)).frame(width:135,alignment:.leading)
                            }.toolboxCard().instantHint(toolboxText("密钥仅在本次请求内使用，不保存、不复制到报告", "Keys are used in-memory for this check only; never saved or included in reports"))
                        }
                    } else {
                        ForEach(model.findings) { finding in
                            VStack(alignment:.leading,spacing:7) {
                                HStack {Text(finding.localizedTitle).font(.system(size:12,weight:.semibold));Spacer();if let path=finding.path {Button {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])} label:{Image(systemName:"folder")}.instantHint(toolboxText("在 Finder 中定位文件", "Reveal in Finder"))}}
                                Text(finding.localizedDetail).font(.system(size:10.5,design:.monospaced)).textSelection(.enabled)
                            }.toolboxCard()
                        }
                    }
                    if mode == "disk" {
                        Text(toolboxText("仅可选择 30 天前未变化的 JSONL / LOG 文件；配置、数据库和符号链接不会清理。文件移入废纸篓。", "Only unchanged JSONL/LOG files older than 30 days can be selected. Configs, databases and symlinks are excluded. Files move to Trash.")).font(.system(size:10)).foregroundStyle(.secondary)
                        ForEach(model.files.filter(\.eligible)) { file in
                            Toggle(isOn:Binding(get:{selected.contains(file.path)},set:{if $0 {selected.insert(file.path)}else{selected.remove(file.path)}})) {
                                VStack(alignment:.leading){Text(file.path).font(.system(size:10)).lineLimit(2);Text(ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file)).font(.system(size:9)).foregroundStyle(.secondary)}
                            }.toggleStyle(.checkbox)
                        }
                        Button(toolboxText("将所选文件移入废纸篓", "Move Selected to Trash")){confirmTrash=true}.disabled(selected.isEmpty || model.busy)
                            .instantHint(toolboxText("执行前会再次核对文件的修改时间和大小", "Rechecks size and modification time before moving files"))
                        Text(trashStatus).font(.system(size:10)).foregroundStyle(.secondary)
                    }
                    if model.findings.isEmpty && model.keys.isEmpty && !model.busy {Text(model.checkedAt == nil ? toolboxText("尚未检查。点击右上角开始，工具不会在后台自动扫描或验活。", "Not checked. Use Run Check; no background scans or key probes.") : toolboxText("本次检查未发现项目。", "No findings in this check.")).font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,30)}
                }.padding(16)
            }
        }.frame(minWidth:600,minHeight:460).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { mode = model.selectedMode }
        .onChange(of:mode){_ in model.selectMode(mode);selected=[];trashStatus=""}
        .onDisappear{model.stop()}
        .confirmationDialog(toolboxText("将所选旧日志移入废纸篓？", "Move the selected old logs to Trash?"),isPresented:$confirmTrash,titleVisibility:.visible){
            Button(toolboxText("移入废纸篓", "Move to Trash"),role:.destructive){
                var moved=0,failed=0
                for file in model.files where selected.contains(file.path) {do {try LocalLogScanner.recycle(file);moved+=1}catch{failed+=1}}
                trashStatus=toolboxText("已移入废纸篓 \(moved) 个 · 跳过 \(failed) 个", "\(moved) moved · \(failed) skipped");model.files.removeAll{selected.contains($0.path) && !FileManager.default.fileExists(atPath:$0.path)};selected=[]
            }
        }
    }
}
#endif
