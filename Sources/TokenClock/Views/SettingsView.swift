import SwiftUI
import AppKit

/// 设置窗口主视图
struct SettingsView: View {
    @ObservedObject var viewModel: ViewModel
    var onDone: (() -> Void)? = nil
    @State private var openclawPath: String = ""
    @State private var claudeCodePath: String = ""
    @State private var geminiPath: String = ""
    @State private var codexPath: String = ""
    @State private var hermesPath: String = ""
    @State private var opencodePath: String = ""
    @State private var qwenPath: String = ""
    @State private var copilotPath: String = ""
    @State private var grokPath: String = ""
    @State private var aiderPath: String = ""
    @State private var antigravityPath: String = ""
    @State private var clinePath: String = ""
    @State private var continuePath: String = ""
    @State private var cursorAgentPath: String = ""
    @State private var detectResults: [PathDetector.DetectionResult] = []
    @State private var detectionSummary: String = ""

    // MARK: - 热力阈值
    @State private var burstValue: String = "500"
    @State private var burstUnit: String = "K"
    @State private var hotValue: String = "100"
    @State private var hotUnit: String = "K"
    @State private var activeValue: String = "20"
    @State private var activeUnit: String = "K"
    @State private var calmValue: String = "2"
    @State private var calmUnit: String = "K"
    @State private var rateWindow: Int = 10

    let rateUnits = ["", "K", "M", "B"]
    let rateWindowOptions = [10, 30, 60]

    // MARK: - 自定义主题编辑状态
    @State private var isEditingCustomTheme = false
    @State private var editingConfig = CustomThemeConfig()
    @State private var editingThemeName: String = ""
    @State private var themeBeforeEdit: ClockFaceTheme = .classic
    // 取消编辑时用于恢复编辑前的 customThemeConfig 快照
    @State private var editingConfigBeforeEdit: CustomThemeConfig? = nil
    @State private var expandedColorRow: String? = nil

    // MARK: - 折叠状态
    @State private var pathsExpanded = false
    @State private var rateThresholdExpanded = false
    @State private var customThemeExpanded = false
    @State private var toolSelectionExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.shared.tr("settings.title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 自动探测（始终可见）
                    autoDetectSection()

                    // 工具选择
                    collapsibleSection(title: L10n.shared.tr("settings.toolSelection"), isExpanded: $toolSelectionExpanded) {
                        toolSelectionSection()
                    }

                    // 数据源路径
                    collapsibleSection(title: L10n.shared.tr("settings.dataPaths"), isExpanded: $pathsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.enabledTools.contains("OpenClaw") {
                            pathRow(
                                emoji: "🦞", name: "OpenClaw",
                                path: $openclawPath,
                                service: "openclaw",
                                browseTitle: L10n.shared.tr("settings.browseOpenClaw")
                            )
                            }

                            if viewModel.enabledTools.contains("Claude Code") {
                            pathRow(
                                emoji: "✳️", name: "Claude Code",
                                path: $claudeCodePath,
                                service: "claudeCode",
                                browseTitle: L10n.shared.tr("settings.browseClaudeCode")
                            )
                            }

                            if viewModel.enabledTools.contains("Gemini CLI") {
                            pathRow(
                                emoji: "✨", name: "Gemini CLI",
                                path: $geminiPath,
                                service: "gemini",
                                browseTitle: L10n.shared.tr("settings.browseGemini")
                            )
                            }

                            if viewModel.enabledTools.contains("Codex") {
                            pathRow(
                                emoji: "🤖", name: "Codex",
                                path: $codexPath,
                                service: "codex",
                                browseTitle: L10n.shared.tr("settings.browseCodex")
                            )
                            }

                            if viewModel.enabledTools.contains("Hermes") {
                            hermesPathRow()
                            }

                            if viewModel.enabledTools.contains("OpenCode") {
                            pathRow(
                                emoji: "🐙", name: "OpenCode",
                                path: $opencodePath,
                                service: "opencode",
                                browseTitle: L10n.shared.tr("settings.browseOpenCode")
                            )
                            }

                            if viewModel.enabledTools.contains("Qwen Code") {
                            pathRow(
                                emoji: "🟣", name: "Qwen Code",
                                path: $qwenPath,
                                service: "qwen",
                                browseTitle: L10n.shared.tr("settings.browseQwen")
                            )
                            }

                            if viewModel.enabledTools.contains("Copilot") {
                            pathRow(
                                emoji: "🐙", name: "Copilot",
                                path: $copilotPath,
                                service: "copilot",
                                browseTitle: L10n.shared.tr("settings.browseCopilot")
                            )
                            }

                            if viewModel.enabledTools.contains("Grok") {
                            pathRow(
                                emoji: "⚡", name: "Grok",
                                path: $grokPath,
                                service: "grok",
                                browseTitle: L10n.shared.tr("settings.browseGrok")
                            )
                            }

                            if viewModel.enabledTools.contains("Aider") {
                            pathRow(
                                emoji: "🤝", name: "Aider",
                                path: $aiderPath,
                                service: "aider",
                                browseTitle: L10n.shared.tr("settings.browseAider")
                            )
                            }

                            if viewModel.enabledTools.contains("Antigravity") {
                            pathRow(
                                emoji: "🛡️", name: "Antigravity",
                                path: $antigravityPath,
                                service: "antigravity",
                                browseTitle: L10n.shared.tr("settings.browseAntigravity")
                            )
                            }

                            if viewModel.enabledTools.contains("Cline") {
                            pathRow(
                                emoji: "🤖", name: "Cline",
                                path: $clinePath,
                                service: "cline",
                                browseTitle: L10n.shared.tr("settings.browseCline")
                            )
                            }

                            if viewModel.enabledTools.contains("Continue") {
                            pathRow(
                                emoji: "▶️", name: "Continue",
                                path: $continuePath,
                                service: "continue",
                                browseTitle: L10n.shared.tr("settings.browseContinue")
                            )
                            }

                            if viewModel.enabledTools.contains("Cursor Agent") {
                            pathRow(
                                emoji: "🖱️", name: "Cursor Agent",
                                path: $cursorAgentPath,
                                service: "cursorAgent",
                                browseTitle: L10n.shared.tr("settings.browseCursorAgent")
                            )
                            }

                            hintText()
                        }
                    }

