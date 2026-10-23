// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeelRESP", targets: ["KeelRESP"]),
        .library(name: "KeelSSH", targets: ["KeelSSH"]),
        .library(name: "KeelCore", targets: ["KeelCore"]),
        .library(name: "KeelControl", targets: ["KeelControl"]),
        .library(name: "KeelMCP", targets: ["KeelMCP"]),
        .library(name: "KeelUI", targets: ["KeelUI"]),
        .executable(name: "Keel", targets: ["KeelApp"]),
        // SSH_ASKPASS helper for saved SSH passwords and the prompt relay; bundled beside the app binary.
        .executable(name: "keel-askpass", targets: ["KeelAskpassMain"])
    ],
    targets: [
        // Protocol layer: no UI, no persistence (02 Architecture → Modules).
        .target(name: "KeelRESP"),
        .target(name: "KeelAskpass"),
        .executableTarget(name: "KeelAskpassMain", dependencies: ["KeelAskpass"]),
        .target(name: "KeelSSH", dependencies: ["KeelAskpass"]),
        .target(name: "KeelCore", dependencies: ["KeelRESP", "KeelSSH"]),
        .target(name: "KeelControl", dependencies: ["KeelCore"]),
        .target(name: "KeelMCP", dependencies: ["KeelControl", "KeelCore"]),
        .target(name: "KeelUI", dependencies: ["KeelCore", "KeelControl"]),
        .executableTarget(name: "KeelApp", dependencies: ["KeelUI", "KeelCore", "KeelSSH", "KeelControl", "KeelMCP"]),
        .target(name: "KeelRelease"),
        .testTarget(name: "KeelRESPTests", dependencies: ["KeelRESP"]),
        .testTarget(name: "KeelSSHTests", dependencies: ["KeelSSH", "KeelAskpass"]),
        .testTarget(name: "KeelCoreTests", dependencies: ["KeelCore", "KeelSSH"]),
        .testTarget(name: "KeelControlTests", dependencies: ["KeelControl", "KeelCore"]),
        .testTarget(name: "KeelMCPTests", dependencies: ["KeelMCP", "KeelControl"]),
        .testTarget(name: "KeelUITests", dependencies: ["KeelUI", "KeelCore"]),
        .testTarget(name: "KeelReleaseTests", dependencies: ["KeelRelease", "KeelCore"]),
        // Container matrix (Redis/Valkey/Dragonfly/sshd); real cases run only with KEEL_INTEGRATION=1.
        .testTarget(name: "KeelIntegrationTests", dependencies: ["KeelCore", "KeelRESP", "KeelSSH"])
    ],
    swiftLanguageModes: [.v6]
)
