import AppKit
import XCTest
@testable import TokenClock

final class StatusSummaryTests: XCTestCase {
    private func tool(_ name: String, tokens: Int, cache: Int = 0, messages: Int = 1) -> ToolUsage {
        var value = ToolUsage(name: name, abbreviation: name, emoji: "", todayTokens: tokens,
                              todayMessages: messages, isActive: false, recentTokens: 0, hourlyTokens: 0)
        value.todayCacheReadTokens = cache
        return value
    }

    func testSummaryUsesDialCacheBasisForTotalsAndRanking() {
        let tools = [tool("Codex", tokens: 100, cache: 900), tool("ZCode", tokens: 400)]
        let excluding = StatusSummarySnapshot(tools: tools, includesCache: false)
        XCTAssertEqual(excluding.totalTokens, 500)
        XCTAssertEqual(excluding.rankedTools.map(\.name), ["ZCode", "Codex"])
        let including = StatusSummarySnapshot(tools: tools, includesCache: true)
        XCTAssertEqual(including.totalTokens, 1_400)
        XCTAssertEqual(including.rankedTools.map(\.name), ["Codex", "ZCode"])
        XCTAssertEqual(including.totalMessages, 2)
        XCTAssertEqual(including.rankedTools.reduce(0) { $0 + including.tokens(for: $1) }, including.totalTokens)
        let cacheOnly = StatusSummarySnapshot(tools: [tool("Cache", tokens: 0, cache: 100, messages: 0)], includesCache: true)
        XCTAssertEqual(cacheOnly.rankedTools.count, 1)
        XCTAssertEqual(cacheOnly.totalTokens, 100)
    }

    func testCreditsAndOtherPeriodsCannotAppearAsTodayTokens() {
        var credit = tool("Credits", tokens: 10_000, messages: 50)
        credit.measurementUnit = .credits
        var lifetime = tool("Lifetime", tokens: 20_000, messages: 100)
        lifetime.measurementScope = .lifetime
        let summary = StatusSummarySnapshot(tools: [credit, lifetime, tool("Codex", tokens: 100)], includesCache: true)
        XCTAssertEqual(summary.totalTokens, 100)
        XCTAssertEqual(summary.totalMessages, 1)
        XCTAssertEqual(summary.rankedTools.map(\.name), ["Codex"])
    }

    func testEmptyAndMessageOnlySnapshots() {
        let empty = StatusSummarySnapshot(tools: [tool("Idle", tokens: 0, messages: 0)], includesCache: false)
        XCTAssertTrue(empty.rankedTools.isEmpty)
        let message = StatusSummarySnapshot(tools: [tool("Codex", tokens: 0, messages: 3)], includesCache: false)
        XCTAssertEqual(message.rankedTools.count, 1)
        XCTAssertEqual(message.totalTokens, 0)
        XCTAssertEqual(message.totalMessages, 3)
    }

    func testHourlyBarsPreserveDayBoundariesMissingHoursAndEnabledTools() {
        let day = "2026-10-28"
        func snapshot(_ key: String, _ name: String = "Codex", tokens: Int = 100, cache: Int? = 30) -> DaySnapshot {
            DaySnapshot(date: key, totalTokens: tokens, totalMessages: 1, tools: [
                DaySnapshot.Tool(name: name, tokens: tokens, messages: 1, cacheRate: 0,
                    isActive: false, cost: .zero, cacheReadTokens: cache, sessions: [])])
        }
        let hourly = StatusSummaryHourlyData.build([
            snapshot(day + "-00"), snapshot(day + "-23", tokens: 200, cache: nil),
            snapshot(day + "-00", "Disabled", tokens: 900),
            snapshot("2026-10-27-23"), snapshot(day + "-24"), snapshot(day)
        ], day: day, tools: ["Codex"])
        XCTAssertEqual(hourly.hours.count, 24)
        XCTAssertEqual(hourly.hours[0].displayedTokens(includingCache: false), 100)
        XCTAssertEqual(hourly.hours[0].displayedTokens(includingCache: true), 130)
        XCTAssertTrue(hourly.hours[0].cacheIsExact)
        XCTAssertFalse(hourly.hours[1].hasRecords)
        XCTAssertTrue(hourly.hours[23].hasRecords)
        XCTAssertFalse(hourly.hours[23].cacheIsExact)
        XCTAssertEqual(hourly.hours.reduce(0) { $0 + $1.tokens }, 300)
    }