                    // 热力图标阈值
                    collapsibleSection(title: L10n.shared.tr("rate.title"), isExpanded: $rateThresholdExpanded) {
                        rateThresholdSection()
                    }

                    // 自定义表盘
                    collapsibleSection(title: L10n.shared.tr("theme.title"), isExpanded: $customThemeExpanded) {
                        customThemeSection()
                    }
                }
                .padding(20)
            }

            Divider()

            // 底部按钮
            HStack {
                Spacer()
                Button(L10n.shared.tr("settings.done")) {
                    savePaths()
                    saveRateSettings()
                    saveCustomTheme()
                    onDone?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 520, height: 520)
        .onAppear {
            loadCurrentPaths()
            loadRateSettings()
            runAutoDetection()
        }
    }

    // MARK: - 自动探测区域

    private func autoDetectSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.shared.tr("settings.autoDetect"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(L10n.shared.tr("settings.redetect")) {
                    runAutoDetection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }

            if !detectionSummary.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: detectionSummary.hasPrefix("✅") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(detectionSummary.hasPrefix("✅") ? .green : .orange)
                    Text(detectionSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }

            Divider().padding(.vertical, 2)

            // Cursor 云端获取开关：告知用户会带凭证请求 cursor.com，可关
            HStack(alignment: .top, spacing: 8) {
                Toggle(isOn: $viewModel.cursorCloudFetchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.shared.tr("dataFetch.cursorCloud"))
                            .font(.system(size: 12))
                        Text(L10n.shared.tr("dataFetch.cursorCloudHint"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 工具选择

    private let toolOptions: [(emoji: String, name: String, service: String)] = [
        ("🦞", "OpenClaw", "openclaw"),
        ("✳️", "Claude Code", "claudeCode"),
        ("✨", "Gemini CLI", "gemini"),
        ("🤖", "Codex", "codex"),
        ("⚕️", "Hermes", "hermes"),
        ("🐙", "OpenCode", "opencode"),
        ("🟣", "Qwen Code", "qwen"),
        ("🐙", "Copilot", "copilot"),
        ("⚡", "Grok", "grok"),
        ("🤝", "Aider", "aider"),
        ("🛡️", "Antigravity", "antigravity"),
        ("🤖", "Cline", "cline"),
        ("▶️", "Continue", "continue"),
        ("🖱️", "Cursor Agent", "cursorAgent"),
    ]

    /// 工具是否已探测到有效数据路径
    private func isToolDetected(_ service: String) -> Bool {
        detectResults.contains { $0.service == service && $0.exists }
    }

    private func toolSelectionSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(toolOptions, id: \.name) { tool in
                    let isEnabled = viewModel.enabledTools.contains(tool.name)
                    let detected = isToolDetected(tool.service)
                    // 视觉 on/off = detected && enabled:未探测到的工具即便被用户启用也显示灰色,
                    // 让用户清楚知道哪些工具当前真正在统计;点击仍可切换 enabledTools(以便后续指向自定义路径)。
                    let shownOn = detected && isEnabled
                    HStack(spacing: 6) {
                        Text("\(tool.emoji) \(tool.name)")
                            .font(.system(size: 12))
                            .foregroundColor(detected ? .primary : .secondary.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { shownOn },
                            set: { _ in viewModel.toggleTool(tool.name) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isEnabled ? Color.accentColor.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                    .opacity(detected ? 1.0 : 0.5)
                    .allowsHitTesting(detected)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    // MARK: - 可折叠 Section

    private func collapsibleSection<Content: View>(title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            }) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : 0))
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Path Row

    private func pathRow(emoji: String, name: String, path: Binding<String>,
                         service: String, browseTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(emoji) \(name)")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                // 路径输入框
                TextField(L10n.shared.tr("settings.defaultPath"), text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)

                // 检索按钮
                Button(L10n.shared.tr("settings.search")) {
                    detectPath(for: service)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))

                // 浏览按钮
                Button(L10n.shared.tr("settings.browse")) {
                    browseForPath(service: service, currentPath: path.wrappedValue, title: browseTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }

            // 检测状态
            if let result = detectResults.first(where: { $0.service == service }) {
                HStack(spacing: 4) {
                    Image(systemName: result.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(result.exists ? .green : .red)
                    Text(result.exists ? "\(result.detail) — \(result.detectedPath)" : result.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Hermes Path Row

    private func hermesPathRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚕️ Hermes")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                TextField(L10n.shared.tr("settings.defaultPath"), text: $hermesPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)

                Button(L10n.shared.tr("settings.search")) {
                    detectPath(for: "hermes")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))

                Button(L10n.shared.tr("settings.browse")) {
                    browseForPath(service: "hermes", currentPath: hermesPath, title: L10n.shared.tr("settings.browseHermes"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }

            if let result = detectResults.first(where: { $0.service == "hermes" }) {
                HStack(spacing: 4) {
                    Image(systemName: result.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(result.exists ? .green : .red)
                    Text(result.exists ? "\(result.detail) — \(result.detectedPath)" : result.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Hint

    private func hintText() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                Text(L10n.shared.tr("settings.hint.emptyPath"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                Text(L10n.shared.tr("settings.hint.envVars"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 热力阈值设置

    private func rateThresholdSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 统计周期选择
            HStack(spacing: 8) {
                Text(L10n.shared.tr("rate.period"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Picker("", selection: $rateWindow) {
                    Text(L10n.shared.tr("rate.10min")).tag(10)
                    Text(L10n.shared.tr("rate.30min")).tag(30)
                    Text(L10n.shared.tr("rate.1hour")).tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: rateWindow) { _ in
                    saveRateSettings()
                }
                Spacer()
            }

            Divider()

            // 阈值输入行
            thresholdRow(emoji: "💥", label: L10n.shared.tr("rate.burst"), value: $burstValue, unit: $burstUnit)
            thresholdRow(emoji: "🔥", label: L10n.shared.tr("rate.hot"), value: $hotValue, unit: $hotUnit)
            thresholdRow(emoji: "🏃‍♂️", label: L10n.shared.tr("rate.active"), value: $activeValue, unit: $activeUnit)
            thresholdRow(emoji: "☕", label: L10n.shared.tr("rate.calm"), value: $calmValue, unit: $calmUnit)

            Text(L10n.shared.tr("rate.rest"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 2)

            if !rateThresholdsValid {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(L10n.shared.tr("rate.adjusted"))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                .padding(.top, 2)
            }

            // 独立保存按钮：底部 Done 按钮用 .keyboardShortcut(.return) 劫持了回车，
            // TextField 的 onSubmit 永不触发，故阈值需要一个显式保存入口。
            HStack {
                Spacer()
                Button(L10n.shared.tr("rate.save")) {
                    saveRateSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func thresholdRow(emoji: String, label: String, value: Binding<String>, unit: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("\(emoji) \(label)")
                .font(.system(size: 12))
                .frame(width: 60, alignment: .leading)

            TextField(L10n.shared.tr("rate.value"), text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 80)

            Picker("", selection: unit) {
                ForEach(rateUnits, id: \.self) { u in
                    Text(u.isEmpty ? "—" : u).tag(u)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .onChange(of: unit.wrappedValue) { _ in
                saveRateSettings()
            }

            Text(L10n.shared.tr("rate.above"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - 阈值读写

    private func loadRateSettings() {
        let burst = UserDefaults.standard.int(for: .rateBurst)
        let hot = UserDefaults.standard.int(for: .rateHot)
        let active = UserDefaults.standard.int(for: .rateActive)
        let calm = UserDefaults.standard.int(for: .rateCalm)
        let window = UserDefaults.standard.int(for: .rateWindow)

        let b = decomposeTokens(burst > 0 ? burst : 500_000)
        let h = decomposeTokens(hot > 0 ? hot : 100_000)
        let a = decomposeTokens(active > 0 ? active : 20_000)
        let c = decomposeTokens(calm > 0 ? calm : 2_000)

        burstValue = b.value; burstUnit = b.unit
        hotValue = h.value; hotUnit = h.unit
        activeValue = a.value; activeUnit = a.unit
        calmValue = c.value; calmUnit = c.unit
        rateWindow = window > 0 ? window : 10
    }

    private func saveRateSettings() {
        var b = composeTokens(value: burstValue, unit: burstUnit)
        var h = composeTokens(value: hotValue, unit: hotUnit)
        var a = composeTokens(value: activeValue, unit: activeUnit)
        var c = composeTokens(value: calmValue, unit: calmUnit)

        // 强制严格递减：b > h > a > c >= 0
        // 先自上而下压平超限值
        if h >= b { h = max(0, b - 1) }
        if a >= h { a = max(0, h - 1) }
        if c >= a { c = max(0, a - 1) }
        // 再自下而上托底
        if a <= c { a = c + 1 }
        if h <= a { h = a + 1 }
        if b <= h { b = h + 1 }

        UserDefaults.standard.setInt(b, for: .rateBurst)
        UserDefaults.standard.setInt(h, for: .rateHot)
        UserDefaults.standard.setInt(a, for: .rateActive)
        UserDefaults.standard.setInt(c, for: .rateCalm)
        UserDefaults.standard.setInt(rateWindow, for: .rateWindow)

        // 如果发生了调整，回写 UI 让用户看见
        let bNew = decomposeTokens(b)
        let hNew = decomposeTokens(h)
        let aNew = decomposeTokens(a)
        let cNew = decomposeTokens(c)
        burstValue = bNew.value; burstUnit = bNew.unit
        hotValue = hNew.value; hotUnit = hNew.unit
        activeValue = aNew.value; activeUnit = aNew.unit
        calmValue = cNew.value; calmUnit = cNew.unit
    }

    /// 检查当前输入值是否已满足严格递减
    private var rateThresholdsValid: Bool {
        let b = composeTokens(value: burstValue, unit: burstUnit)
        let h = composeTokens(value: hotValue, unit: hotUnit)
        let a = composeTokens(value: activeValue, unit: activeUnit)
        let c = composeTokens(value: calmValue, unit: calmUnit)
        return b > h && h > a && a > c && c >= 0
    }

    /// 将 token 整数分解为 (数字字符串, 单位)
    private func decomposeTokens(_ tokens: Int) -> (value: String, unit: String) {
        if tokens >= 1_000_000_000 {
            return (String(format: "%.1f", Double(tokens) / 1_000_000_000), "B")
        } else if tokens >= 1_000_000 {
            return (String(format: "%.1f", Double(tokens) / 1_000_000), "M")
        } else if tokens >= 1_000 {
            return (String(format: "%.0f", Double(tokens) / 1_000), "K")
        } else {
            return ("\(tokens)", "")
        }
    }

    /// 将 (数字字符串, 单位) 组合为 token 整数
    private func composeTokens(value: String, unit: String) -> Int {
        let num = Double(value) ?? 0
        switch unit {
        case "B": return Int(num * 1_000_000_000)
        case "M": return Int(num * 1_000_000)
        case "K": return Int(num * 1_000)
        default:  return Int(num)
        }
    }

    // MARK: - 自定义主题

    private func customThemeSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 已保存表盘列表（始终可见）
            if !viewModel.savedCustomThemes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.shared.tr("theme.saved"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    ForEach(viewModel.savedCustomThemes) { theme in
                        HStack(spacing: 8) {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            Text(theme.name)
                                .font(.system(size: 12))

                            Spacer()

                            Button(L10n.shared.tr("theme.apply")) {
                                viewModel.applyCustomTheme(id: theme.id)
                                viewModel.selectedTheme = .custom
                                viewModel.saveTheme()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.system(size: 11))

                            Button(L10n.shared.tr("theme.delete")) {
                                viewModel.deleteCustomTheme(id: theme.id)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }

            if !isEditingCustomTheme {
                // 未编辑状态：显示新建按钮
                HStack {
                    Button(action: { startEditingCustomTheme() }) {
                        Label(L10n.shared.tr("theme.new"), systemImage: "paintbrush.pointed.fill")
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.yellow)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
            } else {
                // 编辑状态：显示编辑器 + 取消/保存
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.shared.tr("theme.editing"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.shared.tr("theme.cancel")) {
                            cancelEditingCustomTheme()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11))

                        Button(L10n.shared.tr("theme.save")) {
                            saveEditingCustomTheme()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .disabled(editingThemeName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    TextField(L10n.shared.tr("theme.nameHint"), text: $editingThemeName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    customThemeEditor()
                        .onChange(of: editingConfig) { _ in
                            editingConfig.save()
                        }
                }
            }
        }
    }

    private func startEditingCustomTheme() {
        themeBeforeEdit = viewModel.selectedTheme
        editingConfig = CustomThemeConfig.load()
        editingConfigBeforeEdit = editingConfig   // 快照编辑前配置，供取消时回写
        editingThemeName = ""
        isEditingCustomTheme = true
        viewModel.selectedTheme = .custom
        editingConfig.save()
    }

    private func cancelEditingCustomTheme() {
        isEditingCustomTheme = false
        viewModel.selectedTheme = themeBeforeEdit
        viewModel.saveTheme()
        // 回写编辑前的 customThemeConfig，撤销编辑期间的实时 save()
        if let snap = editingConfigBeforeEdit {
            editingConfig = snap
            editingConfig.save()
        }
        editingConfigBeforeEdit = nil
    }

    private func saveEditingCustomTheme() {
        let name = editingThemeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        viewModel.saveNewCustomTheme(name: name, config: editingConfig)
        isEditingCustomTheme = false
    }

    @ViewBuilder
    private func customThemeEditor() -> some View {
        // 表盘
        colorRow(label: L10n.shared.tr("editor.dialBg"), color: Binding(
            get: { editingConfig.dialColor.swiftUIColor },
            set: { editingConfig.dialColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.dialBorder"), color: Binding(
            get: { editingConfig.dialRimColor.swiftUIColor },
            set: { editingConfig.dialRimColor = CodableColor(color: $0) }
        ))
        sliderRow(label: L10n.shared.tr("editor.borderWidth"), value: $editingConfig.dialRimWidth, range: 0...20, step: 0.5)

        Divider()

        // 指针颜色
        colorRow(label: L10n.shared.tr("editor.handHour"), color: Binding(
            get: { editingConfig.hourHandColor.swiftUIColor },
            set: { editingConfig.hourHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.handMinute"), color: Binding(
            get: { editingConfig.minuteHandColor.swiftUIColor },
            set: { editingConfig.minuteHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.handSecond"), color: Binding(
            get: { editingConfig.secondHandColor.swiftUIColor },
            set: { editingConfig.secondHandColor = CodableColor(color: $0) }
        ))

        // 指针样式
        pickerRow(label: L10n.shared.tr("editor.handStyle"), selection: $editingConfig.handStyleRaw, options: [
            ("round", L10n.shared.tr("handStyle.round")), ("tapered", L10n.shared.tr("handStyle.tapered")), ("lance", L10n.shared.tr("handStyle.lance")), ("sword", L10n.shared.tr("handStyle.sword"))
        ])

        // 指针宽度
        sliderRow(label: L10n.shared.tr("editor.handWidthHour"), value: $editingConfig.hourHandWidth, range: 1...10, step: 0.5)
        sliderRow(label: L10n.shared.tr("editor.handWidthMin"), value: $editingConfig.minuteHandWidth, range: 1...8, step: 0.5)
        sliderRow(label: L10n.shared.tr("editor.handWidthSec"), value: $editingConfig.secondHandWidth, range: 0.5...5, step: 0.5)

        Divider()

        // 中心点
        colorRow(label: L10n.shared.tr("editor.centerOuter"), color: Binding(
            get: { editingConfig.centerDotOuterColor.swiftUIColor },
            set: { editingConfig.centerDotOuterColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.centerInner"), color: Binding(
            get: { editingConfig.centerDotInnerColor.swiftUIColor },
            set: { editingConfig.centerDotInnerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 刻度与数字
        HStack {
            Toggle(L10n.shared.tr("editor.showTicks"), isOn: $editingConfig.hasTickMarks)
                .font(.system(size: 12))
            Toggle(L10n.shared.tr("editor.showNumbers"), isOn: $editingConfig.showNumbers)
                .font(.system(size: 12))
            Toggle(L10n.shared.tr("editor.showDeco"), isOn: $editingConfig.hasDialDecoration)
                .font(.system(size: 12))
        }
        colorRow(label: L10n.shared.tr("editor.tickColor"), color: Binding(
            get: { editingConfig.tickMarkColor.swiftUIColor },
            set: { editingConfig.tickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.majorTickColor"), color: Binding(
            get: { editingConfig.majorTickMarkColor.swiftUIColor },
            set: { editingConfig.majorTickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.numberColor"), color: Binding(
            get: { editingConfig.numberColor.swiftUIColor },
            set: { editingConfig.numberColor = CodableColor(color: $0) }
        ))
        pickerRow(label: L10n.shared.tr("editor.numberStyle"), selection: $editingConfig.numberStyleRaw, options: [
            ("arabic", L10n.shared.tr("editor.numArabic")), ("chinese", L10n.shared.tr("editor.numChinese"))
        ])
        pickerRow(label: L10n.shared.tr("editor.numberFont"), selection: $editingConfig.numberFontDesignRaw, options: [
            ("rounded", L10n.shared.tr("editor.fontRounded")), ("serif", L10n.shared.tr("editor.fontSerif")), ("monospaced", L10n.shared.tr("editor.fontMono")), ("default", L10n.shared.tr("editor.fontDefault"))
        ])

        Divider()

        // 下拉面板颜色
        colorRow(label: L10n.shared.tr("editor.dropBg"), color: Binding(
            get: { editingConfig.dropdownBgColor.swiftUIColor },
            set: { editingConfig.dropdownBgColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.dropText"), color: Binding(
            get: { editingConfig.dropdownTextColor.swiftUIColor },
            set: { editingConfig.dropdownTextColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.dropSubtext"), color: Binding(
            get: { editingConfig.dropdownSubtextColor.swiftUIColor },
            set: { editingConfig.dropdownSubtextColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.dropBorder"), color: Binding(
            get: { editingConfig.dropdownBorderColor.swiftUIColor },
            set: { editingConfig.dropdownBorderColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.dropDivider"), color: Binding(
            get: { editingConfig.dropdownDividerColor.swiftUIColor },
            set: { editingConfig.dropdownDividerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 叠加文字颜色
        colorRow(label: L10n.shared.tr("editor.overlayPrimary"), color: Binding(
            get: { editingConfig.textPrimaryColor.swiftUIColor },
            set: { editingConfig.textPrimaryColor = CodableColor(color: $0) }
        ))
        colorRow(label: L10n.shared.tr("editor.overlaySecondary"), color: Binding(
            get: { editingConfig.textSecondaryColor.swiftUIColor },
            set: { editingConfig.textSecondaryColor = CodableColor(color: $0) }
        ))
    }

    private func colorRow(label: String, color: Binding<Color>) -> some View {
        let isExpanded = expandedColorRow == label
        let nsColor = NSColor(color.wrappedValue)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .frame(width: 80, alignment: .leading)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedColorRow = isExpanded ? nil : label
                    }
                }) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.wrappedValue)
                        .frame(width: 32, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .frame(height: 24)

            if isExpanded {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        colorSlider(label: "R", value: .init(
                            get: { Double(r) },
                            set: { newR in color.wrappedValue = Color(red: newR, green: Double(g), blue: Double(b)).opacity(Double(a)) }
                        ), tint: .red)
                        colorSlider(label: "G", value: .init(
                            get: { Double(g) },
                            set: { newG in color.wrappedValue = Color(red: Double(r), green: newG, blue: Double(b)).opacity(Double(a)) }
                        ), tint: .green)
                        colorSlider(label: "B", value: .init(
                            get: { Double(b) },
                            set: { newB in color.wrappedValue = Color(red: Double(r), green: Double(g), blue: newB).opacity(Double(a)) }
                        ), tint: .blue)
                    }
                    HStack(spacing: 8) {
                        Text("A")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .frame(width: 12)
                        Slider(value: .init(
                            get: { Double(a) },
                            set: { newA in color.wrappedValue = Color(red: Double(r), green: Double(g), blue: Double(b)).opacity(newA) }
                        ), in: 0...1)
                        Text(String(format: "%.0f%%", a * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                    }
                    .frame(height: 18)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private func colorSlider(label: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 12)
            Slider(value: value, in: 0...1)
                .tint(tint)
            Text(String(format: "%.0f", value.wrappedValue * 255))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func sliderRow(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 24)
    }

    private func pickerRow(label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 80, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { key, title in
                    Text(title).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selection.wrappedValue) { _ in saveCustomTheme() }
            Spacer()
        }
        .frame(height: 24)
    }

    private func loadCustomTheme() {
        // 从 viewModel 加载已保存主题，编辑状态在点击新建时初始化
    }

    private func saveCustomTheme() {
        // 自定义主题在编辑过程中通过 editingConfig.save() 实时保存到 UserDefaults
        // 最终保存通过 viewModel.saveNewCustomTheme() 完成
    }

    // MARK: - Actions

    private func loadCurrentPaths() {
        openclawPath = UserDefaults.standard.string(for: .openclawPath) ?? ""
        claudeCodePath = UserDefaults.standard.string(for: .claudeCodePath) ?? ""
        geminiPath = UserDefaults.standard.string(for: .geminiPath) ?? ""
        codexPath = UserDefaults.standard.string(for: .codexPath) ?? ""
        hermesPath = UserDefaults.standard.string(for: .hermesPath) ?? ""
        opencodePath = UserDefaults.standard.string(for: .opencodePath) ?? ""
        qwenPath = UserDefaults.standard.string(for: .qwenPath) ?? ""
        copilotPath = UserDefaults.standard.string(for: .copilotPath) ?? ""
        grokPath = UserDefaults.standard.string(for: .grokPath) ?? ""
        aiderPath = UserDefaults.standard.string(for: .aiderPath) ?? ""
        antigravityPath = UserDefaults.standard.string(for: .antigravityPath) ?? ""
        clinePath = UserDefaults.standard.string(for: .clinePath) ?? ""
        continuePath = UserDefaults.standard.string(for: .continuePath) ?? ""
        cursorAgentPath = UserDefaults.standard.string(for: .cursorAgentPath) ?? ""
    }

    private func savePaths() {
        setPath(.openclawPath, openclawPath)
        setPath(.claudeCodePath, claudeCodePath)
        setPath(.geminiPath, geminiPath)
        setPath(.codexPath, codexPath)
        setPath(.hermesPath, hermesPath)
        setPath(.opencodePath, opencodePath)
        setPath(.qwenPath, qwenPath)
        setPath(.copilotPath, copilotPath)
        setPath(.grokPath, grokPath)
        setPath(.aiderPath, aiderPath)
        setPath(.antigravityPath, antigravityPath)
        setPath(.clinePath, clinePath)
        setPath(.continuePath, continuePath)
        setPath(.cursorAgentPath, cursorAgentPath)
    }

    private func setPath(_ key: SettingsKey, _ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        } else {
            UserDefaults.standard.set(value, forKey: key.rawValue)
        }
    }

    /// 运行自动探测并更新 UI
    private func runAutoDetection() {
        let summary = PathDetector.runFullDetection()
        detectResults = summary.results

        // 强制更新所有探测到的路径
        for result in summary.results where result.exists {
            switch result.service {
            case "openclaw": openclawPath = result.detectedPath
            case "claudeCode": claudeCodePath = result.detectedPath
            case "gemini": geminiPath = result.detectedPath
            case "codex": codexPath = result.detectedPath
            case "hermes": hermesPath = result.detectedPath
            case "opencode": opencodePath = result.detectedPath
            case "qwen": qwenPath = result.detectedPath
            case "copilot": copilotPath = result.detectedPath
            case "grok": grokPath = result.detectedPath
            case "aider": aiderPath = result.detectedPath
            case "antigravity": antigravityPath = result.detectedPath
            case "cline": clinePath = result.detectedPath
            case "continue": continuePath = result.detectedPath
            case "cursorAgent": cursorAgentPath = result.detectedPath
            default: break
            }
        }

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if summary.allFound {
            detectionSummary = String(format: L10n.shared.tr("settings.detectAllFound"), summary.totalCount, timeStr)
        } else {
            detectionSummary = String(format: L10n.shared.tr("settings.detectPartial"), summary.foundCount, summary.totalCount, timeStr)
        }

        savePaths()
    }

    private func detectPath(for service: String) {
        let summary = PathDetector.runFullDetection()
        detectResults = summary.results

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let toolLabels: [String: (emoji: String, name: String)] = [
            "openclaw":   ("🦞", "OpenClaw"),
            "claudeCode": ("✳️", "Claude Code"),
            "gemini":     ("✨", "Gemini CLI"),
            "codex":      ("🤖", "Codex"),
            "hermes":     ("⚕️", "Hermes"),
            "opencode":   ("🐙", "OpenCode"),
            "qwen":       ("🟣", "Qwen Code"),
            "copilot":    ("🐙", "Copilot"),
            "grok":       ("⚡", "Grok"),
            "aider":      ("🤝", "Aider"),
            "antigravity":("🛡️", "Antigravity"),
            "cline":      ("🤖", "Cline"),
            "continue":   ("▶️", "Continue"),
            "cursorAgent":("🖱️", "Cursor Agent"),
        ]
        let label = toolLabels[service] ?? ("", service)

        if let result = summary.results.first(where: { $0.service == service }) {
            if result.exists {
                switch service {
                case "openclaw": openclawPath = result.detectedPath
                case "claudeCode": claudeCodePath = result.detectedPath
                case "gemini": geminiPath = result.detectedPath
                case "codex": codexPath = result.detectedPath
                case "hermes": hermesPath = result.detectedPath
                case "opencode": opencodePath = result.detectedPath
                case "qwen": qwenPath = result.detectedPath
                case "copilot": copilotPath = result.detectedPath
                case "grok": grokPath = result.detectedPath
                case "aider": aiderPath = result.detectedPath
                case "antigravity": antigravityPath = result.detectedPath
                case "cline": clinePath = result.detectedPath
                case "continue": continuePath = result.detectedPath
                case "cursorAgent": cursorAgentPath = result.detectedPath
                default: break
                }
                detectionSummary = String(format: L10n.shared.tr("settings.detectUpdated"), label.emoji, label.name, timeStr)
            } else {
                detectionSummary = String(format: L10n.shared.tr("settings.detectNotFound"), label.emoji, label.name)
            }
            savePaths()
        }
    }

    /// 检查指定路径下是否有有效的日志文件
    private func hasValidLogFiles(service: String, basePath: String) -> Bool {
        switch service {
        case "openclaw":
            return PathDetector.findJSONLFiles(in: basePath, subpath: "agents", recursive: true)
        case "claudeCode":
            return PathDetector.findJSONLFiles(in: basePath, subpath: "projects", recursive: true)
        case "gemini":
            return PathDetector.findJSONFiles(in: basePath, subpath: "tmp", recursive: true)
        case "codex":
            return PathDetector.findRolloutJSONLFiles(in: basePath, subpath: "sessions")
        case "hermes":
            let dbPath = basePath + "/state.db"
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dbPath, isDirectory: &isDir) && !isDir.boolValue
        case "opencode":
            let dbPath = basePath + "/opencode.db"
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dbPath, isDirectory: &isDir) && !isDir.boolValue
        case "qwen":
            return PathDetector.findJSONLFiles(in: basePath, subpath: "projects", recursive: true)
        case "copilot":
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return (fm.fileExists(atPath: basePath + "/otel", isDirectory: &isDir) && isDir.boolValue)
                || (fm.fileExists(atPath: basePath + "/session-state", isDirectory: &isDir) && isDir.boolValue)
        case "grok":
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: basePath + "/sessions", isDirectory: &isDir) && isDir.boolValue
        case "aider":
            return PathDetector.findJSONLFiles(in: basePath)
        case "antigravity":
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: basePath + "/conversations", isDirectory: &isDir) && isDir.boolValue
        case "cline":
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: basePath + "/tasks", isDirectory: &isDir) && isDir.boolValue
        case "continue":
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return (fm.fileExists(atPath: basePath + "/dev_data", isDirectory: &isDir) && isDir.boolValue)
                || (fm.fileExists(atPath: basePath + "/sessions", isDirectory: &isDir) && isDir.boolValue)
        case "cursorAgent":
            let fm = FileManager.default
            return fm.fileExists(atPath: basePath + "/hooks/log-token-usage.sh")
                || fm.fileExists(atPath: basePath + "/token-usage.jsonl")
                || fm.fileExists(atPath: basePath + "/cli-config.json")
        default:
            return false
        }
    }

    private func browseForPath(service: String, currentPath: String, title: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "选择"

        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        // 确保应用处于激活状态，否则 NSOpenPanel 会立即关闭
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let selectedPath = url.path
        switch service {
        case "openclaw": openclawPath = selectedPath
        case "claudeCode": claudeCodePath = selectedPath
        case "gemini": geminiPath = selectedPath
        case "codex": codexPath = selectedPath
        case "hermes": hermesPath = selectedPath
        case "opencode": opencodePath = selectedPath
        case "qwen": qwenPath = selectedPath
        case "copilot": copilotPath = selectedPath
        case "grok": grokPath = selectedPath
        case "aider": aiderPath = selectedPath
        case "antigravity": antigravityPath = selectedPath
        case "cline": clinePath = selectedPath
        case "continue": continuePath = selectedPath
        case "cursorAgent": cursorAgentPath = selectedPath
        default: break
        }
        savePaths()

        // 重新检测当前服务
        let exists = hasValidLogFiles(service: service, basePath: selectedPath)
        detectResults.removeAll { $0.service == service }
        detectResults.append(PathDetector.DetectionResult(
            service: service, emoji: "",
            detectedPath: exists ? selectedPath : "",
            isDefault: false, exists: exists,
            source: exists ? .userDefaults : .notFound,
            detail: exists ? L10n.shared.tr("settings.pathValid") : L10n.shared.tr("settings.pathInvalid")
        ))
    }
}
