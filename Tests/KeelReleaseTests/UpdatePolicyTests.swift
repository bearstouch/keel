import XCTest
@testable import KeelCore
@testable import KeelRelease

@MainActor
final class UpdatePolicyTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// What Sparkle's updater would hold, starting from the worst a previous run (or a hand-edited default) could leave.
    private final class FakeUpdater: UpdaterControlling {
        var automaticallyChecksForUpdates = false, automaticallyDownloadsUpdates = true, sendsSystemProfile = true
        var updateCheckInterval: TimeInterval = 3_600
    }

    private func manifest() throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: root.appendingPathComponent("release/manifest.json")))
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("release/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// INT-11: `SUEnableSystemProfiling = NO`, no profile keys in the bundle, and the updater never sends one, whatever
    /// Sparkle remembered from before.
    func testNoSystemProfiling() throws {
        let info = try infoPlist(), sparkle = try manifest().sparkle
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        for key in UpdatePolicy.forbiddenInfoKeys { XCTAssertNil(info[key], key) }
        XCTAssertEqual(UpdatePolicy.problems(info: info, sparkle: sparkle), [])
        var profiling = info
        profiling["SUEnableSystemProfiling"] = true
        profiling["SUSendProfileInfo"] = true
        XCTAssertEqual(UpdatePolicy.problems(info: profiling, sparkle: sparkle), ["SUEnableSystemProfiling must be NO.", "SUSendProfileInfo must not be set."])

        for choice in [true, false] {
            let updater = FakeUpdater()
            UpdatePolicy.apply(checksAutomatically: choice, to: updater)
            XCTAssertFalse(updater.sendsSystemProfile)
        }
    }

    /// FR-AP07: the daily check is on by default and the General toggle turns it off; installs always wait for the user
    /// (no automatic download, `SUAllowsAutomaticUpdates = NO`).
    func testChecksCanBeDisabled() throws {
        XCTAssertTrue(SettingsDocument().checksForUpdates, "On by default")
        let updater = FakeUpdater()
        UpdatePolicy.apply(checksAutomatically: true, to: updater)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertEqual(updater.updateCheckInterval, 86_400, "Daily")
        UpdatePolicy.apply(checksAutomatically: false, to: updater)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates, "Installs wait for the user")

        // The choice survives settings.json, and a file from before KEEL-052 reads as on.
        var document = SettingsDocument()
        document.checksForUpdates = false
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertFalse(decoded.checksForUpdates)
        XCTAssertTrue(try JSONDecoder().decode(SettingsDocument.self, from: Data(#"{"theme":"dark","checksForUpdates":"no"}"#.utf8)).checksForUpdates)
        XCTAssertTrue(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)).checksForUpdates)

        let info = try infoPlist()
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true, "Set in the bundle, so Sparkle never asks at launch")
    }

    /// Only the installed identity with an HTTPS feed and a key gets an updater; `swift run` (no Info.plist), the
    /// development identity and an http feed never contact the network.
    func testUpdaterOnlyInPackagedBuilds() throws {
        let info = try infoPlist(), production = AppInstanceIdentity.production
        XCTAssertTrue(UpdatePolicy.isAvailable(info: info, productionBundleIdentifier: production))
        XCTAssertFalse(UpdatePolicy.isAvailable(info: nil, productionBundleIdentifier: production))
        var dev = info
        dev["CFBundleIdentifier"] = AppInstanceIdentity.development
        XCTAssertFalse(UpdatePolicy.isAvailable(info: dev, productionBundleIdentifier: production))
        var http = info
        http["SUFeedURL"] = "http://bearstouch.com/keel/appcast.xml"
        XCTAssertFalse(UpdatePolicy.isAvailable(info: http, productionBundleIdentifier: production))
        var keyless = info
        keyless["SUPublicEDKey"] = ""
        XCTAssertFalse(UpdatePolicy.isAvailable(info: keyless, productionBundleIdentifier: production))
    }

    /// MAC-22: Remove Keel Data… takes what Sparkle stored in Keel's defaults, and only Keel's keys.
    func testDataRemovalIncludesSparklePreferences() {
        for key in ["SULastCheckTime", "SUEnableAutomaticChecks", "SUSkippedVersion"] { XCTAssertTrue(DataRemovalPlanner.preferenceKeys.contains(key), key) }
        XCTAssertTrue(DataRemovalPlanner.preferenceKeys.allSatisfy { $0 == "keyboardShortcuts" || $0.hasPrefix("SU") })
    }
}
