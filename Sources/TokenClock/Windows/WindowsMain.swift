import Foundation

/// Windows 入口（镜像 Linux/LinuxMain.swift）。
@main
struct TokenClockWindowsMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--catalog-report"), arguments.indices.contains(flag + 1) {
            do {
                try WindowsProviderCatalog.writeDiagnosticReport(to: arguments[flag + 1])
            } catch {
                // GUI-subsystem builds do not have a reliable console, so use a deterministic
                // nonzero exit status; smoke tests inspect the requested output file as well.
                exit(2)
            }
            return
        }
        WindowsApp.shared.run()
    }
}
