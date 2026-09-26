import Foundation
import XCTest
@testable import TokenClock

final class QuotaAccountIdentityTests: XCTestCase {
    private func account(_ id: String, email: String? = nil, age: TimeInterval = 0) -> SubscriptionAccountRecord {
        SubscriptionAccountRecord(provider: .codex, accountID: id, email: email, note: "Primary",
            detectedPlan: "pro", manualPlan: "Pro 20x",
            groups: [ProviderQuotaGroup(id: "subscription", name: "Subscription", buckets: [
                CodexQuotaBucket(id: "weekly", name: "Codex", usedPercent: 23, windowMinutes: 10080, resetsAt: nil)
            ])], refreshedAt: Date().addingTimeInterval(-age), source: "test",
            creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
    }

    func testAnonymousLogDoesNotCreateOrOverwriteAnAccount() {
        let known = account("known", email: "person@example.com")
        let store = SubscriptionAccountStore(restoring: [known])
        let anonymous = account("active")
        let result = store.merge(anonymous)
        XCTAssertEqual(result, [known])
        XCTAssertEqual(store.records(), [known])
    }

    func testLegacyAnonymousSnapshotIsHiddenButNotMergedIntoRealAccount() throws {
        let known = account("known", email: "person@example.com")
        let legacy = account("active")
        let store = SubscriptionAccountStore(restoring: [legacy, known])
        XCTAssertEqual(store.records(), [known])
        let updated = store.update(id: known.id, note: "Work", manualPlan: nil)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.accountID, "known")
        XCTAssertEqual(updated.first?.email, known.email)
    }

    func testRealAccountsRemainSeparateEvenWhenOnlyOneIsLoggedIn() {
        let a = account("a", email: "a@example.com"), b = account("b", email: "b@example.com")
        let store = SubscriptionAccountStore(restoring: [a, b])
        XCTAssertEqual(store.records().count, 2)
        XCTAssertNil(DialQuotaAccountSelection.indicator(provider: .codex, selectedID: a.id,
            activeID: b.id, records: store.records(), liveGroups: b.groups))
        XCTAssertNil(DialQuotaAccountSelection.indicator(provider: .codex, selectedID: "missing",
            activeID: b.id, records: store.records(), liveGroups: b.groups))
    }

    func testPinnedAccountNeedsFreshIdentifiedDataAndShowsItsName() throws {
        let a = account("a")
        let indicator = try XCTUnwrap(DialQuotaAccountSelection.indicator(provider: .codex,
            selectedID: a.id, activeID: a.id, records: [a], liveGroups: a.groups))
        XCTAssertEqual(indicator.outerRemainingPercent, 77)
        XCTAssertEqual(indicator.accountName, "Primary")
        let stale = account("a", age: 3600)
        XCTAssertNil(DialQuotaAccountSelection.indicator(provider: .codex, selectedID: stale.id,
            activeID: stale.id, records: [stale], liveGroups: stale.groups))
        XCTAssertNil(DialQuotaAccountSelection.indicator(provider: .codex, selectedID: nil,
            activeID: nil, records: [a], liveGroups: a.groups))
    }

    func testSelectionPersistsAndMigratesOnlyWhenIdentityIsVerified() throws {
        let name = "TokenClock.QuotaAccountIdentityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let old = account("email-id", email: "person@example.com")
        let store = SubscriptionAccountStore(defaults: defaults)
        _ = store.merge(old)
        DialQuotaAccountSelection.select(old.id, for: .codex, defaults: defaults)
        XCTAssertEqual(DialQuotaAccountSelection.selectedID(for: .codex, defaults: defaults), old.id)
        _ = store.merge(account("active"))
        XCTAssertEqual(DialQuotaAccountSelection.selectedID(for: .codex, defaults: defaults), old.id)
        let updated = account("server-id", email: "PERSON@example.com")
        _ = store.merge(updated)
        XCTAssertEqual(DialQuotaAccountSelection.selectedID(for: .codex, defaults: defaults), updated.id)
        XCTAssertEqual(store.records().count, 1)
        DialQuotaAccountSelection.select(nil, for: .codex, defaults: defaults)
        XCTAssertNil(DialQuotaAccountSelection.selectedID(for: .codex, defaults: defaults))
    }

    func testNewMacCLIPathsArePreferredBeforeNodeWrapper() {
        let paths = CodexQuotaService.executableCandidatePaths(environment: [:], platform: .macOS,
                                                               homeDirectory: "/test")
        XCTAssertEqual(paths.first, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertLessThan(paths.firstIndex(of: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")!,
                          paths.firstIndex(of: "/opt/homebrew/bin/codex")!)
    }

    func testAccountDecoderNeverInventsAnIdentity() {
        XCTAssertNil(CodexQuotaService.decodeAccountResponse(Data(
            #"{"result":{"account":{"type":"chatgpt","email":"  ","planType":"pro"}}}"#.utf8)))
        let decoded = CodexQuotaService.decodeAccountResponse(Data(
            #"{"result":{"account":{"type":"chatgpt","id":"stable-id","email":"person@example.com"}}}"#.utf8))
        XCTAssertEqual(decoded?.id, "stable-id")
    }

    func testInstalledCodexReturnsIdentifiedLiveQuota() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_VERIFY_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Opt-in live account quota read")
        }
        let result = CodexQuotaService().fetch()
        XCTAssertEqual(result.source, .appServer)
        XCTAssertEqual(result.status, .available)
        XCTAssertNotNil(result.account)
        XCTAssertFalse(result.buckets.isEmpty)
    }
}
