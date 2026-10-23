import Foundation

/// Public release metadata only; never reads credentials or installs an update.
/// The daily-report lifecycle calls this on startup/catch-up and at settlement.
final class ReleaseUpdateService: @unchecked Sendable {
    static let shared = ReleaseUpdateService()
    private static let checkKey = "TC_releaseCheckDay"
    private static let noticeKey = "TC_releaseUpdateNotice"
    private let defaults: UserDefaults
    private let installedVersion: String
    private let fetch: @Sendable () -> Data?
    private let lock = NSLock()
    enum CheckResult: Equatable, Sendable {
        case current
        case available(version: String, url: URL)
        case unavailable
    }

    static let distributionRoot = "https://www.ailyre.com/tokenclock"
    static let releasesURL = URL(string: distributionRoot + "/releases/")!
    static let latestMetadataURL = URL(string: distributionRoot + "/releases/latest.json")!

    static func releaseURL(tag: String) -> URL {
        URL(string: distributionRoot + "/releases/" + tag + "/")!
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
    private struct Notice: Codable {
        let id: UUID
        let tag: String
        let createdAt: Date
        var isRead: Bool
    }

    init(defaults: UserDefaults = .standard, installedVersion: String = AppConfig.version,
         fetch: @escaping @Sendable () -> Data? = {
             BillingHTTP.read(ReleaseUpdateService.latestMetadataURL,
                              headers: ["Accept": "application/json",
                                        "User-Agent": "TokenClock/" + AppConfig.version])
         }) {
        self.defaults = defaults
        self.installedVersion = installedVersion
        self.fetch = fetch
    }

    /// Strict stable versions only. Numeric comparison avoids v1.5.9 > v1.5.11.
    static func version(_ tag: String) -> [Int]? {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let values = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  piece.count == 1 || piece.first != "0" else { return nil }
            return Int(piece)
        }
        return values.count == 3 ? values : nil
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = version(candidate), let rhs = version(installed) else { return false }
        return rhs.lexicographicallyPrecedes(lhs)
    }

    /// A user-initiated check bypasses the daily throttle. A failed or malformed
    /// response is never represented as "up to date" and never changes the app.
    func checkNow(completion: @escaping @Sendable (CheckResult) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let data = fetch(), data.count <= 1_048_576,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft, !release.prerelease,
                  let parts = Self.version(release.tag_name), Self.version(installedVersion) != nil else {
                completion(.unavailable); return
            }
            guard Self.isNewer(release.tag_name, than: installedVersion) else { completion(.current); return }
            lock.lock()
            if load().map({ Self.isNewer(release.tag_name, than: $0.tag) }) ?? true {
                save(Notice(id: UUID(), tag: release.tag_name, createdAt: Date(), isRead: false))
            }
            lock.unlock()
            let version = parts.map(String.init).joined(separator: ".")
            completion(.available(version: version,
                url: Self.releaseURL(tag: release.tag_name)))
        }
    }

    /// Claim today's attempt before starting I/O, including failures. Historical
    /// catch-up and repeated scans cannot issue one request per old report.
    @discardableResult
    func checkDaily(now: Date = Date(), calendar: Calendar = .current,
                    completion: @escaping @Sendable () -> Void = {}) -> Bool {
        let day = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let key = "\(day.era ?? 0)-\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        lock.lock()
        guard defaults.string(forKey: Self.checkKey) != key else { lock.unlock(); return false }
        defaults.set(key, forKey: Self.checkKey)
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion() }
            guard let data = fetch(), data.count <= 1_048_576,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft, !release.prerelease,
                  Self.isNewer(release.tag_name, than: installedVersion) else { return }
            lock.lock(); defer { lock.unlock() }
            // Keep read state across launches, tag spelling changes and repeated checks.
            if let existing = load(), !Self.isNewer(release.tag_name, than: existing.tag) { return }
            save(Notice(id: UUID(), tag: release.tag_name, createdAt: now, isRead: false))
        }
        return true
    }

    func notifications() -> [TokenClockNotification] {
        lock.lock(); defer { lock.unlock() }
        guard let notice = load(), Self.isNewer(notice.tag, than: installedVersion),
              let parts = Self.version(notice.tag) else { return [] }
        let version = parts.map(String.init).joined(separator: ".")
        var notification = TokenClockNotification(
            id: notice.id, kind: .system,
            title: BillingText.choose("TokenClock \(version) available", "TokenClock \(version) 可更新", "TokenClock \(version) 可更新"),
            message: BillingText.choose("Current: \(installedVersion). Click to view the release.",
                                        "当前版本：\(installedVersion)。点击查看发布页。",
                                        "目前版本：\(installedVersion)。點擊查看發布頁。"),
            createdAt: notice.createdAt, isRead: notice.isRead)
        // Never trust an arbitrary URL supplied in remote metadata or persisted data.
        notification.releaseURL = Self.releaseURL(tag: notice.tag)
        return [notification]
    }

    func markRead() {
        lock.lock(); defer { lock.unlock() }
        guard var notice = load(), !notice.isRead else { return }
        notice.isRead = true
        save(notice)
    }

    private func load() -> Notice? {
        guard let data = defaults.data(forKey: Self.noticeKey) else { return nil }
        return try? JSONDecoder().decode(Notice.self, from: data)
    }

    private func save(_ notice: Notice) {
        if let data = try? JSONEncoder().encode(notice) { defaults.set(data, forKey: Self.noticeKey) }
    }
}
