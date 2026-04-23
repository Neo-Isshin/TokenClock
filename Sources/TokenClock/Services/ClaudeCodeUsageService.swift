import Foundation

/// 从 Claude Code 本地 JSONL 日志读取 token 使用数据
/// 日志位置: ~/.claude/projects/*/
final class ClaudeCodeUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let claudeHome: String

    init() {
        claudeHome = NSHomeDirectory() + "/.claude"
    }

    func fullScan() {
        dailyData.removeAll()
        fileCache.removeAll()
        recentEntries = []
        scanProjectsDir()
    }

    func incrementalScan() {
        scanProjectsDir()
    }

    func todayUsage() -> (tokens: Int, messages: Int) {
        let d = dailyData[DateHelper.todayKey()]
        return (d?.tokens ?? 0, d?.messages ?? 0)
    }

    func recentUsage(minutes: Int = 10) -> (tokens: Int, messages: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        var tokens = 0, messages = 0
        for entry in recentEntries {
            if entry.timestamp >= cutoff {
                tokens += entry.tokens
                messages += 1
            }
        }
        return (tokens, messages)
    }

    func isActive() -> Bool {
        let cutoff = Date().addingTimeInterval(-600)
        return recentEntries.contains { $0.timestamp >= cutoff }
    }

    // MARK: - 内部

    private func scanProjectsDir() {
        let projectsDir = claudeHome + "/projects"
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for project in projects {
            let projectPath = projectsDir + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in contents {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = projectPath + "/" + file
                var fIsDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &fIsDir), !fIsDir.boolValue else { continue }

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                parseFile(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
    }

    private func parseFile(path: String) {
        guard let stream = InputStream(fileAtPath: path) else { return }
        stream.open()
        defer { stream.close() }

        let today = DateHelper.todayKey()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var lineBuf = Data()

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            lineBuf.append(buf, count: n)

            while let nlRange = lineBuf.range(of: Data([0x0A])) {
                let lineData = lineBuf[lineBuf.startIndex..<nlRange.lowerBound]
                lineBuf = lineBuf[nlRange.upperBound...]
                guard !lineData.isEmpty else { continue }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.contains("\"assistant\"") {
                    parseAssistantLine(line, today: today)
                }
            }
        }

        if !lineBuf.isEmpty,
           let line = String(data: lineBuf, encoding: .utf8),
           line.contains("\"assistant\"") {
            parseAssistantLine(line, today: today)
        }
    }

    private func parseAssistantLine(_ line: String, today: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Claude Code: { "message": { "role": "assistant", "usage": { "input_tokens", "output_tokens" } } }
        guard let msg = obj["message"] as? [String: Any] else { return }
        guard msg["role"] as? String == "assistant" else { return }
        guard let usage = msg["usage"] as? [String: Any] else { return }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let tokens = input + output
        guard tokens > 0 else { return }

        let timestamp = obj["timestamp"] as? String ?? ""
        let dateKey = DateHelper.dateKey(from: timestamp)
        guard dateKey.count == 10 else { return }

        if var existing = dailyData[dateKey] {
            existing.tokens += tokens
            existing.messages += 1
            dailyData[dateKey] = existing
        } else {
            dailyData[dateKey] = DayUsage(tokens: tokens, messages: 1)
        }

        if dateKey == today, let ts = DateHelper.parseISO8601(timestamp) {
            recentEntries.append(RecentEntry(timestamp: ts, tokens: tokens))
        }
    }
}
