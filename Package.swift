// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AISNMPToolkit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SNMPCore", targets: ["SNMPCore"]),
        .library(name: "MIBKit", targets: ["MIBKit"]),
        .library(name: "AIBridge", targets: ["AIBridge"]),
        .executable(name: "snmpcli", targets: ["snmpcli"]),
        .executable(name: "SNMPToolkitApp", targets: ["SNMPToolkitApp"]),
    ],
    targets: [
        .target(name: "SNMPCore"),
        .target(name: "MIBKit"),
        .target(name: "AIBridge", dependencies: ["SNMPCore", "MIBKit"]),
        .executableTarget(name: "snmpcli", dependencies: ["SNMPCore", "MIBKit"]),
        .executableTarget(
            name: "SNMPToolkitApp",
            dependencies: ["SNMPCore", "MIBKit", "AIBridge"]
        ),
        .testTarget(name: "SNMPCoreTests", dependencies: ["SNMPCore"]),
        .testTarget(name: "MIBKitTests", dependencies: ["MIBKit"]),
    ]
)
