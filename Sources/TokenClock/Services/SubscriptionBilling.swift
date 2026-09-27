import Foundation
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking
#endif

enum SubscriptionBillingCycle: String, Codable, CaseIterable, Sendable {
    case unknown, monthly, yearly
    var title: String {
        switch self {
        case .unknown: return BillingText.choose("Unknown / one-off", "未知／单次", "未知／單次")
        case .monthly: return BillingText.choose("Monthly", "月付", "月付")
        case .yearly: return BillingText.choose("Yearly", "年付", "年付")
        }
    }
}
struct SubscriptionBillingInfo: Codable, Equatable, Sendable {
    var date: Date?
    var cycle: SubscriptionBillingCycle
    var autoRenews: Bool?
    var source: String
    var observedAt: Date
    var isManual: Bool { source == "manual" }

    func nextDate(now: Date, calendar: Calendar) -> Date? {
        guard let date else { return nil }
        guard isManual, autoRenews == true, cycle != .unknown else { return date }
        let today = calendar.startOfDay(for: now)
        if calendar.startOfDay(for: date) >= today { return date }
        let component: Calendar.Component = cycle == .yearly ? .year : .month
        let delta = max(0, calendar.dateComponents([component], from: date, to: now).value(for: component) ?? 0)
        // Always advance from the original anchor, not a February-clamped intermediate date.
        for offset in delta...(delta + 2) {
            if let candidate = calendar.date(byAdding: component, value: offset, to: date),
               calendar.startOfDay(for: candidate) >= today { return candidate }
        }
        return nil
    }
    var eventTitle: String {
        if autoRenews == false { return BillingText.choose("Subscription expires", "订阅到期", "訂閱到期") }
        if autoRenews == true { return BillingText.choose("Subscription renews", "订阅续费", "訂閱續費") }
        return BillingText.choose("Subscription date", "订阅日期", "訂閱日期")
    }
}
struct BillingReminderSettings: Codable, Equatable, Sendable {
    static let dayOptions = [1, 2, 3, 7]
    var enabled = true
    var days = 3
    var safeDays: Int { Self.dayOptions.contains(days) ? days : 3 }
}
struct SubscriptionBillingEdit: Equatable {
    var manual: SubscriptionBillingInfo?
    var reminders: BillingReminderSettings
}

