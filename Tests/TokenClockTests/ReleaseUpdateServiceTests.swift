import XCTest
@testable import TokenClock

final class ReleaseUpdateServiceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!
    private var now: Date!
    override func setUp() {
        super.setUp()
        suite = "ReleaseUpdateTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func service(_ body: String?, installed: String = "1.5.9") -> ReleaseUpdateService {
        let data = body.map { Data($0.utf8) }
        return ReleaseUpdateService(defaults: defaults, installedVersion: installed, fetch: { data })
    }

    private func check(_ service: ReleaseUpdateService, days: Int = 0) {
        let done = expectation(description: "Background check")
        XCTAssertTrue(service.checkDaily(now: calendar.date(byAdding: .day, value: days, to: now)!,
                                        calendar: calendar) { done.fulfill() })
        wait(for: [done], timeout: 3)
    }

    func testStableNumericVersionComparison() {
        XCTAssertTrue(ReleaseUpdateService.isNewer("v1.5.11", than: "1.5.9"))
        XCTAssertTrue(ReleaseUpdateService.isNewer("2.0.0", than: "v1.99.99"))
        XCTAssertFalse(ReleaseUpdateService.isNewer("v1.5.9", than: "1.5.11"))
        XCTAssertFalse(ReleaseUpdateService.isNewer("1.5.11", than: "v1.5.11"))
        for invalid in ["", "v1.2", "1.2.3.4", "1.2.3-rc.1", "1.2.3+meta", "../evil", "01.2.3", "1.-2.3", "１.2.3", String(repeating: "9", count: 100) + ".2.3"] {
            XCTAssertNil(ReleaseUpdateService.version(invalid), invalid)
        }
    }

    func testNewReleaseCreatesSafeActionableNoticeAndPersistsReadState() throws {
        let checker = service(#"{"tag_name":"v1.5.11","draft":false,"prerelease":false,"html_url":"https://evil.example/"}"#)
        check(checker)
        let first = try XCTUnwrap(checker.notifications().first)
        XCTAssertFalse(first.isRead)
        XCTAssertEqual(first.releaseURL?.absoluteString, "https://github.com/Neo-Isshin/TokenClock/releases/tag/v1.5.11")
        XCTAssertNil(first.route)
        checker.markRead()
        let relaunched = service(#"{"tag_name":"1.5.11","draft":false,"prerelease":false}"#)
        XCTAssertFalse(relaunched.checkDaily(now: now, calendar: calendar))
        check(relaunched, days: 1)
        XCTAssertEqual(relaunched.notifications().first?.id, first.id)
        XCTAssertEqual(relaunched.notifications().first?.isRead, true)
        XCTAssertTrue(service(nil, installed: "1.5.11").notifications().isEmpty)
        XCTAssertTrue(service(nil, installed: "1.6.0").notifications().isEmpty)
    }

    func testLaterVersionGetsNewNoticeButOlderResponseDoesNotReplaceIt() throws {
        let checker = service(#"{"tag_name":"v1.5.11","draft":false,"prerelease":false}"#)
        check(checker)
        let first = try XCTUnwrap(checker.notifications().first)
        checker.markRead()
        let next = service(#"{"tag_name":"v1.6.0","draft":false,"prerelease":false}"#)
        check(next, days: 1)
        let second = try XCTUnwrap(next.notifications().first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(second.isRead)
        check(checker, days: 2)
        XCTAssertEqual(checker.notifications().first?.id, second.id)
    }

    func testFailedRequestThrottlesAndRetriesNextDay() {
        let offline = service(nil)
        check(offline)
        XCTAssertTrue(offline.notifications().isEmpty)
        for _ in 0..<20 { XCTAssertFalse(offline.checkDaily(now: now, calendar: calendar)) }
        check(offline, days: 1)
    }

    func testDraftPrereleaseMalformedAndInstalledVersionsNeverNotify() {
        let bodies = [
            #"{"tag_name":"v9.0.0","draft":true,"prerelease":false}"#,
            #"{"tag_name":"v9.0.0","draft":false,"prerelease":true}"#,
            #"{"tag_name":"v9.0.0-rc.1","draft":false,"prerelease":false}"#,
            #"{"tag_name":"../../malicious","draft":false,"prerelease":false}"#,
            #"{"tag_name":"v9.0.0"}"#,
            #"{"message":"API rate limit exceeded"}"#,
            #"{"tag_name":"v1.5.9","draft":false,"prerelease":false}"#,
            #"{"tag_name":"v1.5.8","draft":false,"prerelease":false}"#,
            "<html>offline</html>"
        ]
        for (day, body) in bodies.enumerated() {
            let checker = service(body)
            check(checker, days: day)
            XCTAssertTrue(checker.notifications().isEmpty, body)
        }
    }

    func testConcurrentCallsClaimOnlyOneRequestAndDoNotBlockCaller() {
        let entered = expectation(description: "Fetcher entered")
        let finished = expectation(description: "Fetcher finished")
        let gate = DispatchSemaphore(value: 0)
        let checker = ReleaseUpdateService(defaults: defaults, installedVersion: "1.5.9") {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return nil
        }
        XCTAssertTrue(checker.checkDaily(now: now, calendar: calendar) { finished.fulfill() })
        wait(for: [entered], timeout: 2)
        // The fetch is still blocked; another report/scan does not block or fetch again.
        XCTAssertFalse(checker.checkDaily(now: now, calendar: calendar))
        gate.signal()
        wait(for: [finished], timeout: 2)
    }

    func testLocalMidnightResetsThrottleAcrossDST() {
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 59))!
        let checker = service(nil)
        check(checker)
        let done = expectation(description: "Next local day")
        XCTAssertTrue(checker.checkDaily(now: now.addingTimeInterval(120), calendar: calendar) { done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    func testInstalledVersionMatchesCLIReleasePin() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = try String(contentsOf: root.appendingPathComponent("cli/tokenclock"), encoding: .utf8)
        XCTAssertTrue(cli.contains("CLI_VERSION=\"\(AppConfig.version)\""), "Bump AppConfig.version with every release")
    }
}
