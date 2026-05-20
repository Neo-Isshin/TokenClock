import Foundation

/// 自动检索本地环境中各数据源的正确日志路径
/// 支持：环境变量、官方默认路径、备选路径、用户自定义路径
enum PathDetector {
    struct DetectionResult {
        let service: String
        let emoji: String
        let detectedPath: String
        let isDefault: Bool
        let exists: Bool
        let source: PathSource
        let detail: String

        enum PathSource: String {
            case userDefaults = "pathSource.userDefaults"
            case envVariable = "pathSource.envVar"
            case officialDefault = "pathSource.official"
            case alternate = "pathSource.alternate"
            case notFound = "pathSource.notFound"
        }

        var localizedSource: String {
            L10n.shared.tr(source.rawValue)
        }
    }

    struct DetectionSummary {
        let results: [DetectionResult]
        let foundCount: Int
        let totalCount: Int
        var allFound: Bool { foundCount == totalCount }
    }

    // MARK: - 主入口：自动探测所有数据源

    /// 运行完整探测，返回摘要。首次启动时调用。
    static func runFullDetection() -> DetectionSummary {
        let results = [
            detectOpenClaw(),
            detectClaudeCode(),
            detectGemini(),
            detectCodex(),
            detectHermes(),
        ]
        let found = results.filter(\.exists).count
        return DetectionSummary(results: results, foundCount: found, totalCount: results.count)
    }

    /// 自动检测所有数据源路径（兼容旧接口）
    static func detectAll() -> [DetectionResult] {
        runFullDetection().results
    }

    // MARK: - 逐项检测

    private static func detectOpenClaw() -> DetectionResult {
        let custom = UserDefaults.standard.string(forKey: "TC_openclawPath")
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.openclawCandidates(),
            defaults: [PathConfig.defaultOpenclawHome()],
            alternates: [NSHomeDirectory() + "/Library/Logs/OpenClaw"]
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                findJSONLFiles(in: path, subpath: "agents", recursive: true)
                || findJSONLFiles(in: path, subpath: "sessions", recursive: true)
            }
        )
        return buildResult(
            service: "openclaw", emoji: "⚡",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultOpenclawHome()
        )
    }

    private static func detectClaudeCode() -> DetectionResult {
        let custom = UserDefaults.standard.string(forKey: "TC_claudeCodePath")
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.claudeCodeCandidates(),
            defaults: [PathConfig.defaultClaudeCodeHome()],
            alternates: [NSHomeDirectory() + "/Library/Application Support/Claude"]
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                // Claude Code: ~/.claude/projects/** 下有 .jsonl
                findJSONLFiles(in: path, subpath: "projects", recursive: true)
                // 或 Claude Desktop 的 session 目录
                || findJSONLFiles(in: path, subpath: "claude-code-sessions", recursive: true)
            }
        )
        return buildResult(
            service: "claudeCode", emoji: "🧠",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultClaudeCodeHome()
        )
    }

    private static func detectGemini() -> DetectionResult {
        let custom = UserDefaults.standard.string(forKey: "TC_geminiPath")
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.geminiCandidates(),
            defaults: [PathConfig.defaultGeminiHome()],
            alternates: []
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                // Gemini: ~/.gemini/tmp/*/chats/*.json
                findJSONFiles(in: path, subpath: "tmp", recursive: true)
            }
        )
        return buildResult(
            service: "gemini", emoji: "💎",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultGeminiHome()
        )
    }

    private static func detectCodex() -> DetectionResult {
        let custom = UserDefaults.standard.string(forKey: "TC_codexPath")
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.codexCandidates(),
            defaults: [PathConfig.defaultCodexHome()],
            alternates: [NSHomeDirectory() + "/.config/codex"]
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
                findRolloutJSONLFiles(in: path, subpath: "sessions")
                // 或历史格式
                || findJSONLFiles(in: path, subpath: "sessions", recursive: true)
            }
        )
        return buildResult(
            service: "codex", emoji: "🤖",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultCodexHome()
        )
    }

    private static func detectHermes() -> DetectionResult {
        let custom = UserDefaults.standard.string(forKey: "TC_hermesPath")
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.hermesCandidates(),
            defaults: [PathConfig.defaultHermesHome()],
            alternates: []
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                // Hermes: ~/.hermes/state.db (SQLite)
                let dbPath = path + "/state.db"
                let fm = FileManager.default
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: dbPath, isDirectory: &isDir) && !isDir.boolValue
            }
        )
        return buildResult(
            service: "hermes", emoji: "🏔️",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultHermesHome()
        )
    }

    // MARK: - 候选路径构建

    private struct Candidate {
        let path: String
        let source: DetectionResult.PathSource
    }

    /// 按优先级构建候选路径列表（去重）
    private static func buildCandidates(
        custom: String?,
        envName: [String],
        defaults: [String],
        alternates: [String]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen = Set<String>()

        func append(_ path: String, _ source: DetectionResult.PathSource) {
            let resolved = (path as NSString).standardizingPath
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            candidates.append(Candidate(path: resolved, source: source))
        }

        if let custom = custom, !custom.isEmpty {
            append(custom, .userDefaults)
        }
        for path in envName where !path.isEmpty {
            append(path, .envVariable)
        }
        for path in defaults where !path.isEmpty {
            append(path, .officialDefault)
        }
        for path in alternates where !path.isEmpty {
            append(path, .alternate)
        }

        return candidates
    }

    /// 找到第一个通过验证的候选路径
    private static func findFirstValid(
        candidates: [Candidate],
        validator: (String) -> Bool
    ) -> (path: String, source: DetectionResult.PathSource)? {
        for candidate in candidates {
            if validator(candidate.path) {
                return (candidate.path, candidate.source)
            }
        }
        return nil
    }

    /// 构建探测结果
    private static func buildResult(
        service: String,
        emoji: String,
        match: (path: String, source: DetectionResult.PathSource)?,
        custom: String?,
        defaultPath: String
    ) -> DetectionResult {
        if let match = match {
            let isDefault = custom == nil && match.source != .userDefaults
            let detail: String
            switch match.source {
            case .userDefaults:
                detail = L10n.shared.tr("pathDetail.userCustom")
            case .envVariable:
                detail = L10n.shared.tr("pathDetail.envDetected")
            case .officialDefault:
                detail = L10n.shared.tr("pathDetail.official")
            case .alternate:
                detail = L10n.shared.tr("pathDetail.alternate")
            case .notFound:
                detail = L10n.shared.tr("pathDetail.notFound")
            }
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: match.path,
                isDefault: isDefault,
                exists: true,
                source: match.source,
                detail: detail
            )
        } else {
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: defaultPath,
                isDefault: true,
                exists: false,
                source: .notFound,
                detail: L10n.shared.tr("pathDetail.notFoundDefault")
            )
        }
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
                    if findJSONLFiles(in: fullPath, recursive: true) { return true }
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
                    if findJSONFiles(in: fullPath, recursive: true) { return true }
                }
            }
        }
        return false
    }

    /// 在 basePath/subpath 下递归查找 rollout-*.jsonl 文件（Codex 专用）
    static func findRolloutJSONLFiles(in basePath: String, subpath: String) -> Bool {
        let searchDir = basePath + "/" + subpath
        return findRolloutJSONLRecursive(in: searchDir)
    }

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
