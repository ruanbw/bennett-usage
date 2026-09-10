// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BennettUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BennettUsageCore", targets: ["BennettUsageCore"]),
        .executable(name: "BennettUsageApp", targets: ["BennettUsageApp"])
    ],
    targets: [
        .target(
            name: "BennettUsageCore",
            dependencies: [],
            path: "Sources/BennettUsageCore"
        ),
        .executableTarget(
            name: "BennettUsageApp",
            dependencies: ["BennettUsageCore"],
            path: "Sources/BennettUsageApp"
        ),
        .testTarget(
            name: "BennettUsageCoreTests",
            dependencies: ["BennettUsageCore"],
            path: "Tests/BennettUsageCoreTests"
        )
    ]
)
