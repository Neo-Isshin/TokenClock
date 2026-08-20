import Foundation

/// XDG autostart counterpart of macOS's LaunchAgent helper.
enum LinuxAutostart {
    private static var desktopFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let configDirectory: URL
        if let configured = environment["XDG_CONFIG_HOME"], !configured.isEmpty {
            configDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return configDirectory
            .appendingPathComponent("autostart", isDirectory: true)
            .appendingPathComponent("tokenclock.desktop", isDirectory: false)
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: desktopFileURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let manager = FileManager.default
        let url = desktopFileURL
        if !enabled {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }

        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // AppImage exposes its stable outer path in APPIMAGE; argv[0] points into
        // a temporary mount and must never be persisted in an autostart file.
        let executable = ProcessInfo.processInfo.environment["APPIMAGE"]
            ?? ProcessInfo.processInfo.arguments.first
            ?? "/usr/bin/tokenclock"
        let quotedExecutable = "\"\(executable.replacingOccurrences(of: "\"", with: "\\\""))\""
        let desktopFile = """
        [Desktop Entry]
        Type=Application
        Version=1.0
        Name=TokenClock
        Comment=Beautiful local AI token usage clock
        Exec=\(quotedExecutable)
        Terminal=false
        Categories=Utility;
        X-GNOME-Autostart-enabled=true

        """
        try desktopFile.write(to: url, atomically: true, encoding: .utf8)
    }
}
