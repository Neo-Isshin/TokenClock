import Foundation
import Glibc

@main
struct TokenClockLinuxMain {
    static func main() {
        // AppImages carry an older compatible GLib. Do not load newer host
        // gvfs/IBus modules into it; ordinary source installs keep host defaults.
        if let appDir = ProcessInfo.processInfo.environment["APPDIR"], !appDir.isEmpty {
            let modules = appDir + "/usr/lib/tokenclock-empty-modules"
            if FileManager.default.fileExists(atPath: modules) {
                setenv("GIO_MODULE_DIR", modules, 1)
                setenv("GIO_EXTRA_MODULES", "", 1)
                setenv("GIO_USE_VFS", "local", 1)
                setenv("GTK_IM_MODULE", "xim", 1)
            }
        }
        LinuxApp().run()
    }
}
