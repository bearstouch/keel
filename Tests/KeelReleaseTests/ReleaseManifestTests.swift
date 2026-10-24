import XCTest
@testable import KeelCore
@testable import KeelRelease

final class ReleaseManifestTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func manifest() throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: root.appendingPathComponent("release/manifest.json")))
    }

    func testManifestMatchesPackagePlatform() throws {
        let manifest = try manifest()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertEqual(ReleaseManifest.packageMinimumMacOS(in: package), manifest.minimumMacOS, "Package.swift and the manifest agree on macOS")
        XCTAssertEqual(manifest.minimumMacOS, "14.0")
        XCTAssertEqual(manifest.bundleIdentifier, AppInstanceIdentity.production)
        XCTAssertEqual(Set(manifest.architectures), ["arm64", "x86_64"], "Universal 2")
        XCTAssertTrue(manifest.artifacts.contains("Keel.app/Contents/Helpers/keel-askpass"), "The askpass helper is bundled")
        XCTAssertEqual(manifest.version, AppVersion.release, "SwiftPM builds report the manifest version")
    }

    /// INT-11: an HTTPS feed on the Bearstouch host, a real Ed25519 public key, the same Sparkle version that
    /// `Package.swift` pins exactly and `Package.resolved` resolved, and the committed Info.plist carrying both.
    func testManifestHasSparkleFeedAndKey() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.sparkleProblems, [])
        XCTAssertEqual(URL(string: manifest.sparkle.feedURL)?.scheme, "https")
        XCTAssertEqual(URL(string: manifest.sparkle.feedURL)?.host, "bearstouch.com")
        XCTAssertEqual(Data(base64Encoded: manifest.sparkle.publicEDKey)?.count, 32, "An Ed25519 public key")
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains(#"Sparkle", exact: "\#(manifest.sparkle.version)""#), "Package.swift pins the manifest's Sparkle exactly")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Package.resolved"))) as? [String: Any]
        let pin = (resolved?["pins"] as? [[String: Any]])?.first { $0["identity"] as? String == "sparkle" }?["state"] as? [String: Any]
        let dependency = try XCTUnwrap(manifest.dependencies.first { $0.name == "Sparkle" })
        XCTAssertEqual(pin?["version"] as? String, manifest.sparkle.version)
        XCTAssertEqual(pin?["revision"] as? String, dependency.revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(dependency.licenseFile).path))
        let info = try infoPlist()
        XCTAssertEqual(info["SUFeedURL"] as? String, manifest.sparkle.feedURL)
        XCTAssertEqual(info["SUPublicEDKey"] as? String, manifest.sparkle.publicEDKey)

        // A broken record is reported, each problem once.
        let broken = try JSONDecoder().decode(
            ReleaseManifest.self,
            from: JSONSerialization.data(withJSONObject: [
                "bundleIdentifier": "com.bearstouch.keel", "name": "Keel", "version": "0.1.0", "minimumMacOS": "14.0", "architectures": ["arm64"], "packageFormat": "dmg",
                "iconName": "AppIcon", "artifacts": [], "dependencies": [], "releaseChecks": [],
                "sparkle": ["version": "2.10.0", "feedURL": "http://bearstouch.com/keel/appcast.xml", "downloadURLPrefix": "https://bearstouch.com/keel", "publicEDKey": "c2hvcnQ="]
            ]))
        XCTAssertEqual(broken.sparkleProblems.count, 4, "\(broken.sparkleProblems)")
    }

    /// The committed Info.plist is the packaged app's (MAC-14, AC2): identity, minimum OS, icon and version from the
    /// manifest, and the Local Network purpose string.
    func testInfoPlistMatchesManifest() throws {
        let manifest = try manifest(), info = try infoPlist()
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, manifest.bundleIdentifier)
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, manifest.minimumMacOS)
        XCTAssertEqual(info["CFBundleIconName"] as? String, manifest.iconName)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, manifest.version)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Keel")
        XCTAssertEqual(info["NSLocalNetworkUsageDescription"] as? String, "Keel connects to Redis servers on your local network that you configure.")
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("release/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testProblemsReportEveryMismatch() throws {
        let manifest = try manifest()
        let good = ReleaseManifest.BuiltProduct(bundleIdentifier: "com.bearstouch.keel", minimumMacOS: "14.0", architectures: ["arm64", "x86_64"], files: Set(manifest.artifacts), iconName: "AppIcon")
        XCTAssertEqual(manifest.problems(packageMinimumMacOS: "14.0", product: good), [])
        var bad = good
        bad.architectures = ["arm64"]
        bad.minimumMacOS = "13.0"
        bad.bundleIdentifier = "com.bearstouch.keel.dev"
        bad.files.remove("Keel.app/Contents/Helpers/keel-askpass")
        bad.iconName = nil
        let problems = manifest.problems(packageMinimumMacOS: "15.0", product: bad)
        XCTAssertEqual(problems.count, 6, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("x86_64") })
        XCTAssertTrue(problems.contains { $0.contains("keel-askpass") })
    }

    func testIconInBundle() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.iconName, "AppIcon")
        let icon = ["Keel.app/Contents/Resources/Assets.car", "Keel.app/Contents/Resources/AppIcon.icns"]
        for path in icon { XCTAssertTrue(manifest.artifacts.contains(path), "\(path) is a release artifact") }
        var product = ReleaseManifest.BuiltProduct(
            bundleIdentifier: manifest.bundleIdentifier, minimumMacOS: manifest.minimumMacOS, architectures: Set(manifest.architectures), files: Set(manifest.artifacts), iconName: "Keel")
        product.files.subtract(icon)
        let problems = manifest.problems(packageMinimumMacOS: manifest.minimumMacOS, product: product)
        XCTAssertEqual(problems.count, 3, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("CFBundleIconName is Keel") })

        // The packaging step itself: the committed Icon Composer bundle compiles into an Assets.car with the Default,
        // Dark and Tinted appearances (DS-09), beside the committed .icns. Needs Xcode's actool, as CI has.
        guard run("/usr/bin/xcrun", ["--find", "actool"]).status == 0 else { throw XCTSkip("actool is not installed") }
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("keel-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resources) }
        let compile = run(root.appendingPathComponent("scripts/generate-app-icon.sh").path, ["--compile", resources.path])
        XCTAssertEqual(compile.status, 0, compile.output)
        XCTAssertTrue(Set(try FileManager.default.contentsOfDirectory(atPath: resources.path)).isSuperset(of: ["AppIcon.icns", "Assets.car"]))
        XCTAssertEqual(
            try Data(contentsOf: resources.appendingPathComponent("AppIcon.icns")), try Data(contentsOf: root.appendingPathComponent("release/icon/AppIcon.icns")),
            "The bundle ships the committed .icns with the small form, not actool's flattening")
        let info = run("/usr/bin/xcrun", ["assetutil", "--info", resources.appendingPathComponent("Assets.car").path])
        XCTAssertEqual(info.status, 0, info.output)
        for appearance in ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"] {
            XCTAssertTrue(info.output.contains(appearance), "Assets.car has the \(appearance) icon")
        }
    }

    /// Runs a tool to completion, returning its status and combined output.
    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        // Read before waiting: a full pipe would otherwise block the tool forever.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func testPackageMinimumParsing() {
        XCTAssertEqual(ReleaseManifest.packageMinimumMacOS(in: "platforms: [.macOS(.v14)]"), "14.0")
        XCTAssertEqual(ReleaseManifest.packageMinimumMacOS(in: "platforms: [.macOS(.v15)]"), "15.0")
        XCTAssertNil(ReleaseManifest.packageMinimumMacOS(in: "platforms: []"))
    }
}