    func testHarnessSpeedWeightsRequestsAndExcludesOldModelsAndOtherProviders() throws {
        let store = GenerationSpeedStore(), now = Date(timeIntervalSince1970: 1_792_800_000)
        func sample(_ id: String, model: String, output: Int, seconds: Double, ago: Double) -> GenerationSample {
            GenerationSample(id: id, model: model, completedAt: now.addingTimeInterval(-ago),
                             outputTokens: output, seconds: seconds, estimated: false)
        }
        let samples = [sample("a", model: "gpt-6-astra", output: 100, seconds: 2, ago: 2),
            sample("b", model: "gpt-6.1-sol", output: 900, seconds: 9, ago: 1),
            sample("old", model: "gpt-5.4", output: 90_000, seconds: 1, ago: 3_600),
            sample("invalid", model: "gpt-6-astra", output: 100, seconds: 0, ago: 0)]
        store.replace(provider: "Codex", with: samples, now: now)
        store.replace(provider: "ZCode", with: [sample("other", model: "glm-5.3", output: 90_000, seconds: 1, ago: 1)], now: now)
        let speed = store.summary(provider: "Codex", now: now)
        XCTAssertEqual(try XCTUnwrap(speed.tokensPerSecond), 1000.0 / 11, accuracy: 0.000001)
        XCTAssertEqual(speed.sampleCount, 2)
        store.replace(provider: "Codex", with: [], now: now.addingTimeInterval(3_600))
        XCTAssertEqual(store.summary(provider: "Codex", now: now.addingTimeInterval(3_600)), speed)
        XCTAssertNil(store.summary(provider: "Claude Code", now: now).tokensPerSecond)
    }

    func testSummaryQuotaRefreshIsOnOpenWithThreeMinuteCooldown() {
        var schedule = StatusSummaryQuotaSchedule()
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        XCTAssertTrue(schedule.shouldRefresh(now: now))
        XCTAssertFalse(schedule.shouldRefresh(now: now.addingTimeInterval(179)))
        XCTAssertTrue(schedule.shouldRefresh(now: now.addingTimeInterval(180)))
        XCTAssertTrue(schedule.shouldRefresh(now: now.addingTimeInterval(-1)))
    }

    func testSummaryCredentialFallbackCannotInvokeInteractiveKeychainCLI() {
        let missing = StatusSummaryQuotaCredentials.environment([:]) { nil }
        XCTAssertEqual(missing["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN"], "1")
        XCTAssertNil(missing["CURSOR_AUTH_TOKEN"])
        let existing = StatusSummaryQuotaCredentials.environment(["CURSOR_AUTH_TOKEN": "existing-test-token"]) {
            XCTFail("An existing explicit token has priority"); return nil
        }
        XCTAssertEqual(existing["CURSOR_AUTH_TOKEN"], "existing-test-token")
        let silent = StatusSummaryQuotaCredentials.environment([:]) { "silent-test-token" }
        XCTAssertEqual(silent["CURSOR_AUTH_TOKEN"], "silent-test-token")
        XCTAssertEqual(silent["TOKENCLOCK_DISABLE_CURSOR_CLI_KEYCHAIN"], "1")
    }

