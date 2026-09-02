import Foundation
#if os(Windows)
import CSQLite
#endif

/// 自动检索本地环境中各数据源的正确日志路径
/// 支持：环境变量、官方默认路径、备选路径、用户自定义路径
enum PathDetector {
    struct DetectionResult {
        let service: String
        let emoji: String
        let detectedPath: String
        let isDefault: Bool
        #if os(Windows)
        /// The selected catalog candidate itself exists on disk.
        let pathExists: Bool
        /// A filesystem source exists or a loopback service responded. Kept separate because
        /// `pathExists` is intentionally false for HTTP sources.
        let sourceAvailable: Bool
        /// The provider's documented storage/API envelope is readable, even when upstream has
        /// not published numeric statistics fields.
        let contractReadable: Bool
        /// The shared parser's required input (JSONL/JSON/SQLite) is present and readable.
        let parserReadable: Bool
        var exists: Bool { parserReadable }
        #else
        let exists: Bool
        #endif
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
    static func runFullDetection(probeLoopbackServices: Bool = false) -> DetectionSummary {
        var results = [
            detectOpenClaw(),
            detectClaudeCode(),
            detectGemini(),
            detectCodex(),
            detectHermes(),
            detectOpenCode(),
            detectQwen(),
            detectCopilot(),
            detectGrok(),
            detectAider(),
            detectAntigravity(),
            detectCline(),
            detectContinue(),
            detectCursorAgent(),
            detectZCode(),
        ]
        #if os(Windows)
        results.append(detectKiro())
        results.append(detectCodeBuddy(probe: probeLoopbackServices))
        #endif
        let found = results.filter(\.exists).count
        return DetectionSummary(results: results, foundCount: found, totalCount: results.count)
    }

    /// 自动检测所有数据源路径（兼容旧接口）
    static func detectAll() -> [DetectionResult] {
        runFullDetection().results
    }

    // MARK: - 逐项检测

