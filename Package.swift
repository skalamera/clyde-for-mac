// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clyde",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "Clyde",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/Clyde",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
