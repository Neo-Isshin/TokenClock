// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v12)],  // Monterey+ —— normal 变体最低支持 macOS 12（glass 仍只在 main/.v26）
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            resources: [.copy("Resources/glass_disc.png")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
