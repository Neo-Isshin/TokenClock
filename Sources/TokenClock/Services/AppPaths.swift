import Foundation

/// 集中构造桌面平台的应用配置路径，避免散落字面量。
///
/// 用法：
/// ```swift
/// AppPaths.appSupport("Code", "User", "globalStorage", "saoudrizwan.claude-dev")
/// // → "/Users/<user>/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
/// ```
enum AppPaths {
    /// macOS: `~/Library/Application Support/<components>`
    /// Linux: `${XDG_CONFIG_HOME:-~/.config}/<components>`
    static func appSupport(_ components: String...) -> String {
#if os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config", isDirectory: true).path
        return ([configHome] + components).joined(separator: "/")
#else
        ([NSHomeDirectory(), "Library", "Application Support"] + components)
            .joined(separator: "/")
#endif
    }
}
