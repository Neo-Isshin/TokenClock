import Foundation
import XCTest
@testable import TokenClock

final class SubscriptionAccountStoreTests: XCTestCase {
    func testDefaultDialProviderChoosesMostConsumedQuotaThenPanelOrder() throws {
        let codex = DialQuotaIndicator(
            provider: .codex, outerRemainingPercent: 80,
            innerRemainingPercent: nil, details: []
        )
        let claude = DialQuotaIndicator(
            provider: .claude, outerRemainingPercent: 30,
            innerRemainingPercent: nil, details: []
        )
        XCTAssertEqual(
            DialQuotaResolver.defaultProvider(
                from: [codex, claude], providerOrder: [.codex, .claude]
            ),
            .claude
        )

        let tiedCodex = DialQuotaIndicator(
            provider: .codex, outerRemainingPercent: 30,
            innerRemainingPercent: nil, details: []
        )
        let tiedClaude = DialQuotaIndicator(
            provider: .claude, outerRemainingPercent: 30,
            innerRemainingPercent: nil, details: []
        )
        XCTAssertEqual(
            DialQuotaResolver.defaultProvider(
                from: [tiedCodex, tiedClaude, tiedCodex],
                providerOrder: [.claude, .claude, .codex]
            ),
            .claude
        )
    }

    func testOpaqueCredentialIdentifierIsStableAndDoesNotContainTheSecret() {
        let first = SubscriptionAccountIdentity.opaqueID(namespace: "zhipu", secret: "secret-api-key")
        let second = SubscriptionAccountIdentity.opaqueID(namespace: "zhipu", secret: "secret-api-key")
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("secret-api-key"))
    }

    func testSameEmailMigratesToNewStableIDWithoutDuplicatingTheAccount() {
        let store = SubscriptionAccountStore(persistenceEnabled: false)
        let old = record(id: "email-fallback", email: "person@example.com", used: 10)
        _ = store.merge(old)
        _ = store.update(id: old.id, note: "Primary", manualPlan: "Pro 5x")
        _ = store.merge(record(id: "server-account-id", email: "PERSON@example.com", used: 20))
        let records = store.records().filter { $0.provider == .codex }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.accountID, "server-account-id")
        XCTAssertEqual(records.first?.note, "Primary")
        XCTAssertEqual(records.first?.manualPlan, "Pro 5x")
    }

    func testKeepsSwitchedAccountsAndPreservesUserOverrides() throws {
        let store = SubscriptionAccountStore(persistenceEnabled: false)
        let first = record(id: "first", email: "first@example.com", used: 20)
        _ = store.merge(first)
        _ = store.update(id: first.id, note: "Work", manualPlan: "Pro 20x")
        var refreshed = first
        refreshed.groups = [group(used: 35)]
        _ = store.merge(refreshed)
        _ = store.merge(record(id: "second", email: "second@example.com", used: 5))
        let records = store.records().filter { $0.provider == .codex }
        XCTAssertEqual(records.count, 2)
        let saved = try XCTUnwrap(records.first { $0.accountID == "first" })
        XCTAssertEqual(saved.displayName, "Work")
        XCTAssertEqual(saved.email, "first@example.com")
        XCTAssertTrue(saved.revealsEmailOnDemand)
        XCTAssertEqual(saved.effectivePlan, "Pro 20x")
        XCTAssertEqual(saved.groups.first?.buckets.first?.usedPercent, 35)
    }

    func testEmailIsTitleUntilANoteOverridesIt() {
        var value = record(id: "one", email: "one@example.com", used: 1)
        XCTAssertEqual(value.displayName, "one@example.com")
        XCTAssertFalse(value.revealsEmailOnDemand)
        value.note = "Personal"
        XCTAssertEqual(value.displayName, "Personal")
        XCTAssertTrue(value.revealsEmailOnDemand)
    }

    func testDuplicatePersistedIDsRestoreWithoutCrashingAndKeepUserMetadata() throws {
        var older = record(id: "duplicate", email: "person@example.com", used: 10)
        older.note = "Work"
        older.manualPlan = "Pro 20x"
        older.refreshedAt = Date(timeIntervalSince1970: 10)
        var newer = record(id: "duplicate", email: "person@example.com", used: 75)
        newer.refreshedAt = Date(timeIntervalSince1970: 20)
        let restored = SubscriptionAccountStore(restoring: [older, newer])
        let account = try XCTUnwrap(restored.records().first)
        XCTAssertEqual(account.note, "Work")
        XCTAssertEqual(account.manualPlan, "Pro 20x")
        XCTAssertEqual(account.groups.first?.buckets.first?.usedPercent, 75)
    }

    private func record(id: String, email: String, used: Double) -> SubscriptionAccountRecord {
        SubscriptionAccountRecord(
            provider: .codex, accountID: id, email: email, note: "", detectedPlan: "pro",
            manualPlan: nil, groups: [group(used: used)], refreshedAt: Date(), source: "test",
            creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0
        )
    }

    private func group(used: Double) -> ProviderQuotaGroup {
        ProviderQuotaGroup(id: "test", name: "Subscription", buckets: [CodexQuotaBucket(
            id: "weekly", name: "Codex", usedPercent: used, windowMinutes: 10_080, resetsAt: nil
        )])
    }
}
