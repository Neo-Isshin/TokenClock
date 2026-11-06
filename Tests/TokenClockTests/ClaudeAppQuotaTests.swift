#if os(macOS)
import XCTest
import SQLite3
import AppKit
import SwiftUI
import WebKit
@testable import TokenClock

final class ClaudeAppQuotaTests: XCTestCase {
    @MainActor
    func testConnectionLayoutWithoutNetworkOrStoredLogin() throws {
        let controller = ClaudeConnectionController()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame:.zero,configuration:config) // Deliberately never load a URL.
        let view = NSHostingView(rootView:ClaudeConnectionView(controller:controller,webView:web))
        view.frame = NSRect(x:0,y:0,width:780,height:700)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(view.fittingSize.height,560)
        if let output = ProcessInfo.processInfo.environment["TOKENCLOCK_CLAUDE_LOGIN_PREVIEW"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output))
        }
        XCTAssertNil(web.url)
        XCTAssertFalse(controller.busy)
    }
    private let org = "11111111-1111-1111-1111-111111111111"
    private let other = "22222222-2222-2222-2222-222222222222"
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { values.append(request) } }
        var requests: [URLRequest] { lock.withLock { values } }
    }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func fixtureService(usage: Data? = nil, record: Recorder = Recorder(), status: Int = 200,
                                challenge: Bool = false) -> ClaudeAppQuotaService {
        let account = json(["uuid":"account-one", "email_address":"one@example.test"])
        let organizations = json([["uuid":org,"name":"Personal","capabilities":["chat"]]])
        let quota = usage ?? json(["five_hour":["utilization":25],"seven_day":["utilization":70]])
        return ClaudeAppQuotaService { request in
            record.add(request)
            if status != 200 { return .init(status: status,data: Data(),challenge: challenge) }
            switch request.url?.lastPathComponent {
            case "account": return .init(status:200,data:account)
            case "organizations": return .init(status:200,data:organizations)
            default: return .init(status:200,data:quota)
            }
        }
    }
    func testAppOnlyQuotaUsesThreeReadOnlyRequestsAndNoCLI() throws {
        let record = Recorder()
        let snapshot = try fixtureService(record:record).fetch(.init(key:"synthetic-session",organizationID:org,connected:false)).get()
        XCTAssertEqual(snapshot.source,.desktopWeb)
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent),[75,30])
        XCTAssertEqual(snapshot.account?.id,"claude-web:account-one:" + org)
        XCTAssertEqual(record.requests.count,3)
        for request in record.requests {
            XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertEqual(request.url?.host,"claude.ai")
            XCTAssertEqual(request.url?.scheme,"https")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cookie"),"sessionKey=synthetic-session")
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-session"))
            XCTAssertLessThanOrEqual(request.timeoutInterval,8)
        }
        let ring = try XCTUnwrap(DialQuotaResolver.resolve(provider:.claude,groups:[.init(id:"claude",name:"Subscription",buckets:snapshot.buckets)]))
        XCTAssertEqual(ring.outerRemainingPercent,30)
        XCTAssertEqual(ring.innerRemainingPercent,75)
    }
    func testMissingWindowsAreNotMadeInto100Percent() throws {
        let snapshot = try fixtureService(usage:json(["seven_day":["utilization":80]])).fetch(.init(key:"synthetic",organizationID:nil,connected:true)).get()
        XCTAssertEqual(snapshot.buckets.count,1)
        XCTAssertEqual(snapshot.source,.connectedWeb)
        let ring = try XCTUnwrap(DialQuotaResolver.resolve(provider:.claude,groups:[.init(id:"claude",name:"Subscription",buckets:snapshot.buckets)]))
        XCTAssertEqual(ring.outerRemainingPercent,20)
        XCTAssertNil(ring.innerRemainingPercent)
        for usage in [json([:]),json(["five_hour":["utilization":true]]),json(["seven_day":["utilization":101]])] {
            if case .success = fixtureService(usage:usage).fetch(.init(key:"synthetic",organizationID:nil,connected:true)) { XCTFail("Invalid quota accepted") }
        }
        let scoped = try fixtureService(usage:json(["seven_day_opus":["utilization":70]])).fetch(.init(key:"synthetic",organizationID:nil,connected:true)).get()
        XCTAssertNil(DialQuotaResolver.resolve(provider:.claude,groups:[.init(id:"claude",name:"Subscription",buckets:scoped.buckets)]))
    }
    func testStatusFailuresDoNotInventQuotaOrRetry() {
        for status in [401,403,429,500] {
            let record = Recorder()
            if case .failure(let error) = fixtureService(record:record,status:status).fetch(.init(key:"synthetic",organizationID:nil,connected:true)) {
                XCTAssertTrue(error.snapshot.buckets.isEmpty)
                XCTAssertEqual(error.snapshot.requiresConnection,status == 401)
            } else { XCTFail("Failed request accepted") }
            XCTAssertEqual(record.requests.count,1)
        }
        if case .failure(.blocked) = fixtureService(status:403,challenge:true).fetch(.init(key:"synthetic",organizationID:nil,connected:true)) {} else { XCTFail("Security challenge misclassified") }
    }
    func testOrganizationMustBeOwnedAndAmbiguityRequiresSelection() throws {
        let rows = [ClaudeWebOrganization(id:org,name:"One"),.init(id:other,name:"Two")]
        XCTAssertThrowsError(try ClaudeAppQuotaService.selectOrganization(rows,preferred:nil))
        XCTAssertThrowsError(try ClaudeAppQuotaService.selectOrganization([],preferred:nil)) { error in
            guard case ClaudeAppQuotaError.noSubscription = error else { return XCTFail("No subscription misclassified") }
        }
        XCTAssertEqual(try ClaudeAppQuotaService.selectOrganization(rows,preferred:other).id,other)
        XCTAssertThrowsError(try ClaudeAppQuotaService.selectOrganization(rows,preferred:"../../../account"))
        XCTAssertTrue(try ClaudeAppQuotaService.organizations(json([["uuid":org,"capabilities":["api"]]])).isEmpty)
        let record = Recorder()
        _ = fixtureService(record:record).fetch(.init(key:"synthetic",organizationID:other,connected:true))
        XCTAssertEqual(record.requests.count,2) // Never query a foreign organization's usage.
    }
    func testHeaderInjectionAndOversizedResponsesFailClosed() {
        for key in ["", "a\r\nInjected: header", "abc; other=value", "abc\"def", "abc\\def"] {
            let record = Recorder()
            _ = fixtureService(record:record).fetch(.init(key:key,organizationID:nil,connected:false))
            XCTAssertTrue(record.requests.isEmpty)
        }
        let big = Data(repeating:32,count:1_048_577)
        if case .failure(.malformed) = fixtureService(usage:big).fetch(.init(key:"synthetic",organizationID:nil,connected:true)) {} else { XCTFail("Oversized response accepted") }
    }
    func testSelectedConnectionMissingCookieNeverFallsBackToCLIOrDesktop() {
        let result = ClaudeQuotaService(claudeHome:"/missing-cli",environment:[:],homeDirectory:"/missing-home")
            .fetch(connectedSession:nil,connectionSelected:true)
        XCTAssertTrue(result.requiresConnection)
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertTrue(result.buckets.isEmpty)
    }
    func testConnectedAccountChangeRequiresExplicitConfirmationBeforeUsageRead() {
        let recorder = Recorder()
        let session = ClaudeAppSession(key:"synthetic",organizationID:org,connected:true,expectedIdentity:"claude-web:previous-account:" + org)
        if case .failure(.signIn) = fixtureService(record:recorder).fetch(session) {} else { XCTFail("Changed account accepted") }
        XCTAssertEqual(recorder.requests.count,2)
        XCTAssertFalse(recorder.requests.contains { $0.url?.lastPathComponent == "usage" })
    }
    func testLegacySafeStorageCipherFixtureAndInvalidInputs() {
        let cipher = Data(base64Encoded:"djEw5APYyxaXDmuSBIYmLjfxCivXhoFimiC4XKQV2XX7s3Q=")!
        XCTAssertEqual(ClaudeAppCookieReader.decrypt(cipher,password:"test-password",host:".claude.ai",schema:23),"native-token-fixture")
        XCTAssertNil(ClaudeAppCookieReader.decrypt(cipher,password:"test-password",host:".claude.ai",schema:24))
        XCTAssertNil(ClaudeAppCookieReader.decrypt(cipher,password:"wrong",host:".claude.ai",schema:23))
        XCTAssertNil(ClaudeAppCookieReader.decrypt(Data("v20unsupported".utf8),password:"test-password",host:".claude.ai",schema:23))
        // Independently generated with Python PBKDF2 + OpenSSL AES-CBC.
        let bound = Data(base64Encoded:"djEwy6jYs7gT94Sq5G3qkli1iz0Z9feJ3Ed43wFSev1z6T7yJz4WazI7WGIw2kGb9evmPd45RHa4SllVHBgK8hEEXg==")!
        XCTAssertEqual(ClaudeAppCookieReader.decrypt(bound,password:"test-password",host:".claude.ai",schema:24),"synthetic-session")
        XCTAssertNil(ClaudeAppCookieReader.decrypt(bound,password:"test-password",host:"evil.example",schema:24))
    }
    func testPlainDesktopCookieReadAndMissingOrExpiredCookiesNeverProbeKeychain() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-cookie-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("Cookies").path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,is_secure INTEGER);",nil,nil,nil),SQLITE_OK)
        var keychainCalls = 0
        let password: () -> String? = { keychainCalls += 1; return nil }
        XCTAssertNil(ClaudeAppCookieReader.read(homes:[home.path],password:password))
        XCTAssertEqual(sqlite3_exec(db,"INSERT INTO cookies VALUES('.claude.ai','lastActiveOrg','',X'7631300000',0,1);",nil,nil,nil),SQLITE_OK)
        XCTAssertNil(ClaudeAppCookieReader.read(homes:[home.path],password:password))
        XCTAssertEqual(keychainCalls,0)
        XCTAssertEqual(sqlite3_exec(db,"DELETE FROM cookies WHERE name='lastActiveOrg';",nil,nil,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"INSERT INTO cookies VALUES('.claude.ai','sessionKey','synthetic-session',NULL,0,1);",nil,nil,nil),SQLITE_OK)
        let credential = try XCTUnwrap(ClaudeAppCookieReader.read(homes:[home.path],password:password))
        XCTAssertEqual(credential.key,"synthetic-session")
        XCTAssertFalse(credential.connected)
        XCTAssertEqual(sqlite3_exec(db,"UPDATE cookies SET expires_utc=1;",nil,nil,nil),SQLITE_OK)
        XCTAssertNil(ClaudeAppCookieReader.read(homes:[home.path],password:password))
        XCTAssertEqual(keychainCalls,0)
        XCTAssertEqual(sqlite3_exec(db,"UPDATE cookies SET expires_utc=0; INSERT INTO cookies VALUES('claude.ai','sessionKey','other-session',NULL,0,1);",nil,nil,nil),SQLITE_OK)
        XCTAssertNil(ClaudeAppCookieReader.read(homes:[home.path],password:password))
        XCTAssertEqual(keychainCalls,0)
    }
    func testDeclaredLimitsAreAuthoritativeAndOnePercentIsNotOneHundred() throws {
        let data=Data(#"{"five_hour":{"utilization":99},"limits":[{"kind":"session","percent":1,"scope":null},{"kind":"weekly_all","percent":2,"scope":null,"is_active":false},{"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"Other model"}}}]}"#.utf8)
        let result=try ClaudeAppQuotaService.decodeUsage(data)
        XCTAssertEqual(result.buckets.map(\.remainingPercent),[99,98])
        XCTAssertTrue(result.buckets.allSatisfy{$0.resetsAt == nil})
        let legacy=Data(#"{"limits":null,"five_hour":{"utilization":8}}"#.utf8)
        XCTAssertEqual(try ClaudeAppQuotaService.decodeUsage(legacy).buckets.first?.remainingPercent,92)
        let ambiguous=Data(#"{"limits":[{"kind":"session","percent":1},{"kind":"session","percent":2}]}"#.utf8)
        XCTAssertThrowsError(try ClaudeAppQuotaService.decodeUsage(ambiguous))
        let scopedOnly=Data(#"{"limits":[{"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Other model"}}}]}"#.utf8)
        XCTAssertThrowsError(try ClaudeAppQuotaService.decodeUsage(scopedOnly))
    }
    func testAppKeyGrantIsReusedOnlyInMemoryAndCanBeInvalidated() {
        let cache=ClaudeAppPasswordCache();var reads=0
        let denied=cache.read{reads+=1;return .init(data:nil,authorizationRequired:true,cancelled:false)}
        XCTAssertTrue(denied.result.authorizationRequired)
        let granted=cache.read{reads+=1;return .init(data:Data("synthetic-app-key".utf8),authorizationRequired:false,cancelled:false)}
        XCTAssertFalse(granted.cached)
        let reused=cache.read{XCTFail("An explicit grant should not be repeated in the same process");return .init(data:nil,authorizationRequired:true,cancelled:false)}
        XCTAssertTrue(reused.cached);XCTAssertEqual(reads,2)
        cache.invalidate()
        XCTAssertFalse(cache.read{.init(data:Data("rotated-app-key".utf8),authorizationRequired:false,cancelled:false)}.cached)
    }

}
#endif