    private static func detectOpenClaw() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .openclawPath)
        #if os(Windows)
        let alternates: [String] = []
        #else
        let alternates = [NSHomeDirectory() + "/Library/Logs/OpenClaw"]
        #endif
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.openclawCandidates(),
            defaults: [PathConfig.defaultOpenclawHome()],
            alternates: alternates
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                windowsReadableJSONL(in: path, subpaths: ["agents", "sessions"], kind: .openclaw)
                #else
                findJSONLFiles(in: path, subpath: "agents", recursive: true)
                || findJSONLFiles(in: path, subpath: "sessions", recursive: true)
                #endif
            }
        )
        return buildResult(
            service: "openclaw", emoji: "⚡",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultOpenclawHome()
        )
    }

    private static func detectClaudeCode() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .claudeCodePath)
        #if os(Windows)
        let alternates: [String] = []
        #else
        let alternates = [NSHomeDirectory() + "/Library/Application Support/Claude"]
        #endif
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.claudeCodeCandidates(),
            defaults: [PathConfig.defaultClaudeCodeHome()],
            alternates: alternates
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                windowsReadableJSONL(in: path, subpaths: ["projects", "claude-code-sessions"], kind: .claude)
                #else
                // Claude Code: ~/.claude/projects/** 下有 .jsonl
                findJSONLFiles(in: path, subpath: "projects", recursive: true)
                // 或 Claude Desktop 的 session 目录
                || findJSONLFiles(in: path, subpath: "claude-code-sessions", recursive: true)
                #endif
            }
        )
        return buildResult(
            service: "claudeCode", emoji: "🧠",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultClaudeCodeHome()
        )
    }

    private static func detectGemini() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .geminiPath)
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.geminiCandidates(),
            defaults: [PathConfig.defaultGeminiHome()],
            alternates: []
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                windowsGeminiReadable(in: path)
                #else
                // Gemini: ~/.gemini/tmp/*/chats/*.json
                findJSONFiles(in: path, subpath: "tmp", recursive: true)
                #endif
            }
        )
        return buildResult(
            service: "gemini", emoji: "💎",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultGeminiHome()
        )
    }

    private static func detectCodex() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .codexPath)
        #if os(Windows)
        let alternates: [String] = []
        #else
        let alternates = [NSHomeDirectory() + "/.config/codex"]
        #endif
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.codexCandidates(),
            defaults: [PathConfig.defaultCodexHome()],
            alternates: alternates
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                windowsReadableJSONL(in: path, subpaths: ["sessions"], kind: .codex)
                #else
                // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
                findRolloutJSONLFiles(in: path, subpath: "sessions")
                // 或历史格式
                || findJSONLFiles(in: path, subpath: "sessions", recursive: true)
                #endif
            }
        )
        return buildResult(
            service: "codex", emoji: "🤖",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultCodexHome()
        )
    }

    #if os(Windows)
    private static func detectKiro() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .kiroSessionsPath)
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.kiroCandidates(),
            defaults: [WindowsProviderCatalog.entry(.kiro).defaultPath],
            alternates: []
        )
        let match = findFirstValid(
            candidates: candidates,
            parserReadableWhenValid: false,
            validator: KiroSessionContractProbe.isReadable
        )
        return buildResult(
            service: WindowsProviderCatalog.ProviderID.kiro.rawValue,
            emoji: WindowsProviderCatalog.entry(.kiro).emoji,
            match: match,
            custom: custom,
            defaultPath: WindowsProviderCatalog.entry(.kiro).defaultPath
        )
    }

    private static func detectCodeBuddy(probe: Bool) -> DetectionResult {
        let endpoint = PathConfig.codeBuddyEndpoint()
        let validEndpoint = CodeBuddyStatsService.validatedLoopbackBaseURL(endpoint) != nil
        let readable = validEndpoint && probe && CodeBuddyStatsService(endpoint: endpoint).probe().contractReadable
        let custom = UserDefaults.standard.string(for: .codeBuddyEndpoint)
        return DetectionResult(
            service: WindowsProviderCatalog.ProviderID.codeBuddy.rawValue,
            emoji: WindowsProviderCatalog.entry(.codeBuddy).emoji,
            detectedPath: endpoint,
            isDefault: custom == nil,
            pathExists: false,
            sourceAvailable: readable,
            contractReadable: readable,
            parserReadable: readable,
            source: custom == nil ? .officialDefault : .userDefaults,
            detail: readable
                ? L10n.shared.tr("pathDetail.contractOnly")
                : L10n.shared.tr(validEndpoint ? "pathDetail.notFound" : "pathDetail.existsUnreadable")
        )
    }
    #endif

    private static func detectZCode() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .zcodePath)
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.zcodeCandidates(),
            defaults: [PathConfig.defaultZCodeHome()],
            alternates: []
        )
        let match = findFirstValid(candidates: candidates, validator: { path in
            let database = (path.lowercased().hasSuffix(".sqlite") || path.lowercased().hasSuffix(".db"))
                ? path : path + "/cli/db/db.sqlite"
            #if os(Windows)
            return windowsSQLitePrepares(database, query: """
                SELECT session_id, model_id, started_at, input_tokens, output_tokens,
                       reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens
                FROM model_usage LIMIT 1
                """)
            #else
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: database, isDirectory: &isDirectory)
                && !isDirectory.boolValue
            #endif
        })
        return buildResult(
            service: "zcode", emoji: "🅉", match: match, custom: custom,
            defaultPath: PathConfig.defaultZCodeHome()
        )
    }

    private static func detectHermes() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .hermesPath)
        #if os(Windows)
        let alternates = WindowsProviderCatalog.entry(.hermes).alternatePaths
        #else
        let alternates: [String] = []
        #endif
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.hermesCandidates(),
            defaults: [PathConfig.defaultHermesHome()],
            alternates: alternates
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                return windowsSQLitePrepares(path + "/state.db", query: """
                    SELECT started_at, input_tokens, output_tokens, cache_read_tokens,
                           cache_write_tokens, message_count FROM sessions LIMIT 1
                    """)
                #else
                let dbPath = path + "/state.db"
                let fm = FileManager.default
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: dbPath, isDirectory: &isDir) && !isDir.boolValue
                #endif
            }
        )
        return buildResult(
            service: "hermes", emoji: "🏔️",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultHermesHome()
        )
    }

    private static func detectOpenCode() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .opencodePath)
        #if os(Windows)
        let alternates = WindowsProviderCatalog.entry(.opencode).alternatePaths
        #else
        let alternates = [NSHomeDirectory() + "/.opencode"]
        #endif
        let candidates = buildCandidates(
            custom: custom,
            envName: PathConfig.opencodeCandidates(),
            defaults: [PathConfig.defaultOpenCodeHome()],
            alternates: alternates
        )
        let match = findFirstValid(
            candidates: candidates,
            validator: { path in
                #if os(Windows)
                let database = path.lowercased().hasSuffix(".db") ? path : path + "/opencode.db"
                return windowsSQLitePrepares(database, query: """
                    SELECT tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                           tokens_cache_write, time_created FROM session LIMIT 1
                    """)
                #else
                let dbPath = path + "/opencode.db"
                let fm = FileManager.default
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: dbPath, isDirectory: &isDir) && !isDir.boolValue
                #endif
            }
        )
        return buildResult(
            service: "opencode", emoji: "🐙",
            match: match, custom: custom,
            defaultPath: PathConfig.defaultOpenCodeHome()
        )
    }

    private static func detectQwen() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .qwenPath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.qwenCandidates(),
            defaults: [PathConfig.defaultQwenHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            windowsReadableJSONL(in: path, subpaths: ["projects"], kind: .geminiOrQwen)
            #else
            findJSONLFiles(in: path, subpath: "projects", recursive: true)
            #endif
        })
        return buildResult(service: "qwen", emoji: "🟣", match: match, custom: custom, defaultPath: PathConfig.defaultQwenHome())
    }

    private static func detectCopilot() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .copilotPath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.copilotCandidates(),
            defaults: [PathConfig.defaultCopilotHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            if path.lowercased().hasSuffix(".jsonl") {
                return windowsReadableJSONLFile(path, kind: .copilot)
            }
            return windowsReadableJSONL(in: path, subpaths: ["otel", "session-state"], kind: .copilot)
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return (fm.fileExists(atPath: path + "/otel", isDirectory: &isDir) && isDir.boolValue)
                || (fm.fileExists(atPath: path + "/session-state", isDirectory: &isDir) && isDir.boolValue)
            #endif
        })
        return buildResult(service: "copilot", emoji: "🐙", match: match, custom: custom, defaultPath: PathConfig.defaultCopilotHome())
    }

    private static func detectGrok() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .grokPath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.grokCandidates(),
            defaults: [PathConfig.defaultGrokHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            return windowsReadableJSONL(in: path, subpaths: ["sessions"], kind: .grok)
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path + "/sessions", isDirectory: &isDir) && isDir.boolValue
            #endif
        })
        return buildResult(service: "grok", emoji: "⚡", match: match, custom: custom, defaultPath: PathConfig.defaultGrokHome())
    }

    private static func detectAider() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .aiderPath)
        #if os(Windows)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.aiderCandidates(),
            defaults: [PathConfig.defaultAiderAnalyticsPath()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            let resolved = path.lowercased().hasSuffix(".jsonl") ? path : path + "/analytics.jsonl"
            return windowsReadableJSONLFile(resolved, kind: .aider)
        })
        return buildResult(service: "aider", emoji: "🤝", match: match, custom: custom, defaultPath: PathConfig.defaultAiderAnalyticsPath())
        #else
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.aiderCandidates(),
            defaults: [PathConfig.defaultAiderHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                && findJSONLFiles(in: path)
        })
        return buildResult(service: "aider", emoji: "🤝", match: match, custom: custom, defaultPath: PathConfig.defaultAiderHome())
        #endif
    }

    private static func detectAntigravity() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .antigravityPath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.antigravityCandidates(),
            defaults: [PathConfig.defaultAntigravityHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            return windowsAntigravityReadable(in: path + "/conversations")
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path + "/conversations", isDirectory: &isDir) && isDir.boolValue
            #endif
        })
        return buildResult(service: "antigravity", emoji: "🛡️", match: match, custom: custom, defaultPath: PathConfig.defaultAntigravityHome())
    }

    private static func detectCline() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .clinePath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.clineCandidates(),
            defaults: [PathConfig.defaultClineHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            return windowsClineReadable(in: path)
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path + "/tasks", isDirectory: &isDir) && isDir.boolValue
            #endif
        })
        return buildResult(service: "cline", emoji: "🤖", match: match, custom: custom, defaultPath: PathConfig.defaultClineHome())
    }

    private static func detectContinue() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .continuePath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.continueCandidates(),
            defaults: [PathConfig.defaultContinueHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            return windowsReadableJSONL(in: path, subpaths: ["dev_data", "sessions"], kind: .continueDev)
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            return (fm.fileExists(atPath: path + "/dev_data", isDirectory: &isDir) && isDir.boolValue)
                || (fm.fileExists(atPath: path + "/sessions", isDirectory: &isDir) && isDir.boolValue)
            #endif
        })
        return buildResult(service: "continue", emoji: "▶️", match: match, custom: custom, defaultPath: PathConfig.defaultContinueHome())
    }

    private static func detectCursorAgent() -> DetectionResult {
        let custom = UserDefaults.standard.string(for: .cursorAgentPath)
        let candidates = buildCandidates(
            custom: custom, envName: PathConfig.cursorAgentCandidates(),
            defaults: [PathConfig.defaultCursorAgentHome()], alternates: [])
        let match = findFirstValid(candidates: candidates, validator: { path in
            #if os(Windows)
            let db = path.lowercased().hasSuffix(".vscdb") ? path : path + "/state.vscdb"
            return windowsCursorCredentialReadable(db)
            #else
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let hookExists = fm.fileExists(atPath: path + "/hooks/log-token-usage.sh")
            let logExists = fm.fileExists(atPath: path + "/token-usage.jsonl")
            let cliConfigExists = fm.fileExists(atPath: path + "/cli-config.json", isDirectory: &isDir) && !isDir.boolValue
            return hookExists || logExists || cliConfigExists
            #endif
        })
        return buildResult(service: "cursorAgent", emoji: "🖱️", match: match, custom: custom, defaultPath: PathConfig.defaultCursorAgentHome())
    }

    // MARK: - 候选路径构建

    private struct Candidate {
        let path: String
        let source: DetectionResult.PathSource
    }

    private struct CandidateMatch {
        let path: String
        let source: DetectionResult.PathSource
        #if os(Windows)
        let pathExists: Bool
        let contractReadable: Bool
        let parserReadable: Bool
        #endif
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

        #if os(Windows)
        let normalizedDefaults = Set(defaults.map { PathConfig.expandedPath($0) })
        let normalizedAlternates = Set(alternates.map { PathConfig.expandedPath($0) })
        #endif

        func append(_ path: String, _ source: DetectionResult.PathSource) {
            #if os(Windows)
            let resolved = PathConfig.expandedPath(path)
            #else
            let resolved = (path as NSString).standardizingPath
            #endif
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            candidates.append(Candidate(path: resolved, source: source))
        }

        if let custom = custom, !custom.isEmpty {
            append(custom, .userDefaults)
        }
        for path in envName where !path.isEmpty {
            #if os(Windows)
            let resolved = PathConfig.expandedPath(path)
            let source: DetectionResult.PathSource
            if normalizedDefaults.contains(resolved) { source = .officialDefault }
            else if normalizedAlternates.contains(resolved) { source = .alternate }
            else { source = .envVariable }
            append(path, source)
            #else
            append(path, .envVariable)
            #endif
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
        parserReadableWhenValid: Bool = true,
        validator: (String) -> Bool
    ) -> CandidateMatch? {
        #if os(Windows)
        var firstExisting: CandidateMatch?
        #endif
        for candidate in candidates {
            let readable = validator(candidate.path)
            #if os(Windows)
            var isDirectory: ObjCBool = false
            let pathExists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            if readable {
                return CandidateMatch(path: candidate.path, source: candidate.source,
                                      pathExists: pathExists, contractReadable: true,
                                      parserReadable: parserReadableWhenValid)
            }
            if pathExists && firstExisting == nil {
                firstExisting = CandidateMatch(path: candidate.path, source: candidate.source,
                                               pathExists: true, contractReadable: false,
                                               parserReadable: false)
            }
            #else
            if readable { return CandidateMatch(path: candidate.path, source: candidate.source) }
            #endif
        }
        #if os(Windows)
        return firstExisting
        #else
        return nil
        #endif
    }

    /// 构建探测结果
    private static func buildResult(
        service: String,
        emoji: String,
        match: CandidateMatch?,
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
            #if os(Windows)
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: match.path,
                isDefault: isDefault,
                pathExists: match.pathExists,
                sourceAvailable: match.pathExists,
                contractReadable: match.contractReadable,
                parserReadable: match.parserReadable,
                source: match.source,
                detail: match.parserReadable
                    ? detail
                    : L10n.shared.tr(match.contractReadable ? "pathDetail.contractOnly" : "pathDetail.existsUnreadable")
            )
            #else
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: match.path,
                isDefault: isDefault,
                exists: true,
                source: match.source,
                detail: detail
            )
            #endif
        } else {
            #if os(Windows)
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: defaultPath,
                isDefault: true,
                pathExists: false,
                sourceAvailable: false,
                contractReadable: false,
                parserReadable: false,
                source: .notFound,
                detail: L10n.shared.tr("pathDetail.notFoundDefault")
            )
            #else
            return DetectionResult(
                service: service, emoji: emoji,
                detectedPath: defaultPath,
                isDefault: true,
                exists: false,
                source: .notFound,
                detail: L10n.shared.tr("pathDetail.notFoundDefault")
            )
            #endif
        }
    }

    #if os(Windows)
    private enum WindowsJSONLKind {
        case openclaw, claude, geminiOrQwen, codex, copilot, grok, aider, continueDev
    }

    /// Bounded provider-root walk: never scans outside the declared candidate, reads at most 32
    /// JSONL files, 1,024 directory entries, and 512 KiB from each file.
    private static func windowsReadableJSONL(
        in basePath: String,
        subpaths: [String],
        kind: WindowsJSONLKind
    ) -> Bool {
        for subpath in subpaths {
            let root = basePath + "/" + subpath
            for file in windowsFiles(in: root, extensions: ["jsonl"], maxDepth: 7, maxFiles: 32) {
                if windowsReadableJSONLFile(file, kind: kind) { return true }
            }
        }
        return false
    }

    private static func windowsFiles(
        in root: String,
        extensions: Set<String>,
        maxDepth: Int,
        maxFiles: Int
    ) -> [String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        var queue: [(String, Int)] = [(root, 0)]
        var files: [String] = []
        var visitedEntries = 0
        while !queue.isEmpty && files.count < maxFiles && visitedEntries < 1_024 {
            let (directory, depth) = queue.removeFirst()
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names {
                visitedEntries += 1
                if visitedEntries > 1_024 { break }
                let path = directory + "/" + name
                var childIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &childIsDirectory) else { continue }
                if childIsDirectory.boolValue {
                    if depth < maxDepth { queue.append((path, depth + 1)) }
                } else if extensions.contains((name as NSString).pathExtension.lowercased()) {
                    files.append(path)
                    if files.count >= maxFiles { break }
                }
            }
        }
        return files
    }

    private static func windowsReadableJSONLFile(_ path: String, kind: WindowsJSONLKind) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1_024), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline).prefix(200) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if windowsJSONRecord(object, matches: kind) { return true }
        }
        return false
    }

    private static func windowsJSONRecord(_ object: [String: Any], matches kind: WindowsJSONLKind) -> Bool {
        switch kind {
        case .openclaw:
            guard let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any] else { return false }
            return positiveTotal(usage, keys: ["input", "output", "cacheRead"])
        case .claude:
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return false }
            return positiveTotal(usage, keys: ["input_tokens", "output_tokens", "cache_read_input_tokens"])
        case .geminiOrQwen:
            if object["type"] as? String == "gemini", let tokens = object["tokens"] as? [String: Any] {
                return positiveTotal(tokens, keys: ["input", "output", "thought", "thoughts"])
            }
            return false
        case .codex:
            return nestedDictionary(named: "last_token_usage", in: object).map {
                positiveTotal($0, keys: ["total_tokens", "input_tokens", "output_tokens"])
            } ?? false
        case .copilot:
            if let attributes = object["attributes"] as? [String: Any],
               positiveTotal(attributes, keys: ["gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens", "gen_ai.usage.cache_read.input_tokens"]) {
                return true
            }
            if object["type"] as? String == "assistant.usage", let usage = object["usage"] as? [String: Any] {
                return positiveTotal(usage, keys: ["inputTokens", "outputTokens", "cacheReadTokens"])
            }
            return false
        case .grok:
            return positiveTotal(object, keys: ["totalTokens"])
        case .aider:
            guard object["event"] as? String == "message_send",
                  let properties = object["properties"] as? [String: Any] else { return false }
            return positiveTotal(properties, keys: ["prompt_tokens", "completion_tokens"])
        case .continueDev:
            if let tokens = object["tokens"] as? [String: Any] {
                return positiveTotal(tokens, keys: ["input", "prompt", "output", "completion"])
            }
            if let usage = object["usage"] as? [String: Any] {
                return positiveTotal(usage, keys: ["prompt_tokens", "input_tokens", "completion_tokens", "output_tokens"])
            }
            return positiveTotal(object, keys: ["prompt_tokens", "input_tokens", "completion_tokens", "output_tokens"])
        }
    }

    private static func positiveTotal(_ dictionary: [String: Any], keys: [String]) -> Bool {
        keys.reduce(0) { total, key in
            if let value = dictionary[key] as? Int { return total + value }
            if let value = dictionary[key] as? NSNumber { return total + value.intValue }
            return total
        } > 0
    }

    private static func nestedDictionary(named key: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let match = dictionary[key] as? [String: Any] { return match }
            for child in dictionary.values {
                if let match = nestedDictionary(named: key, in: child) { return match }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let match = nestedDictionary(named: key, in: child) { return match }
            }
        }
        return nil
    }

    private static func windowsGeminiReadable(in basePath: String) -> Bool {
        let files = windowsFiles(in: basePath + "/tmp", extensions: ["json", "jsonl"], maxDepth: 4, maxFiles: 32)
        for path in files {
            if path.lowercased().hasSuffix(".jsonl") {
                if windowsReadableJSONLFile(path, kind: .geminiOrQwen) { return true }
                continue
            }
            guard let data = windowsBoundedData(at: path, maximumBytes: 2 * 1_024 * 1_024),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]] else { continue }
            if messages.contains(where: { windowsJSONRecord($0, matches: .geminiOrQwen) }) { return true }
        }
        return false
    }

    private static func windowsClineReadable(in basePath: String) -> Bool {
        let files = windowsFiles(in: basePath + "/tasks", extensions: ["json"], maxDepth: 2, maxFiles: 16)
            .filter { ($0 as NSString).lastPathComponent == "api_conversation.json" }
        for path in files {
            guard let data = windowsBoundedData(at: path, maximumBytes: 2 * 1_024 * 1_024),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for entry in entries {
                guard let message = entry["message"] as? [String: Any] else { continue }
                let usage = (message["usage"] as? [String: Any])
                    ?? ((message["metadata"] as? [String: Any])?["usage"] as? [String: Any])
                if let usage, positiveTotal(usage, keys: ["input_tokens", "inputTokens", "output_tokens", "outputTokens", "cache_read_input_tokens", "cacheReadInputTokens"]) {
                    return true
                }
            }
        }
        return false
    }

    private static func windowsBoundedData(at path: String, maximumBytes: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    }

    private static func windowsSQLitePrepares(_ path: String, query: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_finalize(statement)
        return true
    }

    private static func windowsAntigravityReadable(in conversationsPath: String) -> Bool {
        for path in windowsFiles(in: conversationsPath, extensions: ["db"], maxDepth: 1, maxFiles: 16) {
            if windowsSQLitePrepares(path, query: "SELECT step_payload, metadata FROM steps WHERE step_payload IS NOT NULL LIMIT 1") {
                return true
            }
        }
        return false
    }

    private static func windowsCursorCredentialReadable(_ path: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return !String(cString: text).isEmpty
    }
    #endif

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
