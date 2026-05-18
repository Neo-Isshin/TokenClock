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
    @State private var expandedColorRow: String? = nil

    // MARK: - 折叠状态
    @State private var pathsExpanded = false
    @State private var rateThresholdExpanded = false
    @State private var customThemeExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("TokenClock 设置")
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

                    // 数据源路径
                    collapsibleSection(title: "📁 数据源路径", isExpanded: $pathsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            pathRow(
                                emoji: "🦞", name: "OpenClaw",
                                path: $openclawPath,
                                service: "openclaw",
                                browseTitle: "选择 OpenClaw 目录"
                            )

                            pathRow(
                                emoji: "✳️", name: "Claude Code",
                                path: $claudeCodePath,
                                service: "claudeCode",
                                browseTitle: "选择 Claude Code 目录"
                            )

                            pathRow(
                                emoji: "✨", name: "Gemini CLI",
                                path: $geminiPath,
                                service: "gemini",
                                browseTitle: "选择 Gemini CLI 目录"
                            )

                            pathRow(
                                emoji: "🤖", name: "Codex",
                                path: $codexPath,
                                service: "codex",
                                browseTitle: "选择 Codex 目录"
                            )

                            hermesPathRow()
                            hintText()
                        }
                    }

                    // 热力图标阈值
                    collapsibleSection(title: "🔥 热力图标阈值", isExpanded: $rateThresholdExpanded) {
                        rateThresholdSection()
                    }

                    // 自定义表盘
                    collapsibleSection(title: "🎨 自定义表盘", isExpanded: $customThemeExpanded) {
                        customThemeSection()
                    }
                }
                .padding(20)
            }

            Divider()

            // 底部按钮
            HStack {
                Spacer()
                Button("完成") {
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
                Text("🔍 自动探测")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("重新探测") {
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
                TextField("默认路径", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)

                // 检索按钮
                Button("检索") {
                    detectPath(for: service)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))

                // 浏览按钮
                Button("浏览") {
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
                TextField("默认路径", text: $hermesPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)

                Button("检索") {
                    detectPath(for: "hermes")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))

                Button("浏览") {
                    browseForPath(service: "hermes", currentPath: hermesPath, title: "选择 Hermes 目录")
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
                Text("留空则使用默认路径。修改路径后需重启应用生效。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                Text("支持环境变量覆盖：OPENCLAW_HOME、CLAUDE_CONFIG_DIR、GEMINI_HOME、CODEX_HOME、HERMES_HOME")
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
                Text("统计周期")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Picker("", selection: $rateWindow) {
                    Text("10分钟").tag(10)
                    Text("30分钟").tag(30)
                    Text("1小时").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: rateWindow) {
                    saveRateSettings()
                }
                Spacer()
            }

            Divider()

            // 阈值输入行
            thresholdRow(emoji: "💥", label: "爆发", value: $burstValue, unit: $burstUnit)
            thresholdRow(emoji: "🔥", label: "火热", value: $hotValue, unit: $hotUnit)
            thresholdRow(emoji: "🏃‍♂️", label: "活跃", value: $activeValue, unit: $activeUnit)
            thresholdRow(emoji: "☕", label: "悠闲", value: $calmValue, unit: $calmUnit)

            Text("🛌 休息：低于悠闲阈值")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 2)

            if !rateThresholdsValid {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("阈值已自动调整为递减顺序")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                .padding(.top, 2)
            }
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

            TextField("数值", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 80)
                .onSubmit { saveRateSettings() }

            Picker("", selection: unit) {
                ForEach(rateUnits, id: \.self) { u in
                    Text(u.isEmpty ? "—" : u).tag(u)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .onChange(of: unit.wrappedValue) {
                saveRateSettings()
            }

            Text("以上")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - 阈值读写

    private func loadRateSettings() {
        let burst = UserDefaults.standard.integer(forKey: "TC_rateBurst")
        let hot = UserDefaults.standard.integer(forKey: "TC_rateHot")
        let active = UserDefaults.standard.integer(forKey: "TC_rateActive")
        let calm = UserDefaults.standard.integer(forKey: "TC_rateCalm")
        let window = UserDefaults.standard.integer(forKey: "TC_rateWindow")

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

        UserDefaults.standard.set(b, forKey: "TC_rateBurst")
        UserDefaults.standard.set(h, forKey: "TC_rateHot")
        UserDefaults.standard.set(a, forKey: "TC_rateActive")
        UserDefaults.standard.set(c, forKey: "TC_rateCalm")
        UserDefaults.standard.set(rateWindow, forKey: "TC_rateWindow")

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
                    Text("已保存的表盘")
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

                            Button("应用") {
                                viewModel.applyCustomTheme(id: theme.id)
                                viewModel.selectedTheme = .custom
                                viewModel.saveTheme()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.system(size: 11))

                            Button("删除") {
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
                        Label("新建自定义表盘", systemImage: "paintbrush.pointed.fill")
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
                        Text("编辑中 — 表盘实时预览")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("取消") {
                            cancelEditingCustomTheme()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11))

                        Button("保存") {
                            saveEditingCustomTheme()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .disabled(editingThemeName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    TextField("输入表盘名称", text: $editingThemeName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    customThemeEditor()
                        .onChange(of: editingConfig) {
                            editingConfig.save()
                        }
                }
            }
        }
    }

    private func startEditingCustomTheme() {
        themeBeforeEdit = viewModel.selectedTheme
        editingConfig = CustomThemeConfig.load()
        editingThemeName = ""
        isEditingCustomTheme = true
        viewModel.selectedTheme = .custom
        editingConfig.save()
    }

    private func cancelEditingCustomTheme() {
        isEditingCustomTheme = false
        viewModel.selectedTheme = themeBeforeEdit
        viewModel.saveTheme()
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
        colorRow(label: "表盘底色", color: Binding(
            get: { editingConfig.dialColor.swiftUIColor },
            set: { editingConfig.dialColor = CodableColor(color: $0) }
        ))
        colorRow(label: "表盘边框", color: Binding(
            get: { editingConfig.dialRimColor.swiftUIColor },
            set: { editingConfig.dialRimColor = CodableColor(color: $0) }
        ))
        sliderRow(label: "边框宽度", value: $editingConfig.dialRimWidth, range: 0...20, step: 0.5)

        Divider()

        // 指针颜色
        colorRow(label: "时针颜色", color: Binding(
            get: { editingConfig.hourHandColor.swiftUIColor },
            set: { editingConfig.hourHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: "分针颜色", color: Binding(
            get: { editingConfig.minuteHandColor.swiftUIColor },
            set: { editingConfig.minuteHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: "秒针颜色", color: Binding(
            get: { editingConfig.secondHandColor.swiftUIColor },
            set: { editingConfig.secondHandColor = CodableColor(color: $0) }
        ))

        // 指针样式
        pickerRow(label: "指针样式", selection: $editingConfig.handStyleRaw, options: [
            ("round", "圆形"), ("tapered", "锥形"), ("lance", "枪尖"), ("sword", "剑形")
        ])

        // 指针宽度
        sliderRow(label: "时针宽度", value: $editingConfig.hourHandWidth, range: 1...10, step: 0.5)
        sliderRow(label: "分针宽度", value: $editingConfig.minuteHandWidth, range: 1...8, step: 0.5)
        sliderRow(label: "秒针宽度", value: $editingConfig.secondHandWidth, range: 0.5...5, step: 0.5)

        Divider()

        // 中心点
        colorRow(label: "中心外圈", color: Binding(
            get: { editingConfig.centerDotOuterColor.swiftUIColor },
            set: { editingConfig.centerDotOuterColor = CodableColor(color: $0) }
        ))
        colorRow(label: "中心内圈", color: Binding(
            get: { editingConfig.centerDotInnerColor.swiftUIColor },
            set: { editingConfig.centerDotInnerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 刻度与数字
        HStack {
            Toggle("显示刻度", isOn: $editingConfig.hasTickMarks)
                .font(.system(size: 12))
            Toggle("显示数字", isOn: $editingConfig.showNumbers)
                .font(.system(size: 12))
            Toggle("表盘装饰", isOn: $editingConfig.hasDialDecoration)
                .font(.system(size: 12))
        }
        colorRow(label: "刻度颜色", color: Binding(
            get: { editingConfig.tickMarkColor.swiftUIColor },
            set: { editingConfig.tickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: "主刻度颜色", color: Binding(
            get: { editingConfig.majorTickMarkColor.swiftUIColor },
            set: { editingConfig.majorTickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: "数字颜色", color: Binding(
            get: { editingConfig.numberColor.swiftUIColor },
            set: { editingConfig.numberColor = CodableColor(color: $0) }
        ))
        pickerRow(label: "数字样式", selection: $editingConfig.numberStyleRaw, options: [
            ("arabic", "阿拉伯数字"), ("chinese", "中文数字")
        ])
        pickerRow(label: "数字字体", selection: $editingConfig.numberFontDesignRaw, options: [
            ("rounded", "圆体"), ("serif", "衬线"), ("monospaced", "等宽"), ("default", "默认")
        ])

        Divider()

        // 下拉面板颜色
        colorRow(label: "面板背景", color: Binding(
            get: { editingConfig.dropdownBgColor.swiftUIColor },
            set: { editingConfig.dropdownBgColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板文字", color: Binding(
            get: { editingConfig.dropdownTextColor.swiftUIColor },
            set: { editingConfig.dropdownTextColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板副文字", color: Binding(
            get: { editingConfig.dropdownSubtextColor.swiftUIColor },
            set: { editingConfig.dropdownSubtextColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板边框", color: Binding(
            get: { editingConfig.dropdownBorderColor.swiftUIColor },
            set: { editingConfig.dropdownBorderColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板分割线", color: Binding(
            get: { editingConfig.dropdownDividerColor.swiftUIColor },
            set: { editingConfig.dropdownDividerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 叠加文字颜色
        colorRow(label: "主文字颜色", color: Binding(
            get: { editingConfig.textPrimaryColor.swiftUIColor },
            set: { editingConfig.textPrimaryColor = CodableColor(color: $0) }
        ))
        colorRow(label: "副文字颜色", color: Binding(
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
            .onChange(of: selection.wrappedValue) { saveCustomTheme() }
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
        openclawPath = UserDefaults.standard.string(forKey: "TC_openclawPath") ?? ""
        claudeCodePath = UserDefaults.standard.string(forKey: "TC_claudeCodePath") ?? ""
        geminiPath = UserDefaults.standard.string(forKey: "TC_geminiPath") ?? ""
        codexPath = UserDefaults.standard.string(forKey: "TC_codexPath") ?? ""
        hermesPath = UserDefaults.standard.string(forKey: "TC_hermesPath") ?? ""
    }

    private func savePaths() {
        setPath("TC_openclawPath", openclawPath)
        setPath("TC_claudeCodePath", claudeCodePath)
        setPath("TC_geminiPath", geminiPath)
        setPath("TC_codexPath", codexPath)
        setPath("TC_hermesPath", hermesPath)
    }

    private func setPath(_ key: String, _ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
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
            default: break
            }
        }

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if summary.allFound {
            detectionSummary = "✅ 已探测到全部 \(summary.totalCount) 个数据源（\(timeStr)）"
        } else {
            detectionSummary = "⚠️ 已探测到 \(summary.foundCount)/\(summary.totalCount) 个数据源（\(timeStr)）"
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
                default: break
                }
                detectionSummary = "✅ \(label.emoji) \(label.name) 路径已更新（\(timeStr)）"
            } else {
                detectionSummary = "❌ \(label.emoji) \(label.name) 未找到有效数据目录"
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
            detail: exists ? "用户自定义路径有效" : "所选路径未找到有效日志文件"
        ))
    }
}
