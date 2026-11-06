#if os(macOS)
import XCTest
import Foundation
import SQLite3
@testable import TokenClock

private enum NativeFixtureValues {
    static let tokenA = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ1c2VyX25hdGl2ZUEiLCJleHAiOjIxMDAwMDAwMDB9.fixture"
    static let tokenB = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ1c2VyX25hdGl2ZUIiLCJleHAiOjIxMDAwMDAwMDB9.fixture"
    static let scopeA = "db74fab9562e4449984104b1ea2a4ec2086c48a0ed35f1513e20180e8766fae3"
    static let scopeB = "dbb6f3ad54c430ad393031f04abbab52b371ae0bd3e5b161baafcd85b1ba5765"
    static let cipherA = "djEwWYhmSnp1q+qiTrBMIfHTGgZjW/tTCaTVDTLuKms6rmlUNYvuVEceXKT8Ox42pkBo/q4ZPkvmWA0Z8LT8FvejjvtfAfUAM36s/gq9W1WsyiQhUaOJQo79IJHexzpA2GiOFFupdXpdFz38/Gc/ExcHUg=="
    static let cipherB = "djEwWYhmSnp1q+qiTrBMIfHTGgZjW/tTCaTVDTLuKms6rmlUNYvuVEceXKT8Ox42pkBoYTuZAkOIMNi0jHhLeiasXcBL2Uo0l6uNcvij/smaxFA+kfXjSZ4paEdXiq6G5V4Qao+KsBeZG1r4kD0u7dW8BA=="
    static let machine = "djEwHXqeMoM5dOFLZ6bzPbKilg=="
    static let profile = "djEwJuetFTl3lweMufPV0FM3t65MBFlfjkzsmu2sHctOPttKtGb9jLTV7nG8vK2tdFdG"
}

