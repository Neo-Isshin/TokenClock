import SwiftUI

@main
struct TokenClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 所有窗口由 AppDelegate 创建，这里放空场景避免 SwiftUI 报错。
        // 注：windowResizability(.contentSize) / defaultSize 是 macOS 13+ Scene 修饰符，
        // 而 @SceneBuilder 不支持 if #available（无 buildEither），some Scene 又不允许
        // 两分支不同类型 —— 无法条件应用。占位窗是 0x0 EmptyView 且 onAppear 立即关闭，
        // 省略这两个修饰符对实际表现无影响（真实时钟窗口由 AppDelegate 的 NSPanel 独立管理）。
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
        .handlesExternalEvents(matching: Set())
    }
}