enum BillingText {
    static func choose(_ en: String, _ hans: String, _ hant: String) -> String {
        switch L10n.shared.language { case .en: return en; case .zhHans: return hans; case .zhHant: return hant }
    }
    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
    static var title: String { choose("Billing & reminders", "账单与提醒", "帳單與提醒") }
    static var manual: String { choose("Set billing date manually", "手动设置账单日期", "手動設定帳單日期") }
    static var autoRenew: String { choose("Auto-renewing subscription", "自动续订", "自動續訂") }
    static var reminder: String { choose("Remind before (days)", "提前提醒（天）", "提前提醒（天）") }
    static var enabled: String { choose("Renewal / expiry reminder", "续费／到期提醒", "續費／到期提醒") }
    static var localOnly: String { choose("Reminder settings only — this does not change or cancel your subscription.", "这里只设置提醒，不会修改或取消实际订阅。", "這裡只設定提醒，不會修改或取消實際訂閱。") }
    static var unavailable: String { choose("Billing date unavailable — set it manually", "未取得账单日期，可手动补充", "未取得帳單日期，可手動補充") }
    static func summary(_ info: SubscriptionBillingInfo?, now: Date = Date()) -> String {
        guard let info else { return unavailable }
        let source = info.isManual ? choose("Manual", "手动", "手動") : info.source
        guard let date = info.nextDate(now: now, calendar: .current) else { return "\(info.cycle.title) · \(source) · \(unavailable)" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium
        return "\(info.eventTitle): \(formatter.string(from: date)) · \(info.cycle.title) · \(source)"
    }
}

enum BillingParser {
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            guard seconds.isFinite, seconds > 946684800, seconds < 7258118400 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = value as? String else { return nil }
        if let number = Double(value) { return date(NSNumber(value: number)) }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
    static func openAI(_ data: Data, now: Date = Date()) -> SubscriptionBillingInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let willRenew = object["will_renew"] as? Bool,
              object.keys.contains("active_until") else { return nil }
        let end = date(object["active_until"])
        guard end != nil || object["active_until"] is NSNull else { return nil }
        let rawCycle = (object["billing_period"] as? String ?? "").lowercased()
        let cycle: SubscriptionBillingCycle = ["monthly", "month"].contains(rawCycle) ? .monthly :
            (["annual", "yearly", "year"].contains(rawCycle) ? .yearly : .unknown)
        return SubscriptionBillingInfo(date: end, cycle: cycle, autoRenews: willRenew,
                                       source: "ChatGPT billing", observedAt: now)
    }
    static func cursor(subscription: Data, usage: Data, now: Date = Date()) -> SubscriptionBillingInfo? {
        guard let stripe = try? JSONSerialization.jsonObject(with: subscription) as? [String: Any],
              let yearly = stripe["isYearlyPlan"] as? Bool,
              let team = stripe["isTeamMember"] as? Bool,
              let status = stripe["subscriptionStatus"] as? String else { return nil }
        let canceled = date(stripe["pendingCancellationDate"])
        let cycle: SubscriptionBillingCycle = yearly ? .yearly : .monthly
        if team { return SubscriptionBillingInfo(date: nil, cycle: cycle, autoRenews: nil, source: "Cursor team billing", observedAt: now) }
        if let canceled { return SubscriptionBillingInfo(date: canceled, cycle: cycle, autoRenews: false, source: "Cursor billing", observedAt: now) }
        if stripe["isOnStudentPlan"] as? Bool == true || (stripe.keys.contains("pendingCancellationDate") && !(stripe["pendingCancellationDate"] is NSNull)) {
            return SubscriptionBillingInfo(date: nil, cycle: .unknown, autoRenews: nil, source: "Cursor billing", observedAt: now)
        }
        if status != "active" { return SubscriptionBillingInfo(date: nil, cycle: cycle, autoRenews: false, source: "Cursor billing", observedAt: now) }
        guard status == "active", stripe.keys.contains("pendingCancellationDate") else { return nil }
        // Annual subscriptions can still have MONTHLY usage periods. Never use those for renewal.
        if yearly { return SubscriptionBillingInfo(date: nil, cycle: .yearly, autoRenews: nil, source: "Cursor billing", observedAt: now) }
        guard let object = try? JSONSerialization.jsonObject(with: usage) as? [String: Any] else { return nil }
        let payload = (object["usageSummary"] as? [String: Any]) ?? (object["response"] as? [String: Any]) ?? object
        guard let start = date(payload["billingCycleStart"]), let end = date(payload["billingCycleEnd"]),
              (20 * 86400...35 * 86400).contains(end.timeIntervalSince(start)) else { return nil }
        return SubscriptionBillingInfo(date: end, cycle: .monthly, autoRenews: true, source: "Cursor billing", observedAt: now)
    }
}


/// Uses only the active Codex account's existing OAuth credential; never imports browser cookies.
enum OpenAISubscriptionBilling {
    static func fetch(codexHome: String, account: SubscriptionAccountIdentity) -> SubscriptionBillingInfo? {
        guard BillingFetchPolicy.shouldFetch(provider: .codex, account: account),
              let data = FileManager.default.contents(atPath: codexHome + "/auth.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty else { return nil }
        // An account switch between quota and billing reads must fail closed.
        let email = claimEmail(tokens["id_token"] as? String) ?? claimEmail(token)
        guard matches(account, credentialID: accountID, email: email) else { return nil }
        var url = URLComponents(string: "https://chatgpt.com/backend-api/subscriptions")!
        url.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
        guard let endpoint = url.url,
              let response = BillingHTTP.read(endpoint, headers: [
                "Authorization": "Bearer " + token, "Chatgpt-Account-Id": accountID,
                "Accept": "application/json"
              ]) else { return nil }
        return BillingParser.openAI(response)
    }
    static func matches(_ account: SubscriptionAccountIdentity, credentialID: String, email: String?) -> Bool {
        if account.id == credentialID { return true }
        // Email is only an identity fallback, never permission to cross workspace IDs.
        guard let expected = account.email?.lowercased(), !expected.isEmpty,
              account.id.lowercased() == expected else { return false }
        return email?.lowercased() == expected
    }
    private static func claimEmail(_ token: String?) -> String? {
        guard let token else { return nil }
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (claims["email"] as? String) ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }
}
enum BillingHTTP {
    static func read(_ url: URL, headers: [String: String]) -> Data? {
        #if os(Windows)
        guard let response = try? WindowsNativeHTTP.request(url: url.absoluteString, headers: headers,
              connectTimeout: 5, sendTimeout: 5, receiveTimeout: 10), response.statusCode == 200 else { return nil }
        return response.body
        #else
        let delegate = NoRedirect()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let result = ResponseBox(), ready = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data,response,_ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result.set(data) }
            ready.signal()
        }.resume()
        guard ready.wait(timeout: .now() + 11) == .success else { return nil }
        return result.get()
        #endif
    }
    #if !os(Windows)
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ data: Data?) { lock.lock(); self.data = data; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }
    #endif
}

