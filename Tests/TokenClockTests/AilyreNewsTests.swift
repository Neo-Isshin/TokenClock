#if os(macOS)
import XCTest
@testable import TokenClock

@MainActor final class AilyreNewsTests: XCTestCase {
    private let xml = Data("""
    <rss version="2.0"><channel><item><guid>news-1</guid><title>AI &amp; tools</title>
    <link>https://www.ailyre.com/source/?id=news-1&amp;lang=en</link><pubDate>Fri, 06 Nov 2026 04:07:40 GMT</pubDate>
    <description><![CDATA[<p><b>AI &amp; tools</b><br/>A short update.<br/><a href="https://www.ailyre.com/">Source ↗</a></p><hr/><p>Footer</p>]]></description>
    </item><item><guid>news-1</guid><title>Duplicate</title><link>https://www.ailyre.com/news/</link></item>
    <item><guid>bad</guid><title>Bad</title><link>javascript:alert(1)</link></item></channel></rss>
    """.utf8)
    func testParsesStableIDsPlainSummaryTimeAndOnlyAilyreLinks() throws {
        let items = try XCTUnwrap(AilyreFeedParser.parse(xml))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "AI & tools")
        XCTAssertEqual(item.summary, "A short update.")
        XCTAssertNotNil(item.publishedAt)
        XCTAssertEqual(item.url.query, "id=news-1&lang=en")
        for bad in ["https://evil.example/news/", "http://www.ailyre.com/news/", "https://user:secret@www.ailyre.com/news/"] {
            XCTAssertNil(AilyreFeedParser.safeURL(bad))
        }
        XCTAssertNil(AilyreFeedParser.parse(Data("<!DOCTYPE rss [<!ENTITY x 'test'>]><rss/>".utf8)))
        XCTAssertNil(AilyreFeedParser.parse(Data("<rss><item>".utf8)))
        XCTAssertNil(AilyreFeedParser.parse(Data(repeating: 0, count: AilyreFeedParser.maximumBytes + 1)))
    }
    func testSourceTrackAndProviderLogoComeFromFeedMetadata() throws {
        let source = Data("""
        <rss><channel><item><guid>meta</guid><title>New model</title><link>https://www.ailyre.com/source/?id=meta</link>
        <category>New Models</category><category>OpenAI</category>
        <description><![CDATA[<p><img src="https://www.ailyre.com/assets/logos-png/provider-openai-12ab.png"/> OpenAI · New Models<br/>Details</p>]]></description>
        </item></channel></rss>
        """.utf8)
        let entry = try XCTUnwrap(AilyreFeedParser.parse(source)?.first)
        XCTAssertEqual(entry.track, .models)
        XCTAssertEqual(entry.logoURL?.lastPathComponent, "provider-openai-12ab.png")
        XCTAssertEqual(AilyreNewsTrack.from(categories:["Google","服务变动"]),.changes)
        XCTAssertEqual(AilyreNewsTrack.from(categories:["福利速递"]),.perks)
        XCTAssertEqual(AilyreNewsTrack.from(categories:["Service News"]),.changes)
        XCTAssertEqual(AilyreNewsTrack.from(categories:["Perks"]),.perks)
        XCTAssertNil(AilyreNewsTrack.from(categories:["Unknown category","OpenAI"]))
        for url in ["http://www.ailyre.com/assets/logos-png/a.png","https://evil.example/assets/logos-png/a.png","https://www.ailyre.com/assets/logos-png/a.svg","https://www.ailyre.com/private/a.png"] {
            XCTAssertNil(AilyreFeedParser.safeLogoURL(url))
        }
    }
    func testExistingCacheKeepsReadStateAndRefreshesMetadataOnce() throws {
        let name="NewsMetadataTests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let service=AilyreNewsService(defaults:defaults)
        service.ingest(try XCTUnwrap(AilyreFeedParser.parse(xml)),now:Date())
        service.markAllRead()
        let id=try XCTUnwrap(service.items.first?.noticeID)
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(defaults.data(forKey:"TC_ailyreNewsCache.v1"))) as? [String:Any])
        old.removeValue(forKey:"articleMetadataVersion");old["lastAttempt"]=Date().timeIntervalSinceReferenceDate
        defaults.set(try JSONSerialization.data(withJSONObject:old),forKey:"TC_ailyreNewsCache.v1")
        let upgraded=AilyreNewsService(defaults:defaults)
        XCTAssertEqual(upgraded.items.first?.noticeID,id);XCTAssertEqual(upgraded.unreadCount,0)
        XCTAssertNil(upgraded.cache.lastAttempt);XCTAssertEqual(upgraded.cache.articleMetadataVersion,1)
    }
    func testReadStateAndNoticeIdentitySurviveRefreshAndRelaunch() throws {
        let name = "NewsTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let entries = try XCTUnwrap(AilyreFeedParser.parse(xml))
        let news = AilyreNewsService(defaults: store)
        news.ingest(entries, now: Date())
        XCTAssertEqual(news.unreadCount, 1)
        let notice = try XCTUnwrap(news.notices().first)
        news.markAllRead()
        news.ingest(entries, now: Date().addingTimeInterval(7200))
        XCTAssertEqual(news.notices().first?.id, notice.id)
        XCTAssertEqual(news.unreadCount, 0)
        let relaunched = AilyreNewsService(defaults: store)
        XCTAssertEqual(relaunched.unreadCount, 0)
        XCTAssertEqual(relaunched.items.count, 1)
        news.setViewing(true)
        news.ingest(entries + [.init(id: "new", title: "New", summary: "", url: entries[0].url, publishedAt: nil)], now: Date())
        XCTAssertEqual(news.unreadCount, 0)
    }
    func testHiddenPanelDoesNotReadIncomingNews() throws {
        let name = "NewsVisibilityTests." + UUID().uuidString, defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let entries = try XCTUnwrap(AilyreFeedParser.parse(xml))
        let news = AilyreNewsService(defaults:defaults)
        var visible = false
        news.isPresentationVisible = { visible }
        news.setViewing(true)
        news.ingest(entries,now:Date())
        XCTAssertEqual(news.unreadCount,1)
        visible = true;news.setViewing(true)
        XCTAssertEqual(news.unreadCount,0)
        visible = false
        news.ingest(entries + [.init(id:"new-hidden",title:"New",summary:"",url:entries[0].url,publishedAt:nil)],now:Date())
        XCTAssertEqual(news.unreadCount,1)
    }
    func testTwoHourThrottleDoesNotStartTransportEarly() throws {
        let name = "NewsThrottleTests." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let cache = AilyreNewsService.Cache(language: "en", lastAttempt: now)
        defaults.set(try JSONEncoder().encode(cache), forKey: "TC_ailyreNewsCache.v1")
        var started = 0
        let service = AilyreNewsService(defaults: defaults, makeFetcher: { started += 1; return NetworkDiagnosticFetcher() })
        XCTAssertFalse(service.refreshIfDue(now: now.addingTimeInterval(7199), language: "en"))
        XCTAssertEqual(started, 0)
        XCTAssertEqual(service.nextCheck(now: now), now.addingTimeInterval(7200))
        service.stop()
    }
}
#endif
