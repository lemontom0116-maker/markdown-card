// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MarkdownCard",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MarkdownCardCore", targets: ["MarkdownCardCore"]),
        .executable(name: "MarkdownCard", targets: ["MarkdownCardAgent"]),
        .executable(name: "mdcard", targets: ["mdcard"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            exact: "3.0.1"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
    ],
    targets: [
        .target(
            name: "MarkdownCardCore"
        ),
        .executableTarget(
            name: "MarkdownCardAgent",
            dependencies: [
                "MarkdownCardCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "mdcard",
            dependencies: [
                "MarkdownCardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MarkdownCardCoreTests",
            dependencies: ["MarkdownCardCore"]
        ),
        .testTarget(
            name: "MarkdownCardAgentTests",
            dependencies: ["MarkdownCardAgent", "MarkdownCardCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
