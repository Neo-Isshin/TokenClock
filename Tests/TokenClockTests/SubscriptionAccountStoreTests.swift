import Foundation
import XCTest
@testable import TokenClock

final class SubscriptionAccountStoreTests: XCTestCase {
    func testDialQuotaResolverMapsAntigravityModelGroups() throws {
        let groups = [
            ProviderQuotaGroup(id: "gemini", name: "Gemini Models", buckets: [
                quotaBucket("gw", used: 20, minutes: 10_080),
                quotaBucket("g5", used: 30, minutes: 300),
            ]),
            ProviderQuotaGroup(id: "other", name: "Claude and GPT models", buckets: [
                quotaBucket("ow", used: 40, minutes: 10_080),
                quotaBucket("o5", used: 50, minutes: 300),
            ]),
        ]
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(
            provider: .antigravity, groups: groups
        ))
        XCTAssertEqual(indicator.outerRemainingPercent, 80)
        XCTAssertEqual(indicator.innerRemainingPercent, 60)
        XCTAssertEqual(indicator.details.map(\.remainingPercent), [80, 70, 60, 50])
    }

    func testDialQuotaResolverMapsCursorModelGroups() throws {
        let groups = [ProviderQuotaGroup(id: "cursor", name: "Models", buckets: [
            quotaBucket("cursor", name: "Cursor Models", used: 2, minutes: 44_640),
            quotaBucket("other", name: "Other Models", used: 100, minutes: 44_640),
        ])]
        let indicator = try XCTUnwrap(DialQuotaResolver.resolve(provider: .cursor, groups: groups))
        XCTAssertEqual(indicator.outerRemainingPercent, 0)
        XCTAssertEqual(indicator.innerRemainingPercent, 98)
        XCTAssertEqual(indicator.details.map(\.labelKey), [
            "quota.dial.cursorModels", "quota.dial.otherModels",
        ])
    }

    func testOpaqueCredentialIdentifierIsStableAndDoesNotContainTheSecret() {
        let first = SubscriptionAccountIdentity.opaqueID(namespace: "zhipu", secret: "secret-api-key")
        let second = SubscriptionAccountIdentity.opaqueID(namespace: "zhipu", secret: "secret-api-key")
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("secret-api-key"))
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
        XCTAssertEqual(saved.manualPlan, "Pro 20x")
        XCTAssertEqual(saved.groups.first?.buckets.first?.usedPercent, 35)
    }

    func testDuplicatePersistedIDsRestoreWithoutCrashingAndKeepUserMetadata() throws {
        var older = record(id: "duplicate", email: "person@example.com", used: 10)
        older.note = "Work"
        older.manualPlan = "Pro 20x"
        older.refreshedAt = Date(timeIntervalSince1970: 10)
        var newer = record(id: "duplicate", email: "person@example.com", used: 75)
        newer.refreshedAt = Date(timeIntervalSince1970: 20)
        let account = try XCTUnwrap(SubscriptionAccountStore(restoring: [older, newer]).records().first)
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

private func quotaBucket(
    _ id: String,
    name: String = "Quota",
    used: Double,
    minutes: Int
) -> CodexQuotaBucket {
    CodexQuotaBucket(
        id: id, name: name, usedPercent: used,
        windowMinutes: minutes, resetsAt: nil
    )
}
