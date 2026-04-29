import Foundation

/// 自动检索本地环境中各数据源的正确日志路径
enum PathDetector {
    struct DetectionResult {
        let service: String
        let emoji: String
        let detectedPath: String
        let isDefault: Bool
        let exists: Bool
    }

    /// 自动检测所有数据源路径
    static func detectAll() -> [DetectionResult] {
        var results: [DetectionResult] = []
        results.append(detectOpenClaw())
        results.append(detectClaudeCode())
        results.append(detectGemini())
        results.append(detectCodex())
        results.append(detectHermes())
        return results
    }

    // MARK: - 逐项检测（以存在有效日志文件为准）

    private static func detectOpenClaw() -> DetectionResult {
        let ocCustom = UserDefaults.standard.string(forKey: "TC_openclawPath")
        let basePath = ocCustom ?? PathConfig.defaultOpenclawHome()
        // 检查 ~/.openclaw/agents/*/sessions/ 下是否有 .jsonl 文件
        let hasFiles = findJSONLFiles(in: basePath, subpath: "agents", recursive: true)
        return DetectionResult(
            service: "openclaw", emoji: "⚡",
            detectedPath: hasFiles ? basePath : "",
            isDefault: ocCustom == nil, exists: hasFiles
        )
    }

    private static func detectClaudeCode() -> DetectionResult {
        let ccCustom = UserDefaults.standard.string(forKey: "TC_claudeCodePath")
        let basePath = ccCustom ?? PathConfig.defaultClaudeCodeHome()
        // 检查 ~/.claude/projects/ 下是否有 .jsonl 文件
        let hasFiles = findJSONLFiles(in: basePath, subpath: "projects", recursive: true)
        return DetectionResult(
            service: "claudeCode", emoji: "🧠",
            detectedPath: hasFiles ? basePath : "",
            isDefault: ccCustom == nil, exists: hasFiles
        )
    }

    private static func detectGemini() -> DetectionResult {
        let gemCustom = UserDefaults.standard.string(forKey: "TC_geminiPath")
        let basePath = gemCustom ?? PathConfig.defaultGeminiHome()
        // 检查 ~/.gemini/tmp/*/chats/ 下是否有 .json 文件
        let hasFiles = findJSONFiles(in: basePath, subpath: "tmp", recursive: true)
        return DetectionResult(
            service: "gemini", emoji: "💎",
            detectedPath: hasFiles ? basePath : "",
            isDefault: gemCustom == nil, exists: hasFiles
        )
    }

    private static func detectCodex() -> DetectionResult {
        let cxCustom = UserDefaults.standard.string(forKey: "TC_codexPath")
        let basePath = cxCustom ?? PathConfig.defaultCodexHome()
        // 新版 Codex 按 YYYY/MM/DD 分层，递归查找 rollout-*.jsonl
        let hasFiles = findRolloutJSONLFiles(in: basePath, subpath: "sessions")
        return DetectionResult(
            service: "codex", emoji: "🤖",
            detectedPath: hasFiles ? basePath : "",
            isDefault: cxCustom == nil, exists: hasFiles
        )
    }

    private static func detectHermes() -> DetectionResult {
        let hermesCustom = UserDefaults.standard.string(forKey: "TC_hermesPath")
        let basePath = hermesCustom ?? PathConfig.defaultHermesHome()
        // 检查 ~/.openclaw-hermes/agents/main/sessions/ 下是否有 .jsonl 文件
        let hasFiles = findJSONLFiles(in: basePath, subpath: "agents/main/sessions", recursive: true)
        return DetectionResult(
            service: "hermes", emoji: "🏔️",
            detectedPath: hasFiles ? basePath : "",
            isDefault: hermesCustom == nil, exists: hasFiles
        )
    }

    // MARK: - 文件搜索工具

    /// 在 basePath/subpath 下递归查找 .jsonl 文件（找到即返回 true）
    static func findJSONLFiles(in basePath: String, subpath: String? = nil, recursive: Bool = false) -> Bool {
        let searchDir = subpath != nil ? basePath + "/" + subpath! : basePath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: searchDir, isDirectory: &isDir), isDir.boolValue else { return false }

        guard let contents = try? fm.contentsOfDirectory(atPath: searchDir) else { return false }
        for item in contents {
            let fullPath = searchDir + "/" + item
            if item.hasSuffix(".jsonl") {
                var fIsDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), !fIsDir.boolValue {
                    return true
                }
            }
            if recursive {
                var fIsDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), fIsDir.boolValue {
                    if findJSONLFiles(in: fullPath) { return true }
                }
            }
        }
        return false
    }

    /// 在 basePath/subpath 下递归查找 .json 文件
    static func findJSONFiles(in basePath: String, subpath: String? = nil, recursive: Bool = false) -> Bool {
        let searchDir = subpath != nil ? basePath + "/" + subpath! : basePath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: searchDir, isDirectory: &isDir), isDir.boolValue else { return false }

        guard let contents = try? fm.contentsOfDirectory(atPath: searchDir) else { return false }
        for item in contents {
            let fullPath = searchDir + "/" + item
            if item.hasSuffix(".json") {
                var fIsDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), !fIsDir.boolValue {
                    return true
                }
            }
            if recursive {
                var fIsDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), fIsDir.boolValue {
                    if findJSONFiles(in: fullPath) { return true }
                }
            }
        }
        return false
    }

    /// 在 basePath/subpath 下递归查找 rollout-*.jsonl 文件（Codex 专用，新版按日期分层）
    static func findRolloutJSONLFiles(in basePath: String, subpath: String) -> Bool {
        let searchDir = basePath + "/" + subpath
        return findRolloutJSONLRecursive(in: searchDir)
    }

    /// 递归查找 rollout-*.jsonl
    private static func findRolloutJSONLRecursive(in dir: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        for item in contents {
            let fullPath = dir + "/" + item
            var fIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &fIsDir) else { continue }
            if fIsDir.boolValue {
                if findRolloutJSONLRecursive(in: fullPath) { return true }
            } else if item.hasPrefix("rollout-") && item.hasSuffix(".jsonl") {
                return true
            }
        }
        return false
    }

    // MARK: - SSH

    /// 检查 SSH config 中是否有指定 host
    static func checkSSHConfig(for host: String) -> Bool {
        guard let sshConfigPath = NSHomeDirectory() + "/.ssh/config" as String?,
              let content = try? String(contentsOfFile: sshConfigPath, encoding: .utf8) else {
            return false
        }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("host ") {
                let hostName = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if hostName == host || hostName == "*" {
                    return true
                }
            }
        }
        return false
    }
}
