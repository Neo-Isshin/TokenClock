#if os(macOS)
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Combine

enum AilyreNewsTrack: String, Codable {
    case perks, changes, models
    var badge: String {
        switch self {
        case .perks: return toolboxText("【福利】", "【Perks】")
        case .changes: return toolboxText("【变动】", "【news】")
        case .models: return toolboxText("【模型】", "【Models】")
        }
    }
    static func from(categories: [String]) -> Self? {
        for category in categories {
            switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "福利速递", "福利", "perks", "deals & perks": return .perks
            case "服务变动", "变动", "service news", "service updates", "news": return .changes
            case "ai模型上新", "模型更新", "模型", "new models", "model releases", "models": return .models
            default: continue
            }
        }
        return nil
    }
}

struct AilyreFeedEntry: Equatable {
    let id: String
    let title: String
    let summary: String
    let url: URL
    let publishedAt: Date?
    var logoURL: URL? = nil
    var track: AilyreNewsTrack? = nil
}

enum AilyreFeedParser {
    static let maximumBytes = 1_048_576
    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", ["www.ailyre.com", "ailyre.com"].contains(url.host ?? ""),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              ["/source", "/news"].contains(url.path) || url.path.hasPrefix("/source/") || url.path.hasPrefix("/news/") else { return nil }
        return url
    }
    static func safeLogoURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", ["www.ailyre.com", "ailyre.com"].contains(url.host ?? ""),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/assets/logos-png/[A-Za-z0-9._-]+\.png$"#, options: .regularExpression) != nil else { return nil }
        return url
    }
    static func logoURL(in html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return safeLogoURL(String(html[range]))
    }
    static func plainText(_ html: String) -> String {
        var text = html.components(separatedBy: "<hr").first ?? html
        text = text.replacingOccurrences(of: #"(?i)<(?:br\s*/?|/p|/li)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !["来源 ↗", "Source ↗"].contains($0) }.joined(separator: "\n")
    }
    static func parse(_ data: Data) -> [AilyreFeedEntry]? {
        guard data.count <= maximumBytes,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { return nil }
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.isRSS else { return nil }
        return delegate.entries
    }
    private final class FeedDelegate: NSObject, XMLParserDelegate {
        var isRSS = false
        var entries: [AilyreFeedEntry] = []
        private var values: [String: String]?
        private var field: String?
        private var categories: [String] = []
        private var categoryValue = ""
        private var seen = Set<String>()
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "rss" { isRSS = true }
            if name == "item" { values = [:]; categories = []; categoryValue = "" }
            if values != nil, ["guid", "title", "description", "link", "pubDate", "category"].contains(name) { field = name }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if field == "category" { categoryValue += string }
            else if let field, values != nil { values?[field, default: ""] += string }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self)) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "category", values != nil { categories.append(categoryValue); categoryValue = "" }
            if name == field { field = nil }
            guard name == "item", let values else { return }
            defer { self.values = nil; field = nil }
            let id = (values["guid"] ?? values["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (values["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty, let url = AilyreFeedParser.safeURL(values["link"] ?? ""), seen.insert(id).inserted else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            let date = values["pubDate"].flatMap(formatter.date(from:))
            let summary = AilyreFeedParser.plainText(values["description"] ?? "")
                .components(separatedBy: "\n").filter { $0 != title }.joined(separator: "\n")
            entries.append(.init(id: id, title: String(title.prefix(500)), summary: String(summary.prefix(6000)), url: url, publishedAt: date, logoURL: AilyreFeedParser.logoURL(in: values["description"] ?? ""), track: AilyreNewsTrack.from(categories: categories)))
        }
    }
}

struct AilyreNewsItem: Codable, Identifiable {
    let id: String
    let noticeID: UUID
    var title: String
    var summary: String
    var url: URL
    var publishedAt: Date?
    var firstSeenAt: Date
    var logoURL: URL? = nil
    var track: AilyreNewsTrack? = nil
}

