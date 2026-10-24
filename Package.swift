// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeelRESP", targets: ["KeelRESP"]),
        .library(name: "KeelSSH", targets: ["KeelSSH"]),
        .library(name: "KeelCore", targets: ["KeelCore"]),
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
        // Resources: data-driven server detection rules (INT-02) and the bundled command catalog (INT-03).
        .target(name: "KeelCore", dependencies: ["KeelRESP", "KeelSSH"], resources: [.copy("Resources/ServerDetection.json"), .copy("Resources/Commands")]),
        // Resources: Inter and JetBrains Mono, registered for the process at launch (MAC-19).
        .target(name: "KeelUI", dependencies: ["KeelCore", "KeelSSH"], resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "KeelApp", dependencies: ["KeelUI", "KeelCore", "KeelSSH"]),
        .target(name: "KeelRelease"),
        .testTarget(name: "KeelRESPTests", dependencies: ["KeelRESP"]),
        .testTarget(name: "KeelSSHTests", dependencies: ["KeelSSH", "KeelAskpass"]),
        .testTarget(name: "KeelCoreTests", dependencies: ["KeelCore", "KeelSSH"]),
        .testTarget(name: "KeelUITests", dependencies: ["KeelUI", "KeelCore", "KeelSSH", "KeelAskpass"]),
        .testTarget(name: "KeelReleaseTests", dependencies: ["KeelRelease", "KeelCore"]),
        // Container matrix (Redis/Valkey/Dragonfly/sshd); real cases run only with KEEL_INTEGRATION=1.
        .testTarget(name: "KeelIntegrationTests", dependencies: ["KeelCore", "KeelRESP", "KeelSSH"])
    ],
    swiftLanguageModes: [.v6]
)
