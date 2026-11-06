#if os(macOS)
import SwiftUI

struct NotificationSettingsView: View {
    @ObservedObject var preferences: AppNotificationPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(toolboxText("显示应用内通知", "Show in-app notifications"), isOn: Binding(
                get: { preferences.configuration.enabled }, set: { preferences.setEnabled($0) }))
            ForEach(NotificationCategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { preferences.configuration.categories.contains(category) },
                    set: { preferences.set(category, enabled: $0) }))
                    .disabled(!preferences.configuration.enabled)
            }
            Text(toolboxText("AI速递每 2 小时检查一次；版本更新每 12 小时检查一次。关闭相应类别会暂停自动检查。行事本提醒需要 TokenClock 保持运行。", "AI digest checks every 2 hours; app updates every 12 hours. Disabling a category pauses its automatic checks. Notebook reminders require TokenClock to remain running."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(.checkbox).font(.system(size: 11))
    }
}
#endif
