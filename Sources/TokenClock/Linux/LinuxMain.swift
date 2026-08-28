import Foundation
import Glibc

@main
struct TokenClockLinuxMain {
    static func main() {
        configureBundledModuleIsolation()
        LinuxApp().run()
    }

    /// AppImage bundles its own GLib/GIO stack. Prevent newer host desktop plug-ins
    /// (gvfs/IBus) from being injected into that older compatible stack before GTK
    /// initializes. Keeping this in the ELF entry point lets AppRun target the binary
    /// directly; script-based AppRun launchers fail with ENOEXEC on some runtimes.
    private static func configureBundledModuleIsolation() {
        guard let executable = CommandLine.arguments.first, !executable.isEmpty else { return }
        let binDirectory = URL(fileURLWithPath: executable).standardizedFileURL.deletingLastPathComponent()
        let appRoot = binDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let emptyModules = appRoot.appendingPathComponent("usr/lib/tokenclock-empty-modules").path
        setenv("GIO_MODULE_DIR", emptyModules, 1)
        setenv("GIO_EXTRA_MODULES", "", 1)
        setenv("GIO_USE_VFS", "local", 1)
        setenv("GTK_IM_MODULE", "xim", 1)
    }
}
