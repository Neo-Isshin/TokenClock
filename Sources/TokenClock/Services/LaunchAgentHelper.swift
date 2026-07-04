import Foundation
import ServiceManagement

/// LaunchAgent 自启动管理：统一管理 `~/Library/LaunchAgents/com.tokenclock.app.<variant>.plist`
///
/// 以前安装器（cli/install.sh）和右键菜单（SMAppService）各管各的，曾出现菜单关掉后
/// plist 残留（"zombie plist"）的 smoke 故障。本类作为唯一 owner：
/// - 写 plist → `enable(...)`
/// - 删 plist → `disable(...)`
/// - 状态查询 → `isRegistered(...)` / `plistURL(...)` / `label(...)`
/// - 旧 installer/SMAppService 残留 → `cleanupLegacy()`（应用启动时调用一次）
///
/// 设计为 enum + static 方法，无实例状态，调用方写 `LaunchAgentHelper.enable(...)`。
enum LaunchAgentHelper {

    /// 时钟变体：决定 plist label、plist 路径与 `~/.tokenclock/<directoryName>/TokenClock` 安装目录。
    /// 与 `ClockFaceTheme` 的 theme 概念正交 —— 这里指的是安装时的 build 变体。
    enum Variant: String, CaseIterable {
        case glass  = "glass"
        case normal = "normal"

        /// `~/.tokenclock/<directoryName>/TokenClock` 中的子目录名
        var directoryName: String { rawValue }

        /// LaunchAgent label: `com.tokenclock.app.<variant>`
        var label: String { "com.tokenclock.app.\(rawValue)" }
    }

    /// 自启动 launchctl 调用失败 / plist 写入失败 时抛出
    struct LaunchAgentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 公开 API

    /// 从 argv[0] 推断当前进程对应的安装变体。
    /// `~/.tokenclock/glass/TokenClock` → .glass；`~/.tokenclock/normal/TokenClock` → .normal。
    /// 开发态 `.build/debug/TokenClock` 时 parent 是 `debug`，不在 enum 内，fallback 到 .glass
    ///（Liquid Glass 是当前主推，且与 SwiftUI `.glassMaterial` 等 API 配套）。
    /// 若 binary 名不是 `TokenClock`（被改名等），返回 nil —— 调用方应 skip 整套自启动操作。
    static func detectVariant() -> Variant? {
        let argv0 = ProcessInfo.processInfo.arguments.first ?? ""
        let url = URL(fileURLWithPath: argv0)
        let lastComponent = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if lastComponent != "TokenClock" { return nil }
        if let v = Variant(rawValue: parent) { return v }
        // 开发态 `.build/<config>/TokenClock` → fallback
        return .glass
    }

    /// plist 完整路径：`~/Library/LaunchAgents/com.tokenclock.app.<variant>.plist`
    static func plistURL(variant: Variant) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(variant.label).plist")
    }

    /// launchctl load/unload 时使用的 label（与 plist 内的 `Label` 字段一致）
    static func label(variant: Variant) -> String {
        variant.label
    }

    /// 当前变体对应的 LaunchAgent plist 是否已注册：
    /// 判定 = plist 文件存在 **且** plist 内的 `RunAtLoad == true`。
    /// 不去解析 `launchctl print` 输出 —— 那个 grep-friendly 但 fragile。
    /// 这反映的是磁盘上的意图（写盘的 plist），与 launchd 的运行时状态通常一致
    ///（enable() 写完 plist 立刻 load -w，disable() unload 完立刻删文件）。
    static func isRegistered(variant: Variant) -> Bool {
        let url = plistURL(variant: variant)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let plist = try? Data(contentsOf: url) else { return false }
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return false
        }
        if let runAtLoad = dict["RunAtLoad"] as? Bool {
            return runAtLoad
        }
        return false
    }

    /// 写入 plist 并 `launchctl load -w`（开启自启）。若已注册，幂等。
    /// `binaryPath` 通常就是 `ProcessInfo.processInfo.arguments[0]`（argv[0]），
    /// 这样 plist 里记录的路径始终与当前 binary 路径一致。
    static func enable(variant: Variant, binaryPath: String) throws {
        let url = plistURL(variant: variant)
        let data = try renderPlist(variant: variant, binaryPath: binaryPath)
        try ensureLaunchAgentsDirExists()
        try data.write(to: url, options: .atomic)
        try runLaunchctl(["load", "-w", url.path], throwOnError: true)
    }

    /// `launchctl unload` 并删除 plist（关闭自启）。若未注册，幂等。
    /// unload 失败（如 plist 从未被 load 过）会被吞掉 —— 这与 installer 行为一致。
    static func disable(variant: Variant) {
        let url = plistURL(variant: variant)
        // unload 是 best-effort：忽略非零退出（对应 installer 的 || true）
        _ = try? runLaunchctl(["unload", url.path], throwOnError: false)
        try? FileManager.default.removeItem(at: url)
    }

    /// 兜底清理（应用启动时调用一次）：
    /// 1. **继承** installer 写下的 legacy plist —— 因为新代码使用的 label / 文件名
    ///    跟 installer 一致（`com.tokenclock.app.<variant>.plist`），已存在的 plist
    ///    直接被采用。装入时若检测到 legacy plist 且 `TC_launchAtLogin` 未设置过，
    ///    默认视为开启（沿用 installer "默认开启自启" 的承诺），并写一次 defaults。
    /// 2. **撤销** 通过 `SMAppService.mainApp` 注册过的旧 entry（菜单以前用的那条），
    ///    避免和我们的 plist 冲突。`try?` 吞错，ServiceManagement 偶尔抛 `OperationNotPermitted`
    ///    等错误我们不关心。
    ///
    /// 注意：此方法**不**自动删除 legacy plist，那是 destructive。
    static func cleanupLegacy() {
        let defaults = UserDefaults.standard
        let key = SettingsKey.launchAtLogin.rawValue

        // 1) 尝试继承 legacy plist 的状态
        let anyPlistExists = Variant.allCases.contains { isRegistered(variant: $0) }
        if defaults.object(forKey: key) == nil, anyPlistExists {
            defaults.setBool(true, for: .launchAtLogin)
            print("[LaunchAgent] 继承 installer legacy plist：默认开启自启（首次启动迁移）")
        }

        // 2) 撤销 SMAppService 注册（如果有）。SMAppService.mainApp 仅在当前进程
        // 的 bundle 标识下有效，try? 安全。
        try? SMAppService.mainApp.unregister()
    }

    // MARK: - 私有：plist 序列化

    /// 生成 plist Data —— 与 installer 的 hand-written plist 同格式
    ///（XML、4 空格缩进、一行一个 key），方便人眼 dump 排查。
    private static func renderPlist(variant: Variant, binaryPath: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": variant.label,
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
            "KeepAlive": ["Crashed": true],
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
    }

    /// 确保 `~/Library/LaunchAgents` 存在（一般已存在，但首次手动 install 时可能没有）
    private static func ensureLaunchAgentsDirExists() throws {
        let dir = plistURL(variant: .glass)
            .deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 私有：launchctl 调用

    /// 执行 `/bin/launchctl <args>`。`throwOnError == true` 时非零退出码会抛错；
    /// `false` 时吞掉（用于 disable 的 unload 等 best-effort 场景）。
    @discardableResult
    private static func runLaunchctl(_ args: [String], throwOnError: Bool) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        let status = proc.terminationStatus
        if status != 0, throwOnError {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw LaunchAgentError(
                message: "launchctl \(args.joined(separator: " ")) 退出 \(status)：\(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return status
    }
}