#if os(macOS)
import Foundation
import Combine

struct NotebookEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var completed = false
    var remindAt: Date?
    var notifiedForDate: Date?
    var noticeID: UUID?
    var reminderRead = false
}

@MainActor final class NotebookStore: ObservableObject {
    @Published private(set) var entries: [NotebookEntry] = []
    @Published var selectedID: UUID?
    @Published private(set) var errorMessage = ""
    var onChange: (() -> Void)?
    let url: URL
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var needsRecoveryBackup = false

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokenclock/notebook.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([NotebookEntry].self, from: data) {
            var seen = Set<UUID>()
            entries = values.filter { seen.insert($0.id).inserted }
        } else if FileManager.default.fileExists(atPath: url.path) {
            needsRecoveryBackup = true
            errorMessage = toolboxText("记录文件暂时无法读取，已保留原文件。", "Could not read the notebook. The original file is kept.")
        }
    }
    @discardableResult func add(now: Date = Date()) -> UUID {
        let entry = NotebookEntry(id: UUID(), title: "", body: "", createdAt: now, updatedAt: now)
        entries.insert(entry, at: 0); selectedID = entry.id; changed()
        return entry.id
    }
    func update(_ id: UUID, title: String? = nil, body: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let title { entries[index].title = title }
        if let body { entries[index].body = body }
        entries[index].updatedAt = Date(); changed()
    }
    func setCompleted(_ id: UUID, _ value: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].completed = value; entries[index].updatedAt = Date(); changed(immediate: true)
    }
    func setReminder(_ id: UUID, _ date: Date?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].remindAt != date else { return }
        entries[index].remindAt = date; entries[index].notifiedForDate = nil
        entries[index].noticeID = nil; entries[index].reminderRead = false
        entries[index].updatedAt = Date(); changed(immediate: true)
    }
    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries.first?.id }
        changed(immediate: true)
    }
    var pendingSummaryEntries: [NotebookEntry] {
        entries.filter { !$0.completed }.sorted { left, right in
            if left.remindAt != right.remindAt {
                return (left.remindAt ?? .distantFuture) < (right.remindAt ?? .distantFuture)
            }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return left.id.uuidString < right.id.uuidString
        }
    }
    var nextReminder: Date? {
        entries.filter { !$0.completed && $0.remindAt != nil && $0.notifiedForDate != $0.remindAt }.compactMap(\.remindAt).min()
    }
    @discardableResult func claimDue(now: Date = Date()) -> Bool {
        var claimed = false
        for index in entries.indices {
            guard !entries[index].completed, let date = entries[index].remindAt, date <= now,
                  entries[index].notifiedForDate != date else { continue }
            entries[index].notifiedForDate = date; entries[index].noticeID = UUID(); entries[index].reminderRead = false
            claimed = true
        }
        if claimed { dirty = true; persist(notify: false) }
        return claimed
    }
    func markRead(ids: Set<UUID>) {
        var updated = false
        for index in entries.indices where ids.contains(entries[index].id) && !entries[index].reminderRead {
            entries[index].reminderRead = true; updated = true
        }
        if updated { dirty = true; persist(notify: false) }
    }
    func notices() -> [TokenClockNotification] {
        entries.compactMap { entry in
            guard !entry.completed, let id = entry.noticeID, let date = entry.notifiedForDate else { return nil }
            var notice = TokenClockNotification(id: id, kind: .notebookReminder,
                title: entry.title.isEmpty ? toolboxText("行事本提醒", "Notebook reminder") : entry.title,
                message: entry.body.isEmpty ? toolboxText("点击查看这条记录。", "Click to open this entry.") : String(entry.body.prefix(180)),
                createdAt: date, isRead: entry.reminderRead)
            notice.notebookEntryID = entry.id
            return notice
        }
    }
    func flush() { saveTask?.cancel(); saveTask = nil; persist(notify: false) }

    private func changed(immediate: Bool = false) {
        dirty = true; saveTask?.cancel()
        if immediate { persist(notify: true); return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300000000)
            guard !Task.isCancelled else { return }
            self?.persist(notify: true)
        }
    }
    private func persist(notify: Bool) {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if needsRecoveryBackup {
                let backup = url.deletingLastPathComponent().appendingPathComponent("notebook-recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                needsRecoveryBackup = false
            }
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false; errorMessage = ""
        } catch {
            errorMessage = toolboxText("暂时未能保存，请保留窗口后重试。", "Could not save yet. Keep the window open and retry.")
        }
        if notify { onChange?() }
    }
}
#endif
