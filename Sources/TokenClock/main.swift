import SwiftUI

@main
struct TokenClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 无 Settings 窗口，实际窗口由 AppDelegate 创建
        Settings {
            EmptyView()
        }
    }
}
