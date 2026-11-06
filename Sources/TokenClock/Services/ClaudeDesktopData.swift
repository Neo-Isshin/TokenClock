import Foundation

/// Read-only Desktop support. Chat/cloud sessions without usage receipts are
/// never turned into guessed tokens. Local Code/Cowork receipts remain separate
/// from the app's cached subscription percentages.
enum ClaudeDesktopData {
    // The App throttles its plan-history writes to roughly fifteen minutes.
    // Keep these honest snapshots for one cadence plus one refresh margin.
    static let historyMaximumAge: TimeInterval = 20 * 60
    private static func historySamples(_ data: Data) -> [[String: Any]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? NSNumber, !JSONNumber.isBoolean(version),
              [1.0, 2.0].contains(version.doubleValue) else { return nil }
        return root["samples"] as? [[String: Any]]
    }
    private static func historyOrganization(_ samples: [[String: Any]], selected: String?) -> String? {
        if let selected, !selected.isEmpty { return selected.lowercased() }
        let organizations = Set(samples.compactMap { $0["org"] as? String }.filter { !$0.isEmpty }.map { $0.lowercased() })
        return organizations.count == 1 ? organizations.first : nil
    }

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

    static func decodeUsageHistory(_ data: Data, now: Date = Date(),
                                   maximumAge: TimeInterval = historyMaximumAge,
                                   organizationID: String? = nil) -> ClaudeQuotaSnapshot? {
        guard let samples = historySamples(data),
              let organization = historyOrganization(samples, selected: organizationID) else { return nil }
        let valid = samples.compactMap { sample -> (Date, [String: Any])? in
            guard (sample["org"] as? String)?.lowercased() == organization,
                  let t = sample["t"] as? NSNumber, !JSONNumber.isBoolean(t),
                  t.doubleValue.isFinite, t.doubleValue > 0,
                  let usage = sample["u"] as? [String: Any] else { return nil }
            let timestamp = Date(timeIntervalSince1970: t.doubleValue / 1000)
            guard timestamp <= now, now.timeIntervalSince(timestamp) <= maximumAge else { return nil }
            return (timestamp, usage)
        }
        guard let (timestamp, usage) = valid.max(by: { $0.0 < $1.0 }) else { return nil }
        var buckets: [CodexQuotaBucket] = []
        for (key, id, minutes) in [("fh", "five_hour", 300), ("sd", "seven_day", 10_080)] {
            guard let number = usage[key] as? NSNumber, !JSONNumber.isBoolean(number),
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

    static func quota(in homes: [String], fileManager: FileManager = .default,
                      now: Date = Date(), organizationID: String? = nil) -> ClaudeQuotaSnapshot? {
        var results: [ClaudeQuotaSnapshot] = []
        for home in homes {
            let path = URL(fileURLWithPath: home).appendingPathComponent("plan-usage-history.json").path
            let data: Data? = {
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let size = attributes[.size] as? NSNumber, size.intValue <= 2_097_152 else { return nil }
                return fileManager.contents(atPath: path)
            }()
            if let data, let history = decodeUsageHistory(data, now: now, organizationID: organizationID) { results.append(history) }
            let selected = organizationID ?? data.flatMap(historySamples).flatMap { historyOrganization($0, selected: nil) }
            if let selected, let response = ClaudeAppResponseCache.read(home: home, organizationID: selected, now: now),
               var snapshot = try? ClaudeQuotaPayload.decode(response.data) {
                snapshot.buckets = snapshot.buckets.filter { $0.resetsAt.map { $0 > now } ?? true }
                if !snapshot.buckets.isEmpty {
                    snapshot.refreshedAt = response.recordedAt
                    snapshot.source = .desktopResponseCache
                    snapshot.account = .init(id: "claude-desktop-org:" + response.organizationID, email: nil)
                    snapshot.message = L10n.shared.tr("quota.claudeResponseCacheNote")
                    results.append(snapshot)
                }
            }
        }
        return results.max { ($0.refreshedAt ?? .distantPast) < ($1.refreshedAt ?? .distantPast) }
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
