// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            resources: [.copy("Resources/glass_disc.png")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
