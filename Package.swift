// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexWake",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexWake", targets: ["CodexWake"]),
        .executable(name: "codex-keeper", targets: ["CodexKeeperCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "CodexKeeperCore",
            path: "Sources/CodexKeeperCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CodexWake",
            dependencies: [
                "CodexKeeperCore"
            ],
            path: "Sources/CodexWake",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "CodexKeeperCLI",
            dependencies: [
                "CodexKeeperCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CodexKeeperCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "CodexKeeperCompatibilityTests",
            dependencies: ["CodexKeeperCore"],
            path: "Tests/CodexKeeperCoreTests"
        )
    ]
)
