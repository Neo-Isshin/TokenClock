import SwiftUI
import AppKit

/// 设置窗口主视图
struct SettingsView: View {
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

    // MARK: - 自定义主题
    @State private var customConfig = CustomThemeConfig()
    @State private var showCustomTheme = false
    @State private var newThemeName: String = ""
    @State private var savedThemes: [SavedCustomTheme] = []

    // MARK: - 折叠状态
    @State private var autoDetectExpanded = false
    @State private var pathsExpanded = true
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
                    // 自动探测
                    collapsibleSection(title: "🔍 自动探测", isExpanded: $autoDetectExpanded) {
                        autoDetectSection()
                    }

                    // 数据源路径
                    collapsibleSection(title: "📁 数据源路径", isExpanded: $pathsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            pathRow(
                                emoji: "⚡", name: "OpenClaw",
                                path: $openclawPath,
                                service: "openclaw",
                                browseTitle: "选择 OpenClaw 目录"
                            )

                            pathRow(
                                emoji: "🧠", name: "Claude Code",
                                path: $claudeCodePath,
                                service: "claudeCode",
                                browseTitle: "选择 Claude Code 目录"
                            )

                            pathRow(
                                emoji: "💎", name: "Gemini CLI",
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
            loadCustomTheme()
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
            Text("🏔️ Hermes")
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
            HStack {
                Toggle("启用自定义表盘", isOn: $showCustomTheme)
                    .font(.system(size: 12))
                    .onChange(of: showCustomTheme) {
                        if showCustomTheme {
                            saveCustomTheme()
                        }
                    }
                Spacer()
                Button("重置默认") {
                    customConfig = CustomThemeConfig()
                    saveCustomTheme()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }

            if showCustomTheme {
                // 保存为新表盘
                HStack(spacing: 8) {
                    TextField("输入表盘名称", text: $newThemeName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Button("保存为新表盘") {
                        guard !newThemeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let newTheme = SavedCustomTheme(
                            name: newThemeName.trimmingCharacters(in: .whitespaces),
                            config: customConfig
                        )
                        savedThemes.append(newTheme)
                        SavedCustomTheme.saveAll(savedThemes)
                        newThemeName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .disabled(newThemeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // 已保存表盘列表
                if !savedThemes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已保存的表盘")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

                        ForEach(savedThemes) { theme in
                            HStack(spacing: 8) {
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)

                                Text(theme.name)
                                    .font(.system(size: 12))

                                Spacer()

                                Button("应用") {
                                    customConfig = theme.config
                                    saveCustomTheme()
                                    // 通知外部应用此自定义主题
                                    NotificationCenter.default.post(
                                        name: .customThemeApplied,
                                        object: theme.id
                                    )
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .font(.system(size: 11))

                                Button("删除") {
                                    savedThemes.removeAll { $0.id == theme.id }
                                    SavedCustomTheme.saveAll(savedThemes)
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

                customThemeEditor()
                    .onChange(of: customConfig) {
                        saveCustomTheme()
                    }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func customThemeEditor() -> some View {
        // 表盘
        colorRow(label: "表盘底色", color: Binding(
            get: { customConfig.dialColor.swiftUIColor },
            set: { customConfig.dialColor = CodableColor(color: $0) }
        ))
        colorRow(label: "表盘边框", color: Binding(
            get: { customConfig.dialRimColor.swiftUIColor },
            set: { customConfig.dialRimColor = CodableColor(color: $0) }
        ))
        sliderRow(label: "边框宽度", value: $customConfig.dialRimWidth, range: 0...20, step: 0.5)

        Divider()

        // 指针颜色
        colorRow(label: "时针颜色", color: Binding(
            get: { customConfig.hourHandColor.swiftUIColor },
            set: { customConfig.hourHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: "分针颜色", color: Binding(
            get: { customConfig.minuteHandColor.swiftUIColor },
            set: { customConfig.minuteHandColor = CodableColor(color: $0) }
        ))
        colorRow(label: "秒针颜色", color: Binding(
            get: { customConfig.secondHandColor.swiftUIColor },
            set: { customConfig.secondHandColor = CodableColor(color: $0) }
        ))

        // 指针样式
        pickerRow(label: "指针样式", selection: $customConfig.handStyleRaw, options: [
            ("round", "圆形"), ("tapered", "锥形"), ("lance", "枪尖"), ("sword", "剑形")
        ])

        // 指针宽度
        sliderRow(label: "时针宽度", value: $customConfig.hourHandWidth, range: 1...10, step: 0.5)
        sliderRow(label: "分针宽度", value: $customConfig.minuteHandWidth, range: 1...8, step: 0.5)
        sliderRow(label: "秒针宽度", value: $customConfig.secondHandWidth, range: 0.5...5, step: 0.5)

        Divider()

        // 中心点
        colorRow(label: "中心外圈", color: Binding(
            get: { customConfig.centerDotOuterColor.swiftUIColor },
            set: { customConfig.centerDotOuterColor = CodableColor(color: $0) }
        ))
        colorRow(label: "中心内圈", color: Binding(
            get: { customConfig.centerDotInnerColor.swiftUIColor },
            set: { customConfig.centerDotInnerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 刻度与数字
        HStack {
            Toggle("显示刻度", isOn: $customConfig.hasTickMarks)
                .font(.system(size: 12))
            Toggle("显示数字", isOn: $customConfig.showNumbers)
                .font(.system(size: 12))
            Toggle("表盘装饰", isOn: $customConfig.hasDialDecoration)
                .font(.system(size: 12))
        }
        colorRow(label: "刻度颜色", color: Binding(
            get: { customConfig.tickMarkColor.swiftUIColor },
            set: { customConfig.tickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: "主刻度颜色", color: Binding(
            get: { customConfig.majorTickMarkColor.swiftUIColor },
            set: { customConfig.majorTickMarkColor = CodableColor(color: $0) }
        ))
        colorRow(label: "数字颜色", color: Binding(
            get: { customConfig.numberColor.swiftUIColor },
            set: { customConfig.numberColor = CodableColor(color: $0) }
        ))
        pickerRow(label: "数字样式", selection: $customConfig.numberStyleRaw, options: [
            ("arabic", "阿拉伯数字"), ("chinese", "中文数字")
        ])
        pickerRow(label: "数字字体", selection: $customConfig.numberFontDesignRaw, options: [
            ("rounded", "圆体"), ("serif", "衬线"), ("monospaced", "等宽"), ("default", "默认")
        ])

        Divider()

        // 下拉面板颜色
        colorRow(label: "面板背景", color: Binding(
            get: { customConfig.dropdownBgColor.swiftUIColor },
            set: { customConfig.dropdownBgColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板文字", color: Binding(
            get: { customConfig.dropdownTextColor.swiftUIColor },
            set: { customConfig.dropdownTextColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板副文字", color: Binding(
            get: { customConfig.dropdownSubtextColor.swiftUIColor },
            set: { customConfig.dropdownSubtextColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板边框", color: Binding(
            get: { customConfig.dropdownBorderColor.swiftUIColor },
            set: { customConfig.dropdownBorderColor = CodableColor(color: $0) }
        ))
        colorRow(label: "面板分割线", color: Binding(
            get: { customConfig.dropdownDividerColor.swiftUIColor },
            set: { customConfig.dropdownDividerColor = CodableColor(color: $0) }
        ))

        Divider()

        // 叠加文字颜色
        colorRow(label: "主文字颜色", color: Binding(
            get: { customConfig.textPrimaryColor.swiftUIColor },
            set: { customConfig.textPrimaryColor = CodableColor(color: $0) }
        ))
        colorRow(label: "副文字颜色", color: Binding(
            get: { customConfig.textSecondaryColor.swiftUIColor },
            set: { customConfig.textSecondaryColor = CodableColor(color: $0) }
        ))
    }

    private func colorRow(label: String, color: Binding<Color>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 80, alignment: .leading)
            ColorPicker("", selection: color)
                .frame(width: 40)
            Spacer()
        }
        .frame(height: 24)
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
        customConfig = CustomThemeConfig.load()
        showCustomTheme = UserDefaults.standard.bool(forKey: "TC_showCustomTheme")
        savedThemes = SavedCustomTheme.loadAll()
    }

    private func saveCustomTheme() {
        customConfig.save()
        UserDefaults.standard.set(showCustomTheme, forKey: "TC_showCustomTheme")
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

        // 自动填充探测到的路径
        for result in summary.results where result.exists {
            switch result.service {
            case "openclaw":
                if openclawPath.isEmpty { openclawPath = result.detectedPath }
            case "claudeCode":
                if claudeCodePath.isEmpty { claudeCodePath = result.detectedPath }
            case "gemini":
                if geminiPath.isEmpty { geminiPath = result.detectedPath }
            case "codex":
                if codexPath.isEmpty { codexPath = result.detectedPath }
            case "hermes":
                if hermesPath.isEmpty { hermesPath = result.detectedPath }
            default:
                break
            }
        }

        if summary.allFound {
            detectionSummary = "✅ 已探测到全部 \(summary.totalCount) 个数据源"
        } else {
            detectionSummary = "⚠️ 已探测到 \(summary.foundCount)/\(summary.totalCount) 个数据源，未找到的可在下方手动配置"
        }

        // 保存探测结果到 UserDefaults
        savePaths()
    }

    private func detectPath(for service: String) {
        let summary = PathDetector.runFullDetection()
        detectResults = summary.results

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
                savePaths()
            }
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
