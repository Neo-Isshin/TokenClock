import Foundation

/// Windows 入口（镜像 Linux/LinuxMain.swift）。
@main
struct TokenClockWindowsMain {
    static func main() {
        WindowsApp.shared.run()
    }
}
