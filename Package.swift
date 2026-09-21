// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeepAwakeCore", targets: ["KeepAwakeCore"]),
        .library(name: "PowerAssertions", targets: ["PowerAssertions"]),
    ],
    targets: [
        .target(name: "PowerAssertions"),
        .target(name: "KeepAwakeCore", dependencies: ["PowerAssertions"]),
        .testTarget(name: "PowerAssertionsTests", dependencies: ["PowerAssertions"]),
        .testTarget(name: "KeepAwakeCoreTests", dependencies: ["KeepAwakeCore", "PowerAssertions"]),
    ]
)
