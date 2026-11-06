#if os(macOS)
import Foundation
import Combine

enum NotificationCategory: String, Codable, CaseIterable, Identifiable {
    case news, reports, billing, notebook, updates, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .news: return toolboxText("AI速递", "AI digest")
        case .reports: return toolboxText("日／周／月用量报告", "Daily / weekly / monthly usage reports")
        case .billing: return toolboxText("订阅续费提醒", "Subscription renewal reminders")
        case .notebook: return toolboxText("行事本提醒", "Notebook reminders")
        case .updates: return toolboxText("版本更新提醒", "Version updates")
        case .tools: return toolboxText("模型检测与工具消息", "Model checks and tool notices")
        }
    }
    static func category(for notice: TokenClockNotification) -> Self {
        if notice.subscriptionAccountID != nil { return .billing }
        if notice.releaseURL != nil { return .updates }
        switch notice.kind {
        case .news: return .news
        case .notebookReminder: return .notebook
        case .releaseUpdate: return .updates
        case .dailyReport, .weeklyReport, .monthlyReport: return .reports
        case .modelDetection, .system: return .tools
        }
    }
}

@MainActor final class AppNotificationPreferences: ObservableObject {
    struct Configuration: Codable, Equatable {
        var enabled = true
        var categories = Set(NotificationCategory.allCases)
    }
    private let defaults: UserDefaults
    private static let key = "TC_notificationPreferences.v1"
    @Published private(set) var configuration: Configuration
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
    }
    func allows(_ category: NotificationCategory) -> Bool { configuration.enabled && configuration.categories.contains(category) }
    func allows(_ notice: TokenClockNotification) -> Bool { allows(NotificationCategory.category(for: notice)) }
    func setEnabled(_ value: Bool) { configuration.enabled = value; save() }
    func set(_ category: NotificationCategory, enabled: Bool) {
        if enabled { configuration.categories.insert(category) } else { configuration.categories.remove(category) }
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.key) }
        onChange?()
    }
}

enum NotificationPanelFilter: String, CaseIterable, Identifiable {
    case all, news, reports, billing, notebook, updates, tools
    var id: String { rawValue }
    var title: String { rawValue == "all" ? toolboxText("全部消息", "All notices") : NotificationCategory(rawValue: rawValue)!.title }
    func includes(_ notice: TokenClockNotification) -> Bool { self == .all || NotificationCategory.category(for: notice).rawValue == rawValue }
}

/// One adaptive timer for local reminders and low-frequency content checks.
/// Timer deadlines survive relaunch through each service's persisted claims.
@MainActor final class UserContentCenter {
    let news: AilyreNewsService
    let notebook: NotebookStore
    let preferences: AppNotificationPreferences
    private let releases: ReleaseUpdateService
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var active = false
    init(defaults: UserDefaults = .standard, notebookURL: URL? = nil, releases: ReleaseUpdateService = .shared) {
        news = AilyreNewsService(defaults: defaults)
        notebook = notebookURL.map { NotebookStore(url: $0) } ?? NotebookStore()
        preferences = AppNotificationPreferences(defaults: defaults)
        self.releases = releases
        news.onChange = { [weak self] in self?.changed() }
        notebook.onChange = { [weak self] in self?.runDueJobs() }
        preferences.onChange = { [weak self] in self?.runDueJobs() }
    }
    func start() { guard !active else { return }; active = true; runDueJobs() }
    func stop() { active = false; timer?.invalidate(); timer = nil; news.stop(); notebook.flush() }
    func runDueJobs(now: Date = Date()) {
        guard active else { return }
        if preferences.allows(.notebook) { notebook.claimDue(now: now) }
        if preferences.allows(.news) { news.refreshIfDue(now: now, language: L10n.shared.language.rawValue) }
        if preferences.allows(.updates) {
            releases.checkDaily(now: now) { [weak self] in
                Task { @MainActor in self?.changed() }
            }
        }
        changed()
    }
    func notices() -> [TokenClockNotification] { news.notices() + notebook.notices() }
    private func changed() { schedule(); onChange?() }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard active else { return }
        let now = Date()
        var dates: [Date] = []
        if preferences.allows(.news) { dates.append(news.nextCheck(now: now)) }
        if preferences.allows(.updates) { dates.append(releases.nextCheckDate(now: now)) }
        if preferences.allows(.notebook), let date = notebook.nextReminder { dates.append(date) }
        guard let next = dates.min() else { return }
        let timer = Timer(timeInterval: max(0.5, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runDueJobs() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif
