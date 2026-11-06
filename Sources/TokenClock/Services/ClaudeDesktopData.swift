import Foundation
import CoreFoundation

/// Read-only Desktop support. Chat/cloud sessions without usage receipts are
/// never turned into guessed tokens. Local Code/Cowork receipts remain separate
/// from the app's cached subscription percentages.
enum ClaudeDesktopData {
    static func homes(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        #if os(macOS)
        return [home + "/Library/Application Support/Claude"]
        #elseif os(Windows)
        return [(environment["APPDATA"] ?? home + "/AppData/Roaming") + "/Claude"]
        #else
        return [(environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/Claude"]
        #endif
    }

    static func projectRoots(in homes: [String], fileManager: FileManager = .default) -> [String] {
        var result: [String] = [], seen = Set<String>()
        for home in homes {
            for name in ["local-agent-mode-sessions", "claude-code-sessions"] {
                let root = URL(fileURLWithPath: home).appendingPathComponent(name).resolvingSymlinksInPath()
                guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for case let directory as URL in entries {
                    // Foundation may canonicalize /var to /private/var only
                    // on child URLs. Enumerator depth is independent of that.
                    if entries.level > 3 { entries.skipDescendants(); continue }
                    guard directory.lastPathComponent.hasPrefix("local_") else { continue }
                    // Hidden .claude is deliberately addressed directly; don't recursively
                    // crawl VM bundles, caches, cookies, or every hidden app directory.
                    let projects = directory.appendingPathComponent(".claude/projects").resolvingSymlinksInPath().path
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: projects, isDirectory: &isDirectory), isDirectory.boolValue, seen.insert(projects).inserted {
                        result.append(projects)
                    }
                    entries.skipDescendants()
                }
            }
        }
        return result.sorted()
    }

    static func decodeUsageHistory(_ data: Data, now: Date = Date(), maximumAge: TimeInterval = 600) -> ClaudeQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 2, let samples = root["samples"] as? [[String: Any]] else { return nil }
        // This file is org-scoped rather than user-scoped. Without a verified
        // current-org selector, never pick arbitrarily between multiple orgs.
        let organizations = Set(samples.compactMap { $0["org"] as? String }.filter { !$0.isEmpty })
        guard organizations.count == 1, let organization = organizations.first else { return nil }
        let valid = samples.compactMap { sample -> (Date, [String: Any])? in
            guard sample["org"] as? String == organization,
                  let t = sample["t"] as? NSNumber, CFGetTypeID(t) != CFBooleanGetTypeID(),
                  t.doubleValue.isFinite, t.doubleValue > 0,
                  let usage = sample["u"] as? [String: Any] else { return nil }
            let timestamp = Date(timeIntervalSince1970: t.doubleValue / 1000)
            guard timestamp <= now, now.timeIntervalSince(timestamp) <= maximumAge else { return nil }
            return (timestamp, usage)
        }
        guard let (timestamp, usage) = valid.max(by: { $0.0 < $1.0 }) else { return nil }
        var buckets: [CodexQuotaBucket] = []
        for (key, id, minutes) in [("fh", "five_hour", 300), ("sd", "seven_day", 10_080)] {
            guard let number = usage[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else { continue }
            buckets.append(CodexQuotaBucket(id: "claude:" + id, name: "Claude", usedPercent: number.doubleValue,
                                           windowMinutes: minutes, resetsAt: nil))
        }
        guard !buckets.isEmpty else { return nil }
        return ClaudeQuotaSnapshot(status: .available, buckets: buckets, planType: nil,
            refreshedAt: timestamp, source: .desktopCache,
            message: L10n.shared.tr("quota.claudeCacheNote"),
            account: SubscriptionAccountIdentity(id: "claude-desktop-org:" + organization, email: nil))
    }

    static func quota(in homes: [String], fileManager: FileManager = .default, now: Date = Date()) -> ClaudeQuotaSnapshot? {
        let snapshots = homes.compactMap { home -> ClaudeQuotaSnapshot? in
            let path = URL(fileURLWithPath: home).appendingPathComponent("plan-usage-history.json").path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 2_097_152,
                  let data = fileManager.contents(atPath: path) else { return nil }
            return decodeUsageHistory(data, now: now)
        }
        return snapshots.max { ($0.refreshedAt ?? .distantPast) < ($1.refreshedAt ?? .distantPast) }
    }
}

/// Source of an actual local receipt, independent of the model used in it.
enum ClaudeUsageSurface: String, CaseIterable {
    case codeCLI, codeApp, coworkApp
    var label: String {
        switch self {
        case .codeCLI: return "Code · CLI"
        case .codeApp: return "Code · App"
        case .coworkApp: return "Cowork · App"
        }
    }
    static func classify(path: String) -> Self {
        if path.contains("/local-agent-mode-sessions/") {return .coworkApp}
        if path.contains("/claude-code-sessions/") {return .codeApp}
        return .codeCLI
    }
}
