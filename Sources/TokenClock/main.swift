import SwiftUI

@main
struct TokenClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 所有窗口由 AppDelegate 创建，这里放空场景避免 SwiftUI 报错
        WindowGroup("TokenClock") {
            EmptyView()
                .frame(width: 0, height: 0)
                .onAppear {
                    if let window = NSApplication.shared.windows.first(where: { $0.title == "TokenClock" }) {
                        window.close()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .handlesExternalEvents(matching: Set())
    }
}
