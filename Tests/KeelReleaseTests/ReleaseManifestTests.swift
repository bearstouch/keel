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

    func testProblemsReportEveryMismatch() throws {
        let manifest = try manifest()
        let good = ReleaseManifest.BuiltProduct(bundleIdentifier: "com.bearstouch.keel", minimumMacOS: "14.0", architectures: ["arm64", "x86_64"], files: Set(manifest.artifacts))
        XCTAssertEqual(manifest.problems(packageMinimumMacOS: "14.0", product: good), [])
        var bad = good
        bad.architectures = ["arm64"]
        bad.minimumMacOS = "13.0"
        bad.bundleIdentifier = "com.bearstouch.keel.dev"
        bad.files.remove("Keel.app/Contents/Helpers/keel-askpass")
        let problems = manifest.problems(packageMinimumMacOS: "15.0", product: bad)
        XCTAssertEqual(problems.count, 5, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("x86_64") })
        XCTAssertTrue(problems.contains { $0.contains("keel-askpass") })
    }

    func testPackageMinimumParsing() {
        XCTAssertEqual(ReleaseManifest.packageMinimumMacOS(in: "platforms: [.macOS(.v14)]"), "14.0")
        XCTAssertEqual(ReleaseManifest.packageMinimumMacOS(in: "platforms: [.macOS(.v15)]"), "15.0")
        XCTAssertNil(ReleaseManifest.packageMinimumMacOS(in: "platforms: []"))
    }
}