    private func quotaAccount(_ provider: SubscriptionProvider, user: String = "user", shared: Bool = false,
                              resetOffset: TimeInterval = 86_400) -> SubscriptionAccountRecord {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        return SubscriptionAccountRecord(provider: provider, accountID: user, email: "same@example.test", note: "",
            detectedPlan: "plan", manualPlan: nil,
            groups: [ProviderQuotaGroup(id: shared ? StatusSummaryQuotas.sharedGroupID : "weekly", name: "Subscription", buckets: [
                CodexQuotaBucket(id: "weekly", name: "Weekly quota", usedPercent: 20, windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(resetOffset))])],
            refreshedAt: now, source: "fixture", creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
    }

    func testSummaryDisplaysAllSixReadableProvidersWithoutDialSelectionLimit() {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        let records = SubscriptionProvider.allCases.map { quotaAccount($0) }
        let active = Dictionary(uniqueKeysWithValues: records.map { ($0.provider, $0.id) })
        let groups = Dictionary(uniqueKeysWithValues: records.map { ($0.provider, $0.groups) })
        let shown = StatusSummaryQuotas.indicators(records: records, activeIDs: active, freshGroups: groups, now: now)
        XCTAssertEqual(shown.map(\.provider), SubscriptionProvider.allCases)
        let stale = groups.mapValues { DialQuotaResolver.freshGroups($0, refreshedAt: now.addingTimeInterval(-3_600), now: now) }
        XCTAssertTrue(StatusSummaryQuotas.indicators(records: records, activeIDs: active, freshGroups: stale, now: now).isEmpty)
    }

    func testSummaryDeduplicatesOnlyVerifiedSharedAccountAndPeriod() {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        let cursor = quotaAccount(.cursor, shared: true)
        func shown(_ bot: SubscriptionAccountRecord) -> [StatusSummaryQuota] {
            StatusSummaryQuotas.indicators(records: [cursor, bot], activeIDs: [.cursor: cursor.id, .grokBot: bot.id],
                freshGroups: [.cursor: cursor.groups, .grokBot: bot.groups], now: now)
        }
        XCTAssertEqual(shown(quotaAccount(.grokBot, shared: true)).count, 1)
        XCTAssertEqual(shown(quotaAccount(.grokBot, shared: true)).first?.displayName, "X Subscription")
        XCTAssertEqual(shown(quotaAccount(.grokBot, user: "different", shared: true)).count, 2)
        XCTAssertEqual(shown(quotaAccount(.grokBot, shared: true, resetOffset: 172_800)).count, 2)
        let codex = quotaAccount(.codex)
        XCTAssertTrue(StatusSummaryQuotas.indicators(records: [codex], activeIDs: [:], freshGroups: [.codex: codex.groups], now: now).isEmpty)
    }

    @MainActor
    func testOpeningSummaryKeepsClockHiddenAndRestoresOnlyPreviouslyVisibleWindows() {
        _ = NSApplication.shared
        let clock = window(), hiddenSettings = window(), status = window()
        defer { [clock, hiddenSettings, status].forEach { $0.orderOut(nil) } }
        clock.orderFront(nil)
        status.orderFront(nil)
        let visibility = StatusSummaryHiddenWindows()
        visibility.hide([clock, hiddenSettings, status], excluding: status)
        XCTAssertFalse(clock.isVisible)
        XCTAssertFalse(hiddenSettings.isVisible)
        XCTAssertTrue(status.isVisible)
        // Reopening the summary while the clock is hidden must preserve its restore list.
        visibility.hide([clock, hiddenSettings, status], excluding: status)
        visibility.restore()
        XCTAssertTrue(clock.isVisible)
        XCTAssertFalse(hiddenSettings.isVisible)
        clock.orderOut(nil)
        visibility.restore()
        XCTAssertFalse(clock.isVisible)
    }

    @MainActor
    func testHiddenWindowTrackingDoesNotRetainClosedWindows() {
        _ = NSApplication.shared
        let visibility = StatusSummaryHiddenWindows()
        weak var reference: NSWindow?
        autoreleasepool {
            let temporary = window()
            temporary.isReleasedWhenClosed = false
            reference = temporary
            temporary.orderFront(nil)
            visibility.hide([temporary], excluding: nil)
            temporary.close()
        }
        XCTAssertNil(reference)
        visibility.restore()
    }

    @MainActor
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                 styleMask: .borderless, backing: .buffered, defer: false)
    }
}
