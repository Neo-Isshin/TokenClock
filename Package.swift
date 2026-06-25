// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
