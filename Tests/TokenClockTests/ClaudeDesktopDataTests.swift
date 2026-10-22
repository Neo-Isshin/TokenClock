import XCTest
@testable import TokenClock

final class ClaudeDesktopDataTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_900_000_000)
    private func data(samples:[[String:Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":2,"samples":samples])
    }
    private func sample(age:TimeInterval=20,org:String="org-one",usage:[String:Any]=["fh":25,"sd":70]) -> [String:Any] {
        ["t":now.addingTimeInterval(-age).timeIntervalSince1970*1000,"org":org,"u":usage]
    }
    func testReadsActualDesktopUtilizationWithoutInventingResetTimeOrUserIdentity() throws {
        let value=try XCTUnwrap(ClaudeDesktopData.decodeUsageHistory(data(samples:[sample()]),now:now))
        XCTAssertEqual(value.source,.desktopCache)
        XCTAssertEqual(value.buckets.map(\.remainingPercent),[75,30])
        XCTAssertTrue(value.buckets.allSatisfy { $0.resetsAt == nil })
        XCTAssertNil(value.account?.email)
        XCTAssertEqual(value.refreshedAt,now.addingTimeInterval(-20))
        let indicator=try XCTUnwrap(DialQuotaResolver.resolve(provider:.claude,groups:[ProviderQuotaGroup(id:"claude",name:"Subscription",buckets:value.buckets)]))
        XCTAssertEqual(indicator.outerRemainingPercent,30)
        XCTAssertEqual(indicator.innerRemainingPercent,75)
    }
    func testRejectsStaleFutureAmbiguousAndMalformedCaches() throws {
        XCTAssertNil(ClaudeDesktopData.decodeUsageHistory(try data(samples:[sample(age:601)]),now:now))
        XCTAssertNil(ClaudeDesktopData.decodeUsageHistory(try data(samples:[sample(age:-10)]),now:now))
        XCTAssertNil(ClaudeDesktopData.decodeUsageHistory(try data(samples:[sample(),sample(org:"other")]),now:now))
        XCTAssertNil(ClaudeDesktopData.decodeUsageHistory(try data(samples:[sample(usage:["fh":true,"sd":101])]),now:now))
    }
    func testModelSpecificQuotaCannotOverrideOverallSubscriptionRing() throws {
        let buckets=[
            CodexQuotaBucket(id:"claude:seven_day",name:"Claude",usedPercent:30,windowMinutes:10080,resetsAt:nil),
            CodexQuotaBucket(id:"claude:seven_day_opus",name:"Opus",usedPercent:100,windowMinutes:10080,resetsAt:nil),
            CodexQuotaBucket(id:"claude:seven_day_oauth_apps",name:"Apps",usedPercent:100,windowMinutes:10080,resetsAt:nil)]
        let indicator=try XCTUnwrap(DialQuotaResolver.resolve(provider:.claude,groups:[ProviderQuotaGroup(id:"claude",name:"Subscription",buckets:buckets)]))
        XCTAssertEqual(indicator.outerRemainingPercent,70)
    }
    func testServiceCanUseFreshDesktopCacheWithoutCodeLoginOrKeychain() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("claude-cache-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home=try XCTUnwrap(ClaudeDesktopData.homes(home:root.path,environment:["APPDATA":root.appendingPathComponent("appdata").path,"XDG_CONFIG_HOME":root.appendingPathComponent("config").path]).first)
        try FileManager.default.createDirectory(atPath:home,withIntermediateDirectories:true)
        let receipt:[String:Any]=["t":Date().addingTimeInterval(-5).timeIntervalSince1970*1000,"org":"only-org","u":["fh":25,"sd":70]]
        try data(samples:[receipt]).write(to:URL(fileURLWithPath:home).appendingPathComponent("plan-usage-history.json"))
        let service=ClaudeQuotaService(claudeHome:root.appendingPathComponent("cli").path,environment:["APPDATA":root.appendingPathComponent("appdata").path,"XDG_CONFIG_HOME":root.appendingPathComponent("config").path],homeDirectory:root.path)
        let value=service.fetch()
        XCTAssertEqual(value.status,.available)
        XCTAssertEqual(value.source,.desktopCache)
        XCTAssertEqual(value.buckets.map(\.remainingPercent),[75,30])
    }
    #if os(macOS)
    func testConfiguredCustomHomeFindsItsHashedKeychainServiceWithoutShellEnvironment() {
        let services=ClaudeQuotaService.macOSKeychainServices(environment:[:],configuredClaudeHome:"/custom/claude",defaultClaudeHome:"/home/test/.claude")
        XCTAssertTrue(services.first?.hasPrefix("Claude Code-credentials-") == true)
        XCTAssertEqual(services.count,3)
    }
    #endif
}