@MainActor final class AilyreNewsService: ObservableObject {
    static let interval: TimeInterval = 2 * 3600
    private static let cacheKey = "TC_ailyreNewsCache.v1"
    struct Cache: Codable {
        var items: [AilyreNewsItem] = []
        var readIDs: Set<String> = []
        var language = ""
        var lastAttempt: Date?
        var refreshedAt: Date?
        var articleMetadataVersion: Int? = 1
    }
    @Published private(set) var cache: Cache
    @Published private(set) var loading = false
    @Published private(set) var errorMessage = ""
    var onChange: (() -> Void)?
    var isPresentationVisible: (() -> Bool)?
    private let defaults: UserDefaults
    private let makeFetcher: () -> NetworkDiagnosticFetcher
    private var task: Task<Void, Never>?
    private var fetcher: NetworkDiagnosticFetcher?
    private var runID: UUID?
    private var viewing = false
    var items: [AilyreNewsItem] { cache.items }
    var unreadCount: Int { items.filter { !cache.readIDs.contains($0.id) }.count }

    init(defaults: UserDefaults = .standard, makeFetcher: @escaping () -> NetworkDiagnosticFetcher = {
        NetworkDiagnosticFetcher(maximumBodyBytes: AilyreFeedParser.maximumBytes, userAgent: "TokenClock/" + AppConfig.version + " AI-Digest")
    }) {
        self.defaults = defaults
        self.makeFetcher = makeFetcher
        self.cache = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        // Refresh once when upgrading the existing cache to logo/track metadata.
        if cache.articleMetadataVersion != 1 {
            cache.articleMetadataVersion = 1; cache.lastAttempt = nil; save()
        }
    }
    func nextCheck(now: Date = Date()) -> Date { cache.lastAttempt.map { max(now, $0.addingTimeInterval(Self.interval)) } ?? now }

    @discardableResult func refreshIfDue(now: Date = Date(), language: String, force: Bool = false) -> Bool {
        let language = language.hasPrefix("zh") ? "zh" : "en"
        guard !loading else { return false }
        if !force, cache.language == language, let last = cache.lastAttempt, now >= last, now.timeIntervalSince(last) < Self.interval { return false }
        loading = true; errorMessage = ""
        cache.language = language; cache.lastAttempt = now; save()
        let id = UUID(); runID = id
        let transport = makeFetcher()
        fetcher = transport
        let url = URL(string: language == "zh" ? "https://www.ailyre.com/news/rss.xml" : "https://www.ailyre.com/news/rss-en.xml")!
        task = Task { [weak self] in
            let reply = await transport.fetch(url)
            transport.cancel()
            guard !Task.isCancelled, let self, self.runID == id else { return }
            if reply.status == 200, !reply.limited, let entries = AilyreFeedParser.parse(reply.data) {
                self.ingest(entries, now: now)
            } else {
                self.errorMessage = toolboxText("暂未获取到新内容，已保留上次速递。", "Could not refresh. The last digest is kept.")
            }
            self.loading = false; self.fetcher = nil; self.task = nil; self.runID = nil
            self.onChange?()
        }
        onChange?()
        return true
    }

    func ingest(_ entries: [AilyreFeedEntry], now: Date) {
        let old = Dictionary(cache.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cache.items = entries.prefix(50).map { entry in
            .init(id: entry.id, noticeID: old[entry.id]?.noticeID ?? UUID(), title: entry.title,
                summary: entry.summary, url: entry.url, publishedAt: entry.publishedAt, firstSeenAt: old[entry.id]?.firstSeenAt ?? now, logoURL: entry.logoURL, track: entry.track)
        }
        cache.refreshedAt = now
        if viewing && (isPresentationVisible?() ?? true) { cache.readIDs.formUnion(cache.items.map(\.id)) }
        save()
    }
    func setViewing(_ value: Bool) {
        viewing = value
        if value { markAllRead() }
    }
    func markAllRead() {
        guard isPresentationVisible?() ?? true else { return }
        markRead(ids: Set(items.map(\.id)))
    }
    /// Explicit acknowledgement from either the digest or notification panel.
    /// The hidden digest's visibility guard must not block reading its notices.
    func markRead(ids: Set<String>) {
        let newlyRead = ids.intersection(Set(items.map(\.id))).subtracting(cache.readIDs)
        guard !newlyRead.isEmpty else { return }
        cache.readIDs.formUnion(newlyRead); save(); onChange?()
    }
    func notices() -> [TokenClockNotification] {
        items.map { item in
            var notice = TokenClockNotification(id: item.noticeID, kind: .news, title: item.title,
                message: String(item.summary.prefix(180)), createdAt: item.publishedAt ?? item.firstSeenAt,
                isRead: cache.readIDs.contains(item.id))
            notice.newsItemID = item.id
            return notice
        }
    }
    func stop() { task?.cancel(); task = nil; fetcher?.cancel(); fetcher = nil; runID = nil; loading = false }
    private func save() { if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) } }
}
#endif