// Numeric timestamps are range-checked above (JSON booleans 0/1 are rejected).

/// Persists reminder deliveries/read state, not credentials. One reminder per account and calendar date.
enum BillingReminderStore {
    private struct Notice: Codable {
        var id: UUID
        var accountID: String
        var dueKey: String
        var dueDate: Date
        var createdAt: Date
        var title: String
        var message: String
        var isRead: Bool
    }
    private static let key = "TC_billingReminderNotices"
    private static let lock = NSLock()
    static func notifications(accounts: [SubscriptionAccountRecord], now: Date = Date(),
                              calendar: Calendar = .current, defaults: UserDefaults = .standard) -> [TokenClockNotification] {
        lock.lock(); defer { lock.unlock() }
        var notices = load(defaults)
        var changed = false
        for account in accounts where account.hasVerifiedIdentity {
            let settings = account.billingReminders ?? BillingReminderSettings()
            guard settings.enabled, let info = account.effectiveBilling,
                  info.isManual || (now.timeIntervalSince(info.observedAt) >= 0 && now.timeIntervalSince(info.observedAt) <= 7 * 86400),
                  let due = info.nextDate(now: now, calendar: calendar),
                  let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day,
                  days >= 0, days <= settings.safeDays else { continue }
            let dueKey = String(Int(due.timeIntervalSince1970))
            let formatter = DateFormatter(); formatter.dateStyle = .medium
            if let index = notices.firstIndex(where: { $0.accountID == account.id && $0.dueKey == dueKey }) {
                let title = "\(account.provider.displayName) · \(info.eventTitle)"
                let message = "\(account.displayName) · \(formatter.string(from: due))"
                if notices[index].title != title || notices[index].message != message {
                    notices[index].title = title; notices[index].message = message; changed = true
                }
                continue
            }
            notices.append(Notice(id: UUID(), accountID: account.id, dueKey: dueKey, dueDate: due,
                createdAt: now, title: "\(account.provider.displayName) · \(info.eventTitle)",
                message: "\(account.displayName) · \(formatter.string(from: due))", isRead: false))
            changed = true
        }
        let before = notices.count
        notices = notices.filter { now.timeIntervalSince($0.dueDate) < 400 * 86400 }.suffix(200).map { $0 }
        if changed || before != notices.count { save(notices, defaults) }
        // Keep the delivery ledger, but do not show superseded/canceled schedules as current reminders.
        return notices.filter { notice in
            guard let account = accounts.first(where: { $0.id == notice.accountID }),
                  (account.billingReminders ?? BillingReminderSettings()).enabled,
                  let due = account.effectiveBilling?.nextDate(now: now, calendar: calendar) else { return false }
            return String(Int(due.timeIntervalSince1970)) == notice.dueKey
        }.sorted { $0.createdAt > $1.createdAt }.prefix(30).map {
            var notification = TokenClockNotification(id: $0.id, kind: .system, title: $0.title,
                message: $0.message, createdAt: $0.createdAt, isRead: $0.isRead)
            notification.subscriptionAccountID = $0.accountID
            return notification
        }
    }
    static func markRead(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var notices = load(defaults)
        for index in notices.indices { notices[index].isRead = true }
        save(notices, defaults)
    }
    static func migrate(from oldID: String, to newID: String, defaults: UserDefaults) {
        lock.lock(); defer { lock.unlock() }
        var notices = load(defaults)
        for index in notices.indices where notices[index].accountID == oldID { notices[index].accountID = newID }
        save(notices, defaults)
    }
    private static func load(_ defaults: UserDefaults) -> [Notice] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Notice].self, from: data)) ?? []
    }
    private static func save(_ values: [Notice], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key); defaults.synchronize() }
    }
}

/// Billing reads are throttled separately from the much more frequent quota refreshes.
enum BillingFetchPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts: [String: Date] = [:]
    static func shouldFetch(provider: SubscriptionProvider, account: SubscriptionAccountIdentity, now: Date = Date()) -> Bool {
        let key = provider.rawValue + "::" + account.id
        let cached = SubscriptionAccountStore.shared.records().first { $0.id == key }?.detectedBilling
        if let cached, now.timeIntervalSince(cached.observedAt) < 6 * 3600 { return false }
        lock.lock(); defer { lock.unlock() }
        if let last = attempts[key], now.timeIntervalSince(last) < 3600 { return false }
        attempts[key] = now
        return true
    }
}
