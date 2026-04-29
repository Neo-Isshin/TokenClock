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
                VStack(alignment: .leading, spacing: 16) {
                    // 数据源路径
                    sectionHeader("📁 数据源路径")

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

                    // Hermes (本地)
                    hermesPathRow()

                    // 提示
                    hintText()
                }
                .padding(20)
            }

            Divider()

            // 底部按钮
            HStack {
                Spacer()
                Button("完成") {
                    savePaths()
                    onDone?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 520, height: 460)
        .onAppear {
            loadCurrentPaths()
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.bottom, 4)
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
                    Text(result.exists ? "路径有效，已找到日志文件" : "未找到有效的日志文件")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
                    Text(result.exists ? "路径有效，已找到日志文件" : "未找到有效的日志文件")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Hint

    private func hintText() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
            Text("留空则使用默认路径。修改路径后需重启应用生效。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.top, 4)
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

    private func detectPath(for service: String) {
        let defaultPath: String
        var currentPath: String

        switch service {
        case "openclaw":
            defaultPath = PathConfig.defaultOpenclawHome()
            currentPath = openclawPath
        case "claudeCode":
            defaultPath = PathConfig.defaultClaudeCodeHome()
            currentPath = claudeCodePath
        case "gemini":
            defaultPath = PathConfig.defaultGeminiHome()
            currentPath = geminiPath
        case "codex":
            defaultPath = PathConfig.defaultCodexHome()
            currentPath = codexPath
        case "hermes":
            defaultPath = PathConfig.defaultHermesHome()
            currentPath = hermesPath
        default: return
        }

        let checkPath = currentPath.isEmpty ? defaultPath : currentPath
        let exists = hasValidLogFiles(service: service, basePath: checkPath)

        detectResults.removeAll { $0.service == service }
        detectResults.append(PathDetector.DetectionResult(
            service: service, emoji: "",
            detectedPath: exists ? checkPath : "",
            isDefault: currentPath.isEmpty, exists: exists
        ))

        if exists && currentPath.isEmpty {
            switch service {
            case "openclaw": openclawPath = checkPath
            case "claudeCode": claudeCodePath = checkPath
            case "gemini": geminiPath = checkPath
            case "codex": codexPath = checkPath
            case "hermes": hermesPath = checkPath
            default: break
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
            return PathDetector.findJSONLFiles(in: basePath, subpath: "agents/main/sessions", recursive: true)
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
    }
}
