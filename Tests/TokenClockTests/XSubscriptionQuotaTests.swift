import Foundation
import XCTest
@testable import TokenClock

final class XSubscriptionQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private var plan: Data { Data(#"{"isMerged":true,"planInfo":{"planName":"Premium","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1793197625745","billingCycleEnd":"1794666425529","price":""}}"#.utf8) }
    private var usage: Data { Data(#"{"billingCycleStart":"1792592825745","billingCycleEnd":"1793197625745","planUsage":{"totalPercentUsed":64.13867822318527,"apiPercentUsed":0},"spendLimitUsage":{}}"#.utf8) }
    private var sand: Data { Data(#"{"isUnified":true,"cursorPlanName":"Premium","billingBrand":"SAND_BILLING_BRAND_GROK","usagePercent":64.13867822318527,"currentPeriodStart":"2026-10-21T14:27:05.745Z","nextResetTimestampUtc":"2026-10-28T14:27:05.745Z"}"#.utf8) }

    func testVerifiedEndpointsDecodeOneIdenticalWeeklyBucketWithoutBillingGuesses() throws {
        let cursor = try XCTUnwrap(XSubscriptionQuota.decodeCurrentPeriod(planData: plan, usageData: usage, now: now))
        let bot = try XCTUnwrap(GrokBotQuotaService.decodeResponse(sand, now: now))
        XCTAssertEqual(cursor.groups, bot.groups)
        XCTAssertEqual(cursor.planType, "Premium")
        XCTAssertEqual(bot.planType, "Premium")
        XCTAssertNil(cursor.billing)
        XCTAssertNil(bot.billing)
        let bucket = try XCTUnwrap(cursor.groups.first?.buckets.first)
        XCTAssertEqual(bucket.windowMinutes, 10_080)
        XCTAssertEqual(bucket.remainingPercent, 35.86132177681473, accuracy: 0.000001)
        XCTAssertEqual(bucket.resetsAt?.timeIntervalSince1970 ?? 0, 1_793_197_625.745, accuracy: 0.001)
    }

    func testMergedFlagMustBeAnActualBoolean() {
        XCTAssertEqual(XSubscriptionQuota.planKind(plan), .unified)
        XCTAssertEqual(XSubscriptionQuota.planKind(Data(#"{"isMerged":false}"#.utf8)), .legacy)
        for raw in [#"{"isMerged":"true"}"#, #"{"isMerged":1}"#, #"{"planInfo":{"planName":"Premium"}}"#] {
            XCTAssertEqual(XSubscriptionQuota.planKind(Data(raw.utf8)), .unknown)
        }
    }

    func testRejectsMonthlyWindowAndNonFiniteUsageForUnifiedSubscription() {
        let monthly = Data(#"{"billingCycleStart":"1790812800000","billingCycleEnd":"1793491200000","planUsage":{"totalPercentUsed":0}}"#.utf8)
        XCTAssertNil(XSubscriptionQuota.decodeCurrentPeriod(planData: plan, usageData: monthly))
        XCTAssertNil(XSubscriptionQuota.decodeCurrentPeriod(planData: plan, usageData: Data(#"{"planUsage":{}}"#.utf8)))
        let raw = String(data: sand, encoding: .utf8)!
        XCTAssertNil(GrokBotQuotaService.decodeResponse(Data(raw.replacingOccurrences(of: "64.13867822318527", with: "\"NaN\"").utf8)))
        XCTAssertNil(GrokBotQuotaService.decodeResponse(Data(#"{"isUnified":true,"usagePercent":0}"#.utf8)))
    }

    func testConfirmedUnifiedFailureCannotFallBackToOldMonthlyQuota() {
        let result = XSubscriptionQuota.discover(planData: plan, usage: { Data("{}".utf8) }, sand: { nil })
        guard case .unavailable = result else { return XCTFail("A failed shared pool must not become a legacy 100% monthly quota") }
        XCTAssertNil(CursorQuotaService.decodeResponse(Data(#"{"membershipType":"premium","individualUsage":{"plan":{"totalPercentUsed":0,"apiPercentUsed":0}}}"#.utf8)))
    }

    func testSandIsAnAuthoritativeUnifiedFallbackAndLegacyDiscoveryDoesNotReadIt() throws {
        let fallback = XSubscriptionQuota.discover(planData: nil, usage: { XCTFail("No verified plan"); return nil }, sand: { self.sand }, now: now)
        guard case .unified(let snapshot) = fallback else { return XCTFail("Expected verified Sand shared quota") }
        XCTAssertTrue(XSubscriptionQuota.contains(snapshot.groups))
        let legacy = XSubscriptionQuota.discover(planData: Data(#"{"isMerged":false}"#.utf8),
            usage: { XCTFail("Legacy account must keep its old usage path"); return nil },
            sand: { XCTFail("Unnecessary Sand request"); return nil })
        guard case .legacy = legacy else { return XCTFail("Legacy compatibility") }
        XCTAssertTrue(XSubscriptionQuota.knownLegacySummary(Data(#"{"membershipType":"pro_plus"}"#.utf8)))
        XCTAssertFalse(XSubscriptionQuota.knownLegacySummary(Data(#"{"membershipType":"premium"}"#.utf8)))
    }

    func testUnifiedDialUsesOneWeeklyRingNotLegacyCursorInnerOuterSplit() throws {
        let snapshot = try XCTUnwrap(XSubscriptionQuota.decodeCurrentPeriod(planData: plan, usageData: usage, now: now))
        for provider in [SubscriptionProvider.cursor, .grokBot] {
            let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: provider, groups: snapshot.groups))
            XCTAssertEqual(indicator.displayName, XSubscriptionQuota.title)
            XCTAssertNil(indicator.innerRemainingPercent)
            XCTAssertEqual(indicator.details.first?.labelKey, "quota.dial.weekly")
        }
    }

    private func account(_ provider: SubscriptionProvider, user: String = "user_SHARED", unified: Bool = true,
                         stale: Bool = false, email: String = "same@example.test") throws -> SubscriptionAccountRecord {
        let groups = try XCTUnwrap(XSubscriptionQuota.decodeSand(sand, now: now)).groups
        return SubscriptionAccountRecord(provider: provider, accountID: user, email: email, note: "",
            detectedPlan: unified ? "Premium" : "pro", manualPlan: nil,
            groups: unified ? groups : [ProviderQuotaGroup(id: "legacy", name: "Subscription", buckets: [
                CodexQuotaBucket(id: "legacy:weekly", name: "Legacy", usedPercent: 10, windowMinutes: 10_080,
                                 resetsAt: now.addingTimeInterval(86400))])],
            refreshedAt: stale ? now.addingTimeInterval(-3600) : now, source: "fixture",
            creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
    }

    func testDeduplicatesOnlySameAuthenticatedMergedAccountAndKeepsBothLegacyAccounts() throws {
        let cursor = try account(.cursor), bot = try account(.grokBot)
        let active: [SubscriptionProvider: String] = [.cursor: cursor.id, .grokBot: bot.id]
        let shown = XSubscriptionQuota.visibleAccounts([bot, cursor], activeIDs: active, selected: [], now: now)
        XCTAssertEqual(shown.map(\.id), [cursor.id])
        XCTAssertEqual(XSubscriptionQuota.dialProviders([.grokBot, .cursor], records: [cursor, bot], activeIDs: active, selectedIDs: [:], now: now), [.grokBot])
        let other = try account(.grokBot, user: "user_OTHER")
        XCTAssertEqual(XSubscriptionQuota.visibleAccounts([cursor, other], activeIDs: [:], selected: [], now: now).count, 2,
            "Same email and percentage are not proof of a shared subscription")
        let old = try account(.grokBot, unified: false)
        XCTAssertEqual(XSubscriptionQuota.visibleAccounts([cursor, old], activeIDs: [:], selected: [], now: now).count, 2)
        let anonymous = try account(.cursor, user: "active")
        XCTAssertNil(XSubscriptionQuota.accountKey(anonymous))
        var differentWindow = bot
        let bucket = try XCTUnwrap(bot.groups.first?.buckets.first)
        differentWindow.groups = [ProviderQuotaGroup(id: XSubscriptionQuota.groupID, name: "Subscription", buckets: [
            CodexQuotaBucket(id: bucket.id, name: bucket.name, usedPercent: bucket.usedPercent, windowMinutes: 10_080,
                             resetsAt: bucket.resetsAt?.addingTimeInterval(86400))])]
        XCTAssertEqual(XSubscriptionQuota.visibleAccounts([cursor, differentWindow], activeIDs: active, selected: [], now: now).count, 2,
            "Different observed quota windows must not be guessed to be the same pool")
    }

    func testSelectionAndPinnedAccountBoundariesArePreserved() throws {
        let cursor = try account(.cursor), bot = try account(.grokBot)
        let records = [cursor, bot]
        let active: [SubscriptionProvider: String] = [.cursor: cursor.id, .grokBot: bot.id]
        XCTAssertEqual(XSubscriptionQuota.visibleAccounts(records, activeIDs: active, selected: [.grokBot], now: now).map(\.id), [bot.id])
        XCTAssertEqual(XSubscriptionQuota.dialProviders([.cursor, .grokBot], records: records,
            activeIDs: active, selectedIDs: [.cursor: "cursor::user_PREVIOUS"], now: now), [.cursor, .grokBot])
        XCTAssertEqual(XSubscriptionQuota.dialProviders([], records: records, activeIDs: active, selectedIDs: [:], now: now), [])
        let stale = try account(.cursor, stale: true)
        XCTAssertEqual(XSubscriptionQuota.visibleAccounts([stale, bot], activeIDs: active, selected: [], now: now).map(\.id), [bot.id])
    }

    func testMigrationDropsOldDetectedRenewalButPreservesUserEditsAndLegacyCodableData() throws {
        var old = try account(.cursor, unified: false)
        old.note = "Keep my account name"
        old.manualPlan = "Custom plan label"
        old.detectedBilling = SubscriptionBillingInfo(date: now.addingTimeInterval(3600), cycle: .monthly,
            autoRenews: true, source: "Cursor billing", observedAt: now)
        let store = SubscriptionAccountStore(restoring: [old])
        let shared = try account(.cursor)
        let updated = try XCTUnwrap(store.merge(shared).first)
        XCTAssertNil(updated.detectedBilling)
        XCTAssertNil(updated.effectiveBilling)
        XCTAssertNil(updated.creditBalance)
        XCTAssertEqual(updated.note, old.note)
        XCTAssertEqual(updated.manualPlan, old.manualPlan)
        let decoded = try JSONDecoder().decode(SubscriptionAccountRecord.self, from: JSONEncoder().encode(old))
        XCTAssertFalse(decoded.isUnifiedSubscription)
        XCTAssertNotNil(decoded.effectiveBilling)
        var manual = shared
        manual.manualBilling = old.detectedBilling
        XCTAssertNotNil(manual.effectiveBilling, "Manual dates remain user input, not inferred billing")
    }

    func testLiveMergedAccountWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_UNIFIED_X_QUOTA_TESTS"] == "1" else {
            throw XCTSkip("Explicit opt-in for read-only live unified-account validation")
        }
        let cursor = CursorQuotaService().fetch()
        let bot = GrokBotQuotaService(environment: ["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN": "1"],
                                      homeDirectory: "/tokenclock/no-cli-credential").fetch()
        XCTAssertEqual(cursor.status, .available, cursor.message ?? "")
        XCTAssertEqual(bot.status, .available, bot.message ?? "")
        XCTAssertTrue(XSubscriptionQuota.contains(cursor.groups))
        XCTAssertTrue(XSubscriptionQuota.contains(bot.groups))
        XCTAssertNotNil(cursor.account)
        XCTAssertEqual(cursor.account?.id, bot.account?.id)
        XCTAssertEqual(cursor.groups.first?.buckets.first?.resetsAt, bot.groups.first?.buckets.first?.resetsAt)
        XCTAssertNil(cursor.billing)
        XCTAssertNil(bot.billing)
    }
}
