// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
