import Foundation

/// 集中构造 macOS 标准 `~/Library/...` 路径，避免散落字面量。
///
/// 用法：
/// ```swift
/// AppPaths.appSupport("Code", "User", "globalStorage", "saoudrizwan.claude-dev")
/// // → "/Users/<user>/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
/// ```
enum AppPaths {
    /// `~/Library/Application Support/<components>` 拼接路径
    static func appSupport(_ components: String...) -> String {
        ([NSHomeDirectory(), "Library", "Application Support"] + components)
            .joined(separator: "/")
    }
}