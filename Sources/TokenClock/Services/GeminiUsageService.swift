import Foundation

/// 从 Gemini CLI 本地 session JSON 读取 token 使用数据
/// 日志位置: ~/.gemini/tmp/*/chats/session-*.json
final class GeminiUsageService: @unchecked Sendable {
    private(set) var dailyData: [String: DayUsage] = [:]
    private var fileCache: [String: FileMeta] = [:]
    private var recentEntries: [RecentEntry] = []

    private let fm = FileManager.default
    private let geminiHome: String

    init() {
        geminiHome = NSHomeDirectory() + "/.gemini"
    }

    func fullScan() {
        dailyData.removeAll()
        fileCache.removeAll()
        recentEntries = []
        scanSessionsDir()
    }

    func incrementalScan() {
        scanSessionsDir()
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

    private func scanSessionsDir() {
        let tmpDir = geminiHome + "/tmp"
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }

        for project in projectDirs {
            let chatsDir = tmpDir + "/" + project + "/chats"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files {
                guard file.hasSuffix(".json") else { continue }
                let fullPath = chatsDir + "/" + file

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let cached = fileCache[fullPath]
                if cached != nil && cached?.modDate == modDate { continue }

                parseSessionFile(path: fullPath)
                fileCache[fullPath] = FileMeta(path: fullPath, modDate: modDate)
            }
        }
    }

    private func parseSessionFile(path: String) {
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return }

        let today = DateHelper.todayKey()

        for msg in messages {
            // Gemini CLI 的 assistant 消息 type == "gemini"
            guard msg["type"] as? String == "gemini" else { continue }
            guard let tokens = msg["tokens"] as? [String: Any] else { continue }

            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let total = input + output
            guard total > 0 else { continue }

            let timestamp = msg["timestamp"] as? String ?? ""
            let dateKey = DateHelper.dateKey(from: timestamp)
            guard dateKey.count == 10 else { continue }

            if var existing = dailyData[dateKey] {
                existing.tokens += total
                existing.messages += 1
                dailyData[dateKey] = existing
            } else {
                dailyData[dateKey] = DayUsage(tokens: total, messages: 1)
            }

            if dateKey == today, let ts = DateHelper.parseISO8601(timestamp) {
                recentEntries.append(RecentEntry(timestamp: ts, tokens: total))
            }
        }
    }
}
