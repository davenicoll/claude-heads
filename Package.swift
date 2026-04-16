// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClaudeHeads",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CPTYHelpers",
            path: "Sources/CPTYHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ClaudeHeadsCore",
            dependencies: ["SwiftTerm", "CPTYHelpers"],
            path: "Sources/ClaudeHeads",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ClaudeHeads",
            dependencies: ["ClaudeHeadsCore"],
            path: "Sources/ClaudeHeadsApp"
        ),
        .testTarget(
            name: "ClaudeHeadsCoreTests",
            dependencies: ["ClaudeHeadsCore"],
            path: "Tests/ClaudeHeadsCoreTests"
        ),
    ]
)
