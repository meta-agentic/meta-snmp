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
        // The standard MIB set ships inside the bundle: C-6 requires the app to be
        // fully functional with no internet connectivity, so it cannot be fetched
        // on demand. `.copy` preserves the directory, which lets StandardMIBBundle
        // enumerate the set without reading any module (NFR-7).
        .target(
            name: "MIBKit",
            resources: [.copy("Resources/StandardMIBs"), .copy("Resources/NOTICE")]
        ),
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