final class GrokBotNativeCredentialTests: XCTestCase {
    private let quota = Data(#"{"isUnified":false,"usagePercent":42,"grokPlanLabel":"Cursor Pro"}"#.utf8)
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var reads: [Bool] = []
        var requests: [URLRequest] = []
        func read(_ value: Bool) { lock.withLock { reads.append(value) } }
        func request(_ value: URLRequest) { lock.withLock { requests.append(value) } }
    }
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-native-" + UUID().uuidString)
        init(signedIn: Bool = true, subjectB: Bool = false) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["signedIn":signedIn]).write(to: root.appendingPathComponent("desktop-status.json"))
            try write(subjectB: subjectB)
        }
        func write(subjectB: Bool = false, corrupt: Bool = false) throws {
            let active = subjectB ? NativeFixtureValues.scopeB : NativeFixtureValues.scopeA
            let envelope: [String: Any] = ["active":active,"accounts":[active:["cursor-access-token": corrupt ? "invalid" : (subjectB ? NativeFixtureValues.cipherB : NativeFixtureValues.cipherA),"cursor-account-profile":NativeFixtureValues.profile]]]
            let text = String(decoding:try JSONSerialization.data(withJSONObject:envelope),as:UTF8.self)
            try JSONSerialization.data(withJSONObject:["version":1,"cursor-accounts":text,"cursor-machine-id":NativeFixtureValues.machine])
                .write(to:root.appendingPathComponent("sand-secrets.json"),options:.atomic)
        }
        func store(_ calls: Calls, denied: Bool = false) -> GrokBotNativeCredentialStore {
            .init(supportDirectory:root.path,passwordReader:{ interactive in
                calls.read(interactive)
                if denied && !interactive { return .init(password:nil,authorizationRequired:true) }
                return .init(password:"test-password")
            })
        }
        deinit {try? FileManager.default.removeItem(at:root)}
    }
    func testRestartReusesAnExistingGrantSilentlyWithoutWritingCredentials() throws {
        let f = try Fixture(), calls = Calls()
        let before = try Data(contentsOf:f.root.appendingPathComponent("sand-secrets.json"))
        let first = f.store(calls), restarted = f.store(calls)
        XCTAssertEqual(first.currentCredential?.userID,"user_nativeA")
        XCTAssertEqual(restarted.currentCredential?.userID,"user_nativeA")
        XCTAssertEqual(restarted.accessState,.authorized)
        XCTAssertEqual(calls.reads,[false,false])
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("sand-secrets.json")),before)
    }
    func testConcurrentExplicitAuthorizationPromptsAtMostOnce() throws {
        let f = try Fixture(), calls = Calls(), store = f.store(calls,denied:true)
        XCTAssertNil(store.currentCredential)
        XCTAssertEqual(store.accessState,.authorizationRequired)
        DispatchQueue.concurrentPerform(iterations:8) { _ in _ = store.authorize() }
        XCTAssertEqual(calls.reads.filter{$0}.count,1)
        XCTAssertEqual(store.accessState,.authorized)
        XCTAssertEqual(store.currentCredential?.userID,"user_nativeA")
    }
    func testDecodeFailureIsNotAnotherAuthorizationRequestAndDoesNotReuseOldAccount() throws {
        let f = try Fixture(), calls = Calls(), store = f.store(calls)
        XCTAssertNotNil(store.currentCredential)
        try f.write(corrupt:true)
        XCTAssertNil(store.currentCredential)
        XCTAssertEqual(store.accessState,.readFailed)
        XCTAssertEqual(store.failureMessageKey,"quota.grokBotCredentialReadFailed")
        XCTAssertTrue(calls.reads.allSatisfy{!$0})
    }
    func testAccountSwitchReloadsCurrentFileWithoutAnotherGrant() throws {
        let f = try Fixture(), calls = Calls(), store = f.store(calls)
        XCTAssertEqual(store.currentCredential?.userID,"user_nativeA")
        try f.write(subjectB:true)
        XCTAssertEqual(store.currentCredential?.userID,"user_nativeB")
        XCTAssertEqual(calls.reads,[false])
        XCTAssertFalse(store.acceptsCursorToken(NativeFixtureValues.tokenA))
        XCTAssertTrue(store.acceptsCursorToken(NativeFixtureValues.tokenB))
    }
    func testLogoutDropsTheCachedCredential() throws {
        let f = try Fixture(), calls = Calls(), store = f.store(calls)
        XCTAssertNotNil(store.currentCredential)
        try Data(#"{"signedIn":false}"#.utf8).write(to:f.root.appendingPathComponent("desktop-status.json"),options:.atomic)
        XCTAssertNil(store.currentCredential)
        XCTAssertEqual(store.accessState,.unavailable)
    }
    func testCurrentAndScopedAndLegacyStorageRetainAccountOwnership() throws {
        let f = try Fixture()
        let current = try Data(contentsOf:f.root.appendingPathComponent("sand-secrets.json"))
        XCTAssertEqual(GrokBotNativeCredentialStore.decodeCredential(current,password:"test-password")?.userID,"user_nativeA")
        let scoped = "scoped:v1:" + NativeFixtureValues.scopeA + ":" + NativeFixtureValues.cipherA
        XCTAssertEqual(GrokBotNativeCredentialStore.decryptSafeStoragePayload(scoped,password:"test-password",expectedScope:NativeFixtureValues.scopeA),NativeFixtureValues.tokenA)
        XCTAssertNil(GrokBotNativeCredentialStore.decryptSafeStoragePayload(scoped,password:"test-password",expectedScope:NativeFixtureValues.scopeB))
        let legacy = try JSONSerialization.data(withJSONObject:["cursor-access-token":NativeFixtureValues.cipherA,"cursor-machine-id":NativeFixtureValues.machine])
        XCTAssertEqual(GrokBotNativeCredentialStore.decodeCredential(legacy,password:"test-password")?.userID,"user_nativeA")
        let missing = try JSONSerialization.data(withJSONObject:["cursor-accounts":"{\"active\":null,\"accounts\":{}}","cursor-access-token":NativeFixtureValues.cipherA,"cursor-machine-id":NativeFixtureValues.machine])
        XCTAssertNil(GrokBotNativeCredentialStore.decodeCredential(missing,password:"test-password"))
    }
    func testCursorCLIOnlyNeedsNoGrokBotKeyAndStaysAnIndependentPlan() throws {
        let f = try Fixture(signedIn:false), calls = Calls(), store = f.store(calls)
        let snapshot = GrokBotQuotaService(stateDatabasePath:"/missing",environment:["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenA,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{ request in
            calls.request(request);return .init(statusCode:200,data:Data(#"{"isUnified":false,"usagePercent":17,"grokPlanLabel":"X Pro"}"#.utf8))
        }).fetch()
        XCTAssertEqual(snapshot.status,.available)
        XCTAssertFalse(XSubscriptionQuota.contains(snapshot.groups))
        XCTAssertTrue(snapshot.source.contains("Cursor Agent CLI"))
        XCTAssertFalse(snapshot.requiresLocalAuthorization)
        XCTAssertTrue(calls.reads.isEmpty)
    }
    func testCursorIDEOnlyWorksWithoutCLIOrGrokBot() throws {
        let f = try Fixture(signedIn:false), calls = Calls(), store = f.store(calls)
        let path=f.root.appendingPathComponent("state.vscdb").path
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(path,&db),SQLITE_OK)
        let sql="CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES('cursorAuth/accessToken','\(NativeFixtureValues.tokenA)'),('storage.serviceMachineId','fixture-machine');"
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        let data=quota
        let result=GrokBotQuotaService(stateDatabasePath:path,environment:["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in
            calls.request(request);return .init(statusCode:200,data:data)
        }).fetch()
        XCTAssertEqual(result.status,.available)
        XCTAssertTrue(result.source.contains("Cursor IDE"))
        XCTAssertTrue(calls.reads.isEmpty)
    }
    func testGrokBotOnlyCanReadIndependentQuotaWithoutAnyCursorInstall() throws {
        let f = try Fixture(), calls = Calls(), store = f.store(calls), data=quota
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["TOKENCLOCK_DISABLE_CURSOR_CREDENTIALS":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in
            calls.request(request);return .init(statusCode:200,data:data)
        }).fetch()
        XCTAssertEqual(result.status,.available)
        XCTAssertEqual(result.account?.id,"user_nativeA")
        XCTAssertTrue(result.source.hasSuffix("Grok Bot"))
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertEqual(calls.reads,[false])
    }
    func testDifferentCursorAccountCannotReplaceTheActiveGrokBotAccount() throws {
        let f = try Fixture(), calls = Calls(), store=f.store(calls), data=quota
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenB,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in
            calls.request(request);return .init(statusCode:200,data:data)
        }).fetch()
        XCTAssertEqual(result.account?.id,"user_nativeA")
        XCTAssertEqual(calls.requests.count,1)
        XCTAssertEqual(calls.requests.first?.value(forHTTPHeaderField:"Authorization"),"Bearer " + NativeFixtureValues.tokenA)
    }
    func testNetworkFailureDoesNotAskForAnotherAppsKeychainPermission() throws {
        let f = try Fixture(), calls = Calls(), store=f.store(calls,denied:true)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenA,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in
            calls.request(request);return .init(statusCode:503,data:Data())
        }).fetch()
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertTrue(calls.reads.isEmpty)
    }
    func testRedirectAndRateLimitAndBadResponseDoNotAskForNativePermission() throws {
        for status in [302, 400, 429] {
            let f = try Fixture(), calls = Calls(), store = f.store(calls, denied: true)
            let result = GrokBotQuotaService(stateDatabasePath: "/missing",
                environment: ["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenA,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],
                homeDirectory:f.root.path,nativeCredentialStore:store,
                transport:{ _ in .init(statusCode:status,data:Data()) }).fetch()
            XCTAssertEqual(result.status,.unavailable)
            XCTAssertFalse(result.requiresLocalAuthorization)
            XCTAssertTrue(calls.reads.isEmpty)
        }
    }
    func testAPIDenialAfterSuccessfulKeyReadDoesNotAskToAuthorizeAgain() throws {
        let f = try Fixture(), calls=Calls(), store=f.store(calls)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["TOKENCLOCK_DISABLE_CURSOR_CREDENTIALS":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{_ in .init(statusCode:401,data:Data())}).fetch()
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertEqual(store.accessState,.authorized)
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertEqual(result.message,L10n.shared.tr("quota.grokBotLoginRejected"))
    }
    func testConfirmedXUnifiedQuotaIsDistinctFromAnIndependentCursorPlan() throws {
        let f = try Fixture(), calls=Calls(), store=f.store(calls)
        let data=Data(#"{"isUnified":true,"usagePercent":27,"currentPeriodStart":"2026-11-01T00:00:00Z","nextResetTimestampUtc":"2026-11-08T00:00:00Z","cursorPlanName":"X Pro"}"#.utf8)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenA,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{_ in .init(statusCode:200,data:data)}).fetch()
        XCTAssertEqual(result.status,.available)
        XCTAssertTrue(XSubscriptionQuota.contains(result.groups))
        XCTAssertTrue(calls.reads.isEmpty)
    }
    func testExplicitlyAbsentBotAllowanceIsNotShownAsFullButAnActiveTrialIsKept() throws {
        let f = try Fixture(signedIn:false), calls=Calls(), store=f.store(calls)
        let absent=Data(#"{"isUnified":false,"usagePercent":0,"hasNonZeroIncludedLimit":false,"hasAvailableUsage":false}"#.utf8)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["CURSOR_AUTH_TOKEN":NativeFixtureValues.tokenA,"TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{_ in .init(statusCode:200,data:absent)}).fetch()
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertTrue(calls.reads.isEmpty)
        let trial=Data(#"{"isUnified":false,"usagePercent":0,"hasNonZeroIncludedLimit":false,"hasAvailableUsage":true}"#.utf8)
        XCTAssertEqual(GrokBotQuotaService.decodeResponse(trial)?.groups.first?.buckets.first?.remainingPercent,100)
    }
    func testKeychainOnlyCursorCLIRequestsItsOwnGrantWithoutRequiringGrokBot() throws {
        let f=try Fixture(signedIn:false), calls=Calls(), store=f.store(calls), data=quota
        let service=GrokBotQuotaService(stateDatabasePath:"/missing",environment:[:],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in
            calls.request(request);return .init(statusCode:200,data:data)
        },cursorCredentialReader:{interactive in
            calls.read(interactive)
            return interactive ? .init(password:NativeFixtureValues.tokenA) : .init(password:nil,authorizationRequired:true)
        })
        let denied=service.fetch()
        XCTAssertTrue(denied.requiresLocalAuthorization)
        XCTAssertEqual(denied.localAuthorizationSource,.cursorCLI)
        XCTAssertTrue(calls.requests.isEmpty)
        XCTAssertTrue(service.authorizeCursorCLI())
        let ready=service.fetch()
        XCTAssertEqual(ready.status,.available)
        XCTAssertFalse(ready.requiresLocalAuthorization)
        XCTAssertEqual(ready.account?.id,"user_nativeA")
        XCTAssertEqual(calls.reads.filter{$0}.count,1)
    }
    func testCursorCLIAccountMetadataChangeCannotReuseAnAllowOnceToken() throws {
        let f=try Fixture(signedIn:false), calls=Calls(), store=f.store(calls), data=quota
        let config=f.root.appendingPathComponent(".cursor/cli-config.json")
        try FileManager.default.createDirectory(at:config.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(#"{"authInfo":{"id":"first-account"}}"#.utf8).write(to:config)
        let service=GrokBotQuotaService(stateDatabasePath:"/missing",environment:[:],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in calls.request(request);return .init(statusCode:200,data:data)},cursorCredentialReader:{interactive in
            interactive ? .init(password:NativeFixtureValues.tokenA) : .init(password:nil,authorizationRequired:true)
        })
        XCTAssertTrue(service.authorizeCursorCLI())
        XCTAssertEqual(service.fetch().status,.available)
        try Data(#"{"authInfo":{"id":"second-account"}}"#.utf8).write(to:config,options:.atomic)
        let result=service.fetch()
        XCTAssertTrue(result.requiresLocalAuthorization)
        XCTAssertEqual(calls.requests.count,1)
    }
    func testAvailableIDEIsUsedBeforeAskingForDeniedCLIKeychainAccess() throws {
        let f=try Fixture(signedIn:false), calls=Calls(), store=f.store(calls), data=quota
        let path=f.root.appendingPathComponent("state.vscdb").path
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES('cursorAuth/accessToken','\(NativeFixtureValues.tokenA)'),('storage.serviceMachineId','fixture-machine');",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let result=GrokBotQuotaService(stateDatabasePath:path,environment:[:],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{_ in .init(statusCode:200,data:data)},cursorCredentialReader:{ interactive in
            calls.read(interactive);return .init(password:nil,authorizationRequired:true)
        }).fetch()
        XCTAssertEqual(result.status,.available)
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertEqual(calls.reads,[false])
        XCTAssertTrue(result.source.hasSuffix("Cursor IDE"))
    }
    func testSignedInBotRequestsBotGrantRatherThanAnUnrelatedCursorCLIGrant() throws {
        let f=try Fixture(), calls=Calls(), store=f.store(calls,denied:true)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:[:],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{_ in XCTFail("No credential is readable");return nil},cursorCredentialReader:{_ in .init(password:nil,authorizationRequired:true)}).fetch()
        XCTAssertTrue(result.requiresLocalAuthorization)
        XCTAssertEqual(result.localAuthorizationSource,.grokBot)
        XCTAssertTrue(calls.reads.allSatisfy{!$0})
    }
    func testGrokOnlyWithoutConfirmedCredentialSourceDoesNotInventQuotaOrRequestAuthorization() throws {
        let f = try Fixture(signedIn:false), calls=Calls(), store=f.store(calls)
        let result=GrokBotQuotaService(stateDatabasePath:"/missing",environment:["TOKENCLOCK_DISABLE_CURSOR_CREDENTIALS":"1"],homeDirectory:f.root.path,nativeCredentialStore:store,transport:{request in calls.request(request);return nil}).fetch()
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertFalse(result.requiresLocalAuthorization)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(calls.requests.isEmpty)
        XCTAssertTrue(calls.reads.isEmpty)
    }
}
#endif
