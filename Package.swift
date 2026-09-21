// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeepAwakeCore", targets: ["KeepAwakeCore"]),
        .library(name: "PowerAssertions", targets: ["PowerAssertions"]),
        .library(name: "ProcessWatch", targets: ["ProcessWatch"]),
    ],
    targets: [
        .target(name: "MonotonicTime"),
        .target(name: "PowerAssertions"),
        .target(name: "KeepAwakeCore", dependencies: ["PowerAssertions", "MonotonicTime"]),
        .target(name: "ProcessWatch", dependencies: ["MonotonicTime"]),
        // Test-only helpers. Not exported as a product, so nothing ships with the app.
        .target(name: "TestSupport", dependencies: ["MonotonicTime", "PowerAssertions"]),
        .testTarget(name: "MonotonicTimeTests", dependencies: ["MonotonicTime"]),
        .testTarget(name: "PowerAssertionsTests", dependencies: ["PowerAssertions"]),
        .testTarget(
            name: "KeepAwakeCoreTests",
            dependencies: ["KeepAwakeCore", "PowerAssertions", "TestSupport"]
        ),
        .testTarget(name: "ProcessWatchTests", dependencies: ["ProcessWatch", "TestSupport"]),
    ]
)
