import XCTest
@testable import TokenClock

final class SubscriptionBillingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func account(info: SubscriptionBillingInfo?, days: Int = 3, enabled: Bool = true) -> SubscriptionAccountRecord {
        var value = SubscriptionAccountRecord(provider: .codex, accountID: "account", email: "a@example.com",
            note: "Work", detectedPlan: "pro", manualPlan: nil, groups: [], refreshedAt: nil, source: "test",
            creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
        value.detectedBilling = info
        value.billingReminders = BillingReminderSettings(enabled: enabled, days: days)
        return value
    }
    private func isolated(_ run: (UserDefaults) throws -> Void) throws {
        let name = "TokenClock.BillingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults)
    }
    func testOpenAIDecodesActualRenewalAndCancellation() throws {
        let active = Data(#"{"will_renew":true,"active_until":"2026-10-22T15:04:20Z","billing_period":"monthly"}"#.utf8)
        let info = try XCTUnwrap(BillingParser.openAI(active))
        XCTAssertEqual(info.date, date("2026-10-22T15:04:20Z"))
        XCTAssertEqual(info.autoRenews, true); XCTAssertEqual(info.cycle, .monthly)
        let canceled = Data(#"{"will_renew":false,"active_until":"2026-10-22T15:04:20Z","billing_period":"annual"}"#.utf8)
        XCTAssertEqual(BillingParser.openAI(canceled)?.autoRenews, false)
        XCTAssertNil(BillingParser.openAI(Data(#"{"resets_at":1800000000,"window_minutes":10080}"#.utf8)))
    }
    func testCursorMonthlyAnnualCancellationAndTeams() throws {
        let usage = Data(#"{"billingCycleStart":"2026-09-24T00:27:33.000Z","billingCycleEnd":"2026-10-24T00:27:33.000Z"}"#.utf8)
        let monthly = Data(#"{"subscriptionStatus":"active","isYearlyPlan":false,"isTeamMember":false,"pendingCancellationDate":null}"#.utf8)
        XCTAssertEqual(BillingParser.cursor(subscription: monthly, usage: usage)?.autoRenews, true)
        let annual = Data(#"{"subscriptionStatus":"active","isYearlyPlan":true,"isTeamMember":false,"pendingCancellationDate":null}"#.utf8)
        let annualInfo = try XCTUnwrap(BillingParser.cursor(subscription: annual, usage: usage))
        XCTAssertEqual(annualInfo.cycle, .yearly); XCTAssertNil(annualInfo.date)
        let canceled = Data(#"{"subscriptionStatus":"active","isYearlyPlan":true,"isTeamMember":false,"pendingCancellationDate":"2027-01-01T00:00:00Z"}"#.utf8)
        XCTAssertEqual(BillingParser.cursor(subscription: canceled, usage: usage)?.autoRenews, false)
        let team = Data(#"{"subscriptionStatus":"active","isYearlyPlan":false,"isTeamMember":true,"pendingCancellationDate":null}"#.utf8)
        XCTAssertNil(BillingParser.cursor(subscription: team, usage: usage)?.date)
        XCTAssertNil(BillingParser.cursor(subscription: Data("{}".utf8), usage: usage))
    }
    func testReminderOptionsAndThresholds() throws {
        XCTAssertEqual(BillingReminderSettings.dayOptions, [1,2,3,7])
        XCTAssertEqual(BillingReminderSettings(days: 5).safeDays, 3)
        let now = date("2026-09-27T12:00:00Z")
        for days in BillingReminderSettings.dayOptions {
            try isolated { defaults in
                let due = calendar.date(byAdding: .day, value: days, to: now)!
                let info = SubscriptionBillingInfo(date: due, cycle: .monthly, autoRenews: true, source: "test", observedAt: now)
                XCTAssertEqual(BillingReminderStore.notifications(accounts: [account(info: info, days: days)],
                    now: now, calendar: calendar, defaults: defaults).count, 1)
            }
            try isolated { defaults in
                let due = calendar.date(byAdding: .day, value: days + 1, to: now)!
                let info = SubscriptionBillingInfo(date: due, cycle: .monthly, autoRenews: true, source: "test", observedAt: now)
                XCTAssertTrue(BillingReminderStore.notifications(accounts: [account(info: info, days: days)],
                    now: now, calendar: calendar, defaults: defaults).isEmpty)
            }
        }
    }
    func testRemindersSurviveRestartAndDoNotRepeatAfterReading() throws {
        try isolated { defaults in
            let now = date("2026-09-27T12:00:00Z")
            let info = SubscriptionBillingInfo(date: date("2026-09-29T12:00:00Z"), cycle: .monthly, autoRenews: true, source: "test", observedAt: now)
            let records = [account(info: info)]
            let first = BillingReminderStore.notifications(accounts: records, now: now, calendar: calendar, defaults: defaults)
            XCTAssertEqual(first.first?.subscriptionAccountID, "codex::account")
            BillingReminderStore.markRead(defaults: defaults)
            let repeated = BillingReminderStore.notifications(accounts: records, now: now.addingTimeInterval(60), calendar: calendar, defaults: defaults)
            XCTAssertEqual(repeated.count, 1); XCTAssertEqual(repeated.first?.id, first.first?.id)
            XCTAssertEqual(repeated.first?.isRead, true)
        }
    }
    func testMissingStaleDisabledAndPastDatesDoNotNotify() throws {
        let now = date("2026-09-27T12:00:00Z")
        for (date, age, enabled) in [(Optional<Date>.none, 0.0, true),
                                     (Optional(now), 9 * 86400.0, true),
                                     (Optional(now), 0.0, false),
                                     (Optional(now.addingTimeInterval(-86400)), 0.0, true)] {
            try isolated { defaults in
                let info = SubscriptionBillingInfo(date: date, cycle: .unknown, autoRenews: false,
                    source: "test", observedAt: now.addingTimeInterval(-age))
                XCTAssertTrue(BillingReminderStore.notifications(accounts: [account(info: info, enabled: enabled)],
                    now: now, calendar: calendar, defaults: defaults).isEmpty)
            }
        }
    }
    func testCalendarAnchorsKeepMonthEndAndLeapDay() throws {
        let monthly = SubscriptionBillingInfo(date: date("2026-01-31T12:00:00Z"), cycle: .monthly, autoRenews: true, source: "manual", observedAt: Date())
        XCTAssertEqual(monthly.nextDate(now: date("2026-02-10T12:00:00Z"), calendar: calendar), date("2026-02-28T12:00:00Z"))
        XCTAssertEqual(monthly.nextDate(now: date("2026-03-10T12:00:00Z"), calendar: calendar), date("2026-03-31T12:00:00Z"))
        let yearly = SubscriptionBillingInfo(date: date("2024-02-29T12:00:00Z"), cycle: .yearly, autoRenews: true, source: "manual", observedAt: Date())
        XCTAssertEqual(yearly.nextDate(now: date("2025-02-01T12:00:00Z"), calendar: calendar), date("2025-02-28T12:00:00Z"))
    }
    func testQuotaMergePreservesManualBillingAndReminderChoice() throws {
        let store = SubscriptionAccountStore(persistenceEnabled: false)
        let first = account(info: nil)
        _ = store.merge(first)
        let info = SubscriptionBillingInfo(date: Date(), cycle: .yearly, autoRenews: false, source: "manual", observedAt: Date())
        _ = store.updateBilling(id: first.id, edit: SubscriptionBillingEdit(manual: info, reminders: BillingReminderSettings(enabled: false, days: 2)))
        _ = store.merge(first)
        XCTAssertEqual(store.records().first?.manualBilling, info)
        XCTAssertEqual(store.records().first?.billingReminders?.days, 2)
        XCTAssertEqual(store.records().first?.billingReminders?.enabled, false)
    }
    func testCancellationUpdatesReminderWithoutAnotherDelivery() throws {
        try isolated { defaults in
            let now = date("2026-09-27T12:00:00Z")
            var info = SubscriptionBillingInfo(date: date("2026-09-29T12:00:00Z"), cycle: .monthly,
                autoRenews: true, source: "test", observedAt: now)
            let first = try XCTUnwrap(BillingReminderStore.notifications(accounts: [account(info: info)],
                now: now, calendar: calendar, defaults: defaults).first)
            BillingReminderStore.markRead(defaults: defaults)
            info.autoRenews = false
            let canceled = try XCTUnwrap(BillingReminderStore.notifications(accounts: [account(info: info)],
                now: now, calendar: calendar, defaults: defaults).first)
            XCTAssertEqual(canceled.id, first.id); XCTAssertTrue(canceled.isRead)
            XCTAssertNotEqual(canceled.title, first.title)
            info.date = nil
            XCTAssertTrue(BillingReminderStore.notifications(accounts: [account(info: info)],
                now: now, calendar: calendar, defaults: defaults).isEmpty)
        }
    }
    func testCredentialIdentityCannotCrossWorkspacesOrAccounts() {
        let a = SubscriptionAccountIdentity(id: "workspace-a", email: "same@example.com")
        XCTAssertFalse(OpenAISubscriptionBilling.matches(a, credentialID: "workspace-b", email: "same@example.com"))
        XCTAssertTrue(OpenAISubscriptionBilling.matches(a, credentialID: "workspace-a", email: nil))
        let fallback = SubscriptionAccountIdentity(id: "same@example.com", email: "same@example.com")
        XCTAssertTrue(OpenAISubscriptionBilling.matches(fallback, credentialID: "workspace-a", email: "same@example.com"))
        XCTAssertFalse(OpenAISubscriptionBilling.matches(fallback, credentialID: "workspace-a", email: "other@example.com"))
    }
    func testInactiveSubscriptionClearsPreviouslyKnownDate() throws {
        let data = Data(#"{"will_renew":false,"active_until":null}"#.utf8)
        let info = try XCTUnwrap(BillingParser.openAI(data))
        XCTAssertNil(info.date)
        XCTAssertEqual(info.autoRenews, false)
    }
    func testSameEmailDoesNotMoveBillingBetweenDistinctWorkspaceIDs() {
        let first = account(info: nil)
        var second = account(info: nil)
        second = SubscriptionAccountRecord(provider: .codex, accountID: "other-workspace", email: first.email,
            note: "", detectedPlan: "business", manualPlan: nil, groups: [], refreshedAt: nil,
            source: "test", creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
        let store = SubscriptionAccountStore(restoring: [first])
        _ = store.updateBilling(id: first.id, edit: SubscriptionBillingEdit(
            manual: SubscriptionBillingInfo(date: Date(), cycle: .monthly, autoRenews: true, source: "manual", observedAt: Date()),
            reminders: BillingReminderSettings()))
        _ = store.merge(second)
        XCTAssertEqual(store.records().count, 2)
        XCTAssertNil(store.records().first(where: { $0.id == second.id })?.manualBilling)
    }
    func testLegacyRecordsDecodeWithoutBillingFields() throws {
        let original = account(info: nil)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["detectedBilling","manualBilling","billingReminders"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(SubscriptionAccountRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.accountID, original.accountID)
        XCTAssertNil(decoded.effectiveBilling)
        XCTAssertNil(decoded.billingReminders)
    }
    func testLiveBillingMetadata() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_VERIFY_BILLING"] == "1" else {
            throw XCTSkip("Opt-in read-only subscription integration")
        }
        let codex = CodexQuotaService().fetch()
        XCTAssertNotNil(codex.billing?.date)
        let cursor = CursorQuotaService().fetch()
        XCTAssertNotNil(cursor.billing)
    }
}
