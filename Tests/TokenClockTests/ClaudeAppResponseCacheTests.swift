#if os(macOS)
import XCTest
import Foundation
@testable import TokenClock

private enum CacheGolden {
    static let plain = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAwAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAdTtATVAAAAAAAAAA"
    static let zstd = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZSi1L/0ghcUCAIQEeyJmaXZlX2hvdXIiOnsidXRpbGl6YXRpb24iOjI1LCJyZXNldHNfYXQiOiIyMDMxLTBUMDA6WiJ9LCJzZXZlbl9kYXk3MDV9BQCAE1BjRZgKCBEDBwXYQQ2XRW/69AEAAAC8zm3IAAAAAAAAAABMAAAAAwAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAdTtATVAAAAAAAAAA"
    static let forbidden = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAwAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgNDAzIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAjLwQ51AAAAAAAAAA"
    static let truncated = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAxAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAA7HZViFAAAAAAAAAA"
    static let stale = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAwAAAMB3xl2gHjAAwHfGXaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAOuePelAAAAAAAAAA"
    static let future = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAwAAAEBCqIGgHjAAQEKogaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAZ+SadVAAAAAAAAAA"
    static let otherOrg = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMi91c2FnZXsiZml2ZV9ob3VyIjp7InV0aWxpemF0aW9uIjoyNSwicmVzZXRzX2F0IjoiMjAzMS0wMS0wMVQwMDowMDowMFoifSwic2V2ZW5fZGF5Ijp7InV0aWxpemF0aW9uIjo3MCwicmVzZXRzX2F0IjoiMjAzMS0wMS0wNVQwMDowMDowMFoifX3YQQ2XRW/69AEAAADy5rD+AAAAAAAAAABMAAAAAwAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AANBlbiDgV35eEMO+EeH7eJPkV/UDNhqv+ZY29mVPb0ws2EENl0Vv+vQDAAAAdTtATVAAAAAAAAAA"
    static let huge = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZSi1L/2gCAAQAHwAADh7IngiOiJ4AQD2/zkwAgIAEHgCABB4AgAQeAIAEHgCABB4AgAQeAIAEHhBAAB4eHh4eHgifdhBDZdFb/r0AQAAAJdGs40AAAAAAAAAAEwAAAADAAAAwLRMgaAeMADAtEyBoB4wADQAAABIVFRQLzEuMSAyMDAgU3RhdHVzAENvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbgAAxMKOBhH6ifMqwrboTk3LbB9Xl52hMZG/+QVL9kjYV1XYQQ2XRW/69AMAAAB1O0BNUAAAAAAAAAA="
    static let error = "MFxypxtt+/wFAAAAUgAAAAAAAAAAAAAAMS8wL2h0dHBzOi8vY2xhdWRlLmFpL2FwaS9vcmdhbml6YXRpb25zLzExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMS91c2FnZXsidHlwZSI6ImVycm9yIn3YQQ2XRW/69AEAAAAlPYpoAAAAAAAAAABMAAAAAwAAAMC0TIGgHjAAwLRMgaAeMAA0AAAASFRUUC8xLjEgMjAwIFN0YXR1cwBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24AAMTCjgYR+onzKsK26E5Ny2wfV5edoTGRv/kFS/ZI2FdV2EENl0Vv+vQDAAAAdTtATVAAAAAAAAAA"
    static let name = "b44f976f27c486f6_0"
    static let bodyOffset = 106
}
final class ClaudeAppResponseCacheTests: XCTestCase {
    let org="11111111-1111-4111-8111-111111111111"
    let now=Date(timeIntervalSince1970:1_900_000_000)
    final class Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var directory:URL {root.appendingPathComponent("Cache/Cache_Data")}
        init() throws {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        func write(_ value:String,name:String=CacheGolden.name) throws -> URL {
            let path=directory.appendingPathComponent(name)
            try XCTUnwrap(Data(base64Encoded:value)).write(to:path)
            return path
        }
        func history(org:String,now:Date,age:Double) throws {
            let sample:[String:Any]=["t":now.addingTimeInterval(-age).timeIntervalSince1970*1000,"org":org,"u":["fh":80,"sd":90]]
            try JSONSerialization.data(withJSONObject:["version":2,"samples":[sample]])
                .write(to:root.appendingPathComponent("plan-usage-history.json"))
        }
        deinit {try? FileManager.default.removeItem(at:root)}
    }
    func testKnownQuotaKeysReadPlainAndZstdWithoutCredentialsAndKeepResponseTime() throws {
        for data in [CacheGolden.plain,CacheGolden.zstd] {
            let f=try Fixture();_ = try f.write(data)
            let response=try XCTUnwrap(ClaudeAppResponseCache.read(home:f.root.path,organizationID:org,now:now))
            XCTAssertEqual(response.organizationID,org)
            XCTAssertEqual(response.recordedAt.timeIntervalSince1970,now.addingTimeInterval(-5).timeIntervalSince1970,accuracy:0.0001)
            let parsed=try ClaudeAppQuotaService.decodeUsage(response.data)
            XCTAssertEqual(parsed.buckets.map(\.remainingPercent),[75,30])
        }
    }
    func testRejectsChallengesTruncationExpiredFutureAndOversizedDecodedBody() throws {
        for fixture in [CacheGolden.forbidden,CacheGolden.truncated,CacheGolden.stale,CacheGolden.future,CacheGolden.huge] {
            let f=try Fixture();_ = try f.write(fixture)
            XCTAssertNil(ClaudeAppResponseCache.read(home:f.root.path,organizationID:org,now:now))
        }
    }
    func testOtherOrganizationAndUnrelatedCacheEntriesAreNotOpenedAsQuotaBodies() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.otherOrg,name:"other-organization_0")
        var decoded=0
        XCTAssertNil(ClaudeAppResponseCache.read(home:f.root.path,organizationID:org,now:now,decodeBody:{data in decoded+=1;return data}))
        XCTAssertEqual(decoded,0)
        XCTAssertTrue(ClaudeAppResponseCache.entryKeys(organizationID:"../../other-app").isEmpty)
    }
    func testChecksumAndConcurrentMutationAreRejected() throws {
        let f=try Fixture()
        var data=try XCTUnwrap(Data(base64Encoded:CacheGolden.plain))
        data[CacheGolden.bodyOffset] ^= 1
        try data.write(to:f.directory.appendingPathComponent(CacheGolden.name))
        XCTAssertNil(ClaudeAppResponseCache.read(home:f.root.path,organizationID:org,now:now))
        let path=try f.write(CacheGolden.plain)
        let result=ClaudeAppResponseCache.read(home:f.root.path,organizationID:org,now:now,decodeBody:{ body in
            let writer=FileHandle(forWritingAtPath:path.path)!
            try! writer.seek(toOffset:UInt64(CacheGolden.bodyOffset));try! writer.write(contentsOf:Data([0]));try! writer.close()
            return body
        })
        XCTAssertNil(result)
    }
    func testNewestCompleteLocalResponseReplacesThrottledHistoryWithoutMixingWindows() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.zstd);try f.history(org:org,now:now,age:900)
        let result=try XCTUnwrap(ClaudeDesktopData.quota(in:[f.root.path],now:now))
        XCTAssertEqual(result.source,.desktopResponseCache)
        XCTAssertEqual(result.buckets.map(\.remainingPercent),[75,30])
        XCTAssertEqual(result.refreshedAt,now.addingTimeInterval(-5))
        XCTAssertNil(result.verifiedIdentity)
        XCTAssertNil(result.account?.email)
        XCTAssertTrue(result.buckets.allSatisfy{$0.resetsAt != nil})
    }
    func testAnErrorResponseCannotBecomeZeroOrFullQuota() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.error);try f.history(org:org,now:now,age:90000)
        XCTAssertNil(ClaudeDesktopData.quota(in:[f.root.path],now:now))
    }
    func testCurrentSessionOrganizationSelectsOnlyItsOwnLocalRecords() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.plain)
        let samples:[[String:Any]]=[
            ["t":now.addingTimeInterval(-900).timeIntervalSince1970*1000,"org":org,"u":["fh":80,"sd":90]],
            ["t":now.addingTimeInterval(-3).timeIntervalSince1970*1000,"org":"22222222-2222-4222-8222-222222222222","u":["fh":1,"sd":2]]]
        try JSONSerialization.data(withJSONObject:["version":2,"samples":samples]).write(to:f.root.appendingPathComponent("plan-usage-history.json"))
        XCTAssertNil(ClaudeDesktopData.quota(in:[f.root.path],now:now))
        let result=try XCTUnwrap(ClaudeDesktopData.quota(in:[f.root.path],now:now,organizationID:org))
        XCTAssertEqual(result.buckets.map(\.remainingPercent),[75,30])
    }
    final class Calls: @unchecked Sendable {
        let lock=NSLock();var count=0
        func increment(){lock.withLock{count+=1}}
    }
    func testProductionAutomaticReadWorksFromSavedResponseWithoutCLIOrAnyRequest() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.zstd);try f.history(org:org,now:now,age:90000)
        let hostHome=f.root.appendingPathComponent("test-user")
        let appHome=try XCTUnwrap(ClaudeDesktopData.homes(home:hostHome.path).first)
        try FileManager.default.createDirectory(at:URL(fileURLWithPath:appHome).deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:appHome,withDestinationPath:f.root.path)
        let calls=Calls()
        let service=ClaudeQuotaService(claudeHome:hostHome.appendingPathComponent("no-cli").path,
            environment:["CLAUDE_CODE_OAUTH_TOKEN":"synthetic-no-network-canary"],homeDirectory:hostHome.path,
            oauthTransport:{_ in calls.increment();XCTFail("A local quota read must not send a request");return nil})
        for offset in [0.0,180.0,360.0] {
            let result=service.fetch(connectedSession:nil,connectionSelected:false,now:now.addingTimeInterval(offset))
            XCTAssertEqual(result.status,.available)
            XCTAssertEqual(result.source,.desktopResponseCache)
            XCTAssertEqual(result.buckets.map(\.remainingPercent),[75,30])
            XCTAssertEqual(result.refreshedAt,now.addingTimeInterval(-5))
            XCTAssertFalse(result.localAuthorizationRequired)
            XCTAssertFalse(result.requiresConnection)
        }
        XCTAssertEqual(calls.count,0)
    }
    func testWireChallengeThenLocalFallbackAndMissingDataNeverBecomeAnotherLoginRequest() throws {
        let f=try Fixture();_ = try f.write(CacheGolden.plain)
        let wire=Data("HTTP/2 403 Forbidden\r\ncf-mitigated: challenge\r\ncontent-type: text/html\r\n\r\nJust a moment".utf8)
        let decoded=try ClaudeQuotaNetwork.decode(wire).get()
        XCTAssertTrue(decoded.challenge)
        let app=ClaudeAppQuotaService{_ in .init(status:decoded.status,data:decoded.data,challenge:decoded.challenge)}
        guard case .failure(let error)=app.fetch(.init(key:"synthetic-session",organizationID:org,connected:false)) else {return XCTFail("Challenge was accepted as data")}
        XCTAssertEqual(error.messageKey,"quota.claudeWebBlocked")
        let missing={ClaudeQuotaReadPolicy.failure(.noCredential,key:"quota.claudePassiveUnavailable")}
        let local=try XCTUnwrap(ClaudeDesktopData.quota(in:[f.root.path],now:now,organizationID:org))
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:missing,
            desktop:{error.snapshot},oauth:missing,cache:{local},now:now)
        XCTAssertEqual(result.source,.desktopResponseCache)
        XCTAssertFalse(result.requiresConnection)
        XCTAssertEqual(result.buckets.map(\.remainingPercent),[75,30])
        let expired=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:missing,
            desktop:{error.snapshot},oauth:missing,cache:{local},now:now.addingTimeInterval(700))
        XCTAssertEqual(expired.status,.unavailable)
        XCTAssertEqual(expired.readFailure,.blocked)
        XCTAssertFalse(expired.requiresConnection)
        XCTAssertTrue(expired.buckets.isEmpty)
    }

}
#endif
