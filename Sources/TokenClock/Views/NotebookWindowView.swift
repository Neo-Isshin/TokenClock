#if os(macOS)
import SwiftUI

struct NotebookWindowView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var preferences: AppNotificationPreferences
    @State private var showCompleted = false
    @State private var deleting = false
    private var selected: NotebookEntry? { store.entries.first { $0.id == store.selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(toolboxText("行事本", "Notebook")).font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(toolboxText("记录想法、待办与提醒，仅保存在本机", "Notes, tasks and reminders, stored on this Mac"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.add() } label: { Label(toolboxText("新建", "New"), systemImage: "plus") }
                    .buttonStyle(.bordered).instantHint(toolboxText("新建一条记录", "Add an entry"))
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).font(.system(size: 11)).foregroundStyle(.orange).padding(12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    entries
                    if let entry = selected { editor(entry) }
                    else {
                        VStack(spacing: 8) {
                            Image(systemName: "note.text").font(.system(size: 24)).foregroundStyle(.secondary)
                            Text(toolboxText("写下第一条记录", "Write your first entry")).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button(toolboxText("新建记录", "New entry")) { store.add() }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, minHeight: 170).toolboxCard()
                    }
                    Text(toolboxText("支持纯文本、分行和基础列表。到时会加入应用内通知，请保持 TokenClock 运行。", "Plain text, line breaks and simple lists. Due reminders appear in in-app notifications; keep TokenClock running."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
        }.environment(\.locale, Locale(identifier:L10n.shared.language.rawValue)).frame(minWidth: 400, minHeight: 460).background(Color(nsColor: .windowBackgroundColor))
            .confirmationDialog(toolboxText("删除这条记录？", "Delete this entry?"), isPresented: $deleting) {
                Button(toolboxText("删除", "Delete"), role: .destructive) { if let id = store.selectedID { store.delete(id) } }
            }
    }
    private var entries: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(toolboxText("记录", "Entries")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Toggle(toolboxText("显示已完成", "Show completed"), isOn: $showCompleted).toggleStyle(.checkbox).font(.system(size: 10))
            }
            ForEach(store.entries.filter { showCompleted || !$0.completed }) { entry in
                HStack(spacing: 8) {
                    Button { store.setCompleted(entry.id, !entry.completed) } label: {
                        Image(systemName: entry.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                    }.buttonStyle(.plain).instantHint(toolboxText("切换完成状态", "Toggle completion"))
                    Button { store.selectedID = entry.id } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title.isEmpty ? toolboxText("未命名记录", "Untitled entry") : entry.title)
                                .font(.system(size: 11, weight: .medium)).lineLimit(1).strikethrough(entry.completed)
                            if let date = entry.remindAt {
                                Text(date, format: .dateTime.month().day().hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(8).background(.primary.opacity(store.selectedID == entry.id ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 8))
            }
        }.toolboxCard()
    }
    private func editor(_ entry: NotebookEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(toolboxText("标题", "Title"), text: Binding(get: { selected?.title ?? "" }, set: { store.update(entry.id, title: $0) }))
                .textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .semibold))
            TextEditor(text: Binding(get: { selected?.body ?? "" }, set: { store.update(entry.id, body: $0) }))
                .font(.system(size: 12)).scrollContentBackground(.hidden).frame(minHeight: 150)
                .padding(5).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            Toggle(toolboxText("设置提醒时间", "Set a reminder"), isOn: Binding(get: { selected?.remindAt != nil },
                set: { store.setReminder(entry.id, $0 ? Date().addingTimeInterval(3600) : nil) }))
                .toggleStyle(.checkbox).font(.system(size: 11))
            if let date = entry.remindAt {
                DatePicker(toolboxText("提醒时间", "Remind at"), selection: Binding(get: { selected?.remindAt ?? date },
                    set: { store.setReminder(entry.id, $0) }), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field).font(.system(size: 11))
                if !preferences.allows(.notebook) {
                    Text(toolboxText("行事本通知已暂停，可在设置的通知选项中开启。", "Notebook notifications are paused; enable them in notification settings."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(toolboxText("自动保存", "Saved automatically")).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { deleting = true } label: { Label(toolboxText("删除", "Delete"), systemImage: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.toolboxCard()
    }
}
#endif
