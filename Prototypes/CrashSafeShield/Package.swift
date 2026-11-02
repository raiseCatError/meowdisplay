// swift-tools-version:5.9
// Isolated prototype for the crash-safe Privacy Shield. Not part of the app build; nothing here
// registers with launchd or installs anything. See README.md.
import PackageDescription

let package = Package(
    name: "CrashSafeShield",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShieldCore"),
        .executableTarget(name: "ShieldKeeper", dependencies: ["ShieldCore"]),
        .executableTarget(name: "FakeSender", dependencies: ["ShieldCore"]),
        .executableTarget(name: "CoverageTrace"),
        .testTarget(name: "ShieldCoreTests", dependencies: ["ShieldCore"]),
    ]
)
