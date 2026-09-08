import Foundation
import XCTest
@testable import TokenClock

final class SubscriptionAccountStoreTests: XCTestCase {
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
        var older = record(id: "same", email: "person@example.com", used: 10)
        older.note = "Work"
        older.manualPlan = "Pro 20x"
        older.refreshedAt = Date(timeIntervalSince1970: 100)
        var newer = record(id: "same", email: "person@example.com", used: 35)
        newer.refreshedAt = Date(timeIntervalSince1970: 200)
        let restored = SubscriptionAccountStore(restoring: [older, newer]).records()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.groups.first?.buckets.first?.usedPercent, 35)
        XCTAssertEqual(restored.first?.note, "Work")
        XCTAssertEqual(restored.first?.manualPlan, "Pro 20x")
    }

    private func record(id: String, email: String, used: Double) -> SubscriptionAccountRecord {
        SubscriptionAccountRecord(
            provider: .codex,
            accountID: id,
            email: email,
            note: "",
            detectedPlan: "pro",
            manualPlan: nil,
            groups: [group(used: used)],
            refreshedAt: Date(),
            source: "test",
            creditBalance: nil,
            hasUnlimitedCredits: false,
            resetCreditCount: 0
        )
    }

    private func group(used: Double) -> ProviderQuotaGroup {
        ProviderQuotaGroup(
            id: "test", name: "Subscription",
            buckets: [CodexQuotaBucket(
                id: "weekly", name: "Codex", usedPercent: used,
                windowMinutes: 10_080, resetsAt: nil
            )]
        )
    }
}
