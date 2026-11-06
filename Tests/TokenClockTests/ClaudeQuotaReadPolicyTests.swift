#if os(macOS)
import XCTest
import Foundation
@testable import TokenClock

final class ClaudeQuotaReadPolicyTests: XCTestCase {
    let now=Date(timeIntervalSince1970:1_900_000_000)
    let a=ClaudeQuotaIdentity(accountID:"11111111-1111-4111-8111-111111111111",organizationID:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let b=ClaudeQuotaIdentity(accountID:"22222222-2222-4222-8222-222222222222",organizationID:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    func good(_ identity:ClaudeQuotaIdentity?,source:ClaudeQuotaSource = .desktopWeb,age:Double=0)->ClaudeQuotaSnapshot {
        var value=ClaudeQuotaSnapshot(status:.available,buckets:[.init(id:"weekly",name:"Claude",usedPercent:20,windowMinutes:10_080,resetsAt:nil)],planType:"pro",refreshedAt:now.addingTimeInterval(-age),source:source,message:nil,account:.init(id:identity?.key ?? "claude-desktop-org:cached",email:nil))
        value.verifiedIdentity=identity
        return value
    }
    func missing()->ClaudeQuotaSnapshot {ClaudeQuotaReadPolicy.failure(.noCredential,key:"quota.claudePassiveUnavailable")}
    func testWorkingAppSessionDoesNotReadOtherCredentials() {
        var oauth=0,cache=0
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:{self.missing()},desktop:{self.good(self.a)},oauth:{oauth+=1;return self.missing()},cache:{cache+=1;return nil},now:now)
        XCTAssertEqual(result.verifiedIdentity,a);XCTAssertEqual(oauth,0);XCTAssertEqual(cache,0)
    }
    func testBlockedAppFallsBackToVerifiedSameAccountAndOrganization() {
        var blocked=ClaudeQuotaReadPolicy.failure(.blocked,key:"quota.claudeWebBlocked");blocked.verifiedIdentity=a
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:{self.missing()},desktop:{blocked},oauth:{self.good(self.a,source:.oauthAPI)},cache:{nil},now:now)
        XCTAssertEqual(result.source,.oauthAPI);XCTAssertEqual(result.verifiedIdentity,a);XCTAssertFalse(result.requiresConnection)
    }
    func testDifferentAccountOrSameAccountDifferentOrganizationIsNotPublished() {
        var blocked=ClaudeQuotaReadPolicy.failure(.network,key:"quota.claudeNetworkError");blocked.verifiedIdentity=a
        for identity in [b,.init(accountID:a.accountID,organizationID:b.organizationID)] {
            let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:{self.missing()},desktop:{blocked},oauth:{self.good(identity,source:.oauthAPI)},cache:{nil},now:now)
            XCTAssertEqual(result.status,.unavailable);XCTAssertTrue(result.buckets.isEmpty);XCTAssertFalse(result.requiresConnection)
        }
    }
    func testPinnedWebAccountCanReuseMatchingAppSessionWithoutAnotherLogin() {
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:true,expected:a,previous:nil,connected:{self.missing()},desktop:{self.good(self.a)},oauth:{self.missing()},cache:{nil},now:now)
        XCTAssertEqual(result.verifiedIdentity,a);XCTAssertFalse(result.requiresConnection)
    }
    func testRateLimitUsesPreviousTimestampAndNeverRequestsAnotherCredential() {
        var calls=0
        let limited=ClaudeQuotaReadPolicy.failure(.rateLimited,key:"quota.claudeRateLimited")
        let previous=good(a,age:90)
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:previous,connected:{self.missing()},desktop:{limited},oauth:{calls+=1;return self.good(self.a)},cache:{nil},now:now)
        XCTAssertEqual(calls,0);XCTAssertTrue(result.isCachedFallback)
        XCTAssertEqual(result.refreshedAt,previous.refreshedAt);XCTAssertEqual(result.buckets,previous.buckets)
    }
    func testFreshCacheWorksWithoutCredentialsButStaleOrFutureCacheDoesNot() {
        for age in [90.0,1201.0,-1.0] {
            let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:nil,connected:{self.missing()},desktop:{self.missing()},oauth:{self.missing()},cache:{self.good(nil,source:.desktopCache,age:age)},now:now)
            XCTAssertEqual(result.status,age==90 ? .available:.unavailable)
        }
    }
    func testOrganizationOnlyCacheCannotReplacePinnedPersonalQuota() {
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:true,expected:a,previous:nil,connected:{self.missing()},desktop:{self.missing()},oauth:{self.missing()},cache:{self.good(nil,source:.desktopCache)},now:now)
        XCTAssertEqual(result.status,.unavailable);XCTAssertTrue(result.buckets.isEmpty)
    }
    func testOAuthPrimaryFollowsAnExplicitAccountChangeInTheSameSource() {
        let result=ClaudeQuotaReadPolicy.resolve(selectedWeb:false,expected:nil,previous:good(a,source:.oauthAPI),connected:{self.missing()},desktop:{self.missing()},oauth:{self.good(self.b,source:.oauthAPI)},cache:{nil},now:now)
        XCTAssertEqual(result.verifiedIdentity,b)
    }
    func testServerProfileRejectsMissingIdentityAndSeparatesOrganizations() throws {
        let body=Data("{\"account\":{\"uuid\":\"\(a.accountID)\",\"email\":\"user@example.test\"},\"organization\":{\"uuid\":\"\(a.organizationID)\",\"organization_type\":\"claude_max\",\"rate_limit_tier\":\"default_claude_max_20x\"}}".utf8)
        let parsed=try XCTUnwrap(ClaudeQuotaService.decodeOAuthProfile(body))
        XCTAssertEqual(parsed.identity,a);XCTAssertEqual(parsed.planType,"max_20x")
        XCTAssertNil(ClaudeQuotaService.decodeOAuthProfile(Data(#"{"account":{"email":"user@example.test"}}"#.utf8)))
        XCTAssertNotEqual(a.key,ClaudeQuotaIdentity(accountID:a.accountID,organizationID:b.organizationID).key)
    }
    func testLocalReceiptTypesUsePathsWithoutReclassifyingModelsOrInventingChatUsage() {
        XCTAssertEqual(ClaudeUsageSurface.classify(path:"/home/.claude/projects/demo/a.jsonl"),.codeCLI)
        XCTAssertEqual(ClaudeUsageSurface.classify(path:"/Claude/claude-code-sessions/x/local_1/.claude/projects/demo/a.jsonl"),.codeApp)
        XCTAssertEqual(ClaudeUsageSurface.classify(path:"/Claude/local-agent-mode-sessions/x/local_1/.claude/projects/demo/a.jsonl"),.coworkApp)
    }
    final class Requests: @unchecked Sendable {
        let lock=NSLock();var values:[URLRequest]=[]
        func add(_ request:URLRequest) {lock.lock();values.append(request);lock.unlock()}
    }
    func profile(_ owner:ClaudeQuotaIdentity)->Data {
        Data("{\"account\":{\"uuid\":\"\(owner.accountID)\",\"email\":\"user@example.test\"},\"organization\":{\"uuid\":\"\(owner.organizationID)\",\"organization_type\":\"claude_pro\"}}".utf8)
    }
    func testOAuthProfileIsVerifiedBeforeQuotaAndDifferentOrgDoesNotGetUsageRequest() {
        let requests=Requests(),body=profile(b)
        let service=ClaudeQuotaService(claudeHome:"/missing-cli",environment:["CLAUDE_CODE_OAUTH_TOKEN":"synthetic-source-test"],homeDirectory:"/missing-home",oauthTransport:{ request in
            requests.add(request)
            return .init(statusCode:200,body:body)
        })
        let result=service.fetch(connectedSession:nil,connectionSelected:true,expectedIdentity:a.key)
        XCTAssertEqual(result.status,.unavailable)
        XCTAssertEqual(requests.values.map{$0.url!.lastPathComponent},["profile"])
        XCTAssertTrue(requests.values.allSatisfy{$0.url?.host=="api.anthropic.com" && $0.httpMethod=="GET" && !$0.httpShouldHandleCookies})
    }
    func testSameOwnerOAuthQuotaWorksWithoutCLIOrAppFiles() {
        let requests=Requests(),body=profile(a)
        let usage=Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":27}}"#.utf8)
        let service=ClaudeQuotaService(claudeHome:"/missing-cli",environment:["CLAUDE_CODE_OAUTH_TOKEN":"synthetic-source-test"],homeDirectory:"/missing-home",oauthTransport:{ request in
            requests.add(request)
            return .init(statusCode:200,body:request.url?.lastPathComponent=="profile" ? body:usage)
        })
        let result=service.fetch(connectedSession:nil,connectionSelected:true,expectedIdentity:a.key)
        XCTAssertEqual(result.status,.available);XCTAssertEqual(result.verifiedIdentity,a)
        XCTAssertEqual(result.account?.id,a.key)
        XCTAssertEqual(requests.values.map{$0.url!.lastPathComponent},["profile","usage"])
        XCTAssertTrue(requests.values.allSatisfy{$0.httpMethod=="GET"})
    }

}
#endif
