// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenClock",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "TokenClock",
            path: "Sources/TokenClock",
            exclude: [
                "Linux",
                "Windows",
                "Resources/glass_disc.png",
            ],
            resources: [
                .copy("Resources/pricing-snapshot.json"),
            ],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "TokenClockTests",
            dependencies: ["TokenClock"],
            path: "Tests/TokenClockTests"
        )
    ]
)
