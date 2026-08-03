// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let linuxSources = [
    "Config/AppConfig.swift",
    "Config/SettingsKeys.swift",
    "L10n.swift",
    "Models/TokenUsage.swift",
    "Services/AiderUsageService.swift",
    "Services/AntigravityUsageService.swift",
    "Services/AppPaths.swift",
    "Services/ClaudeCodeUsageService.swift",
    "Services/ClineUsageService.swift",
    "Services/CodexUsageService.swift",
    "Services/ContinueUsageService.swift",
    "Services/CopilotUsageService.swift",
    "Services/CursorAgentUsageService.swift",
    "Services/GeminiUsageService.swift",
    "Services/GrokUsageService.swift",
    "Services/HermesUsageService.swift",
    "Services/HistoryStore.swift",
    "Services/MockUsageService.swift",
    "Services/ModelEmoji.swift",
    "Services/ModelNormalizer.swift",
    "Services/OpenClawUsageService.swift",
    "Services/OpenCodeUsageService.swift",
    "Services/PathConfig.swift",
    "Services/PathDetector.swift",
    "Services/QwenCodeUsageService.swift",
    "Services/UsageAggregator.swift",
    "Services/UsageServiceProtocol.swift",
    "Linux/LinuxAPIServer.swift",
    "Linux/LinuxApp.swift",
    "Linux/LinuxMain.swift",
    "Linux/LinuxUsageModel.swift",
]

let package = Package(
    name: "TokenClock",
    targets: [
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk+-3.0",
            providers: [.apt(["libgtk-3-dev"])]
        ),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .executableTarget(
            name: "TokenClock",
            dependencies: ["CGtk", "CSQLite"],
            path: "Sources/TokenClock",
            exclude: [
                "AppDelegate.swift",
                "FloatingPanel.swift",
                "Models/ClockFaceTheme.swift",
                "Models/ClockSize.swift",
                "Models/CustomThemeConfig.swift",
                "Resources",
                "Services/LaunchAgentHelper.swift",
                "Services/UsageAPIServer.swift",
                "Services/WeatherService.swift",
                "ViewModel.swift",
                "Views",
                "main.swift",
            ],
            sources: linuxSources,
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
#elseif os(Windows)
// Windows 原生（Win32）normal 版。
// P1：仅 Windows/ UI 骨架 + Win32Shim（C 互操作层）。共享 Services + CSQLite 在 P2/P3 接入。
let package = Package(
    name: "TokenClock",
    targets: [
        .target(
            name: "Win32Shim",
            path: "Sources/Win32Shim",
            linkerSettings: [
                .linkedLibrary("User32"),
                .linkedLibrary("Shell32"),
                .linkedLibrary("Gdi32"),
                .linkedLibrary("Advapi32"),
            ]
        ),
        .executableTarget(
            name: "TokenClock",
            dependencies: ["Win32Shim"],
            path: "Sources/TokenClock",
            sources: ["Windows"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
#else
let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v12)],  // Monterey+ —— normal 变体最低支持 macOS 12（glass 仍只在 main/.v26）
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            exclude: ["Linux", "Windows"],
            resources: [.copy("Resources/glass_disc.png")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
#endif
