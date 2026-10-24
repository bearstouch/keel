import Foundation

/// The parts of Sparkle's `SPUUpdater` the policy sets; the app conforms the real updater, tests a fake.
@MainActor
public protocol UpdaterControlling: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var sendsSystemProfile: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
}

/// How Keel updates itself (FR-AP07, INT-11, MAC-08): Sparkle 2 over an HTTPS feed with an EdDSA-signed appcast and
/// archives, a daily check that the user can turn off, installs only after the user confirms, and no system profile.
public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 86_400

    /// The Sparkle keys every packaged `Info.plist` must carry with exactly these values (`release/Info.plist`).
    /// `SUAllowsAutomaticUpdates = NO` removes "install automatically": every install waits for the user.
    public static let requiredInfoValues: [String: Bool] = [
        "SUEnableSystemProfiling": false, "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false, "SUEnableAutomaticChecks": true,
        "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true
    ]
    /// Keys that would send or enable a system profile; none may appear in `Info.plist`.
    public static let forbiddenInfoKeys = ["SUSendProfileInfo", "SUCustomFeedParameters"]

    /// `UserDefaults` keys Sparkle writes in Keel's domain; Remove Keel Data… removes them (MAC-22).
    public static let sparklePreferenceKeys = [
        "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo", "SUScheduledCheckInterval", "SULastCheckTime", "SULastProfileSubmissionDate",
        "SUHasLaunchedBefore", "SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion", "SUUpdateGroupIdentifier",
        "SUInitialFailedFeedSigningValidationDate"
    ]

    /// Whether this bundle can update itself: the installed identity with an HTTPS feed and a public EdDSA key. `swift run`
    /// and development builds have neither, so they never start an updater or contact the network.
    public static func isAvailable(info: [String: Any]?, productionBundleIdentifier: String) -> Bool {
        guard let info, info["CFBundleIdentifier"] as? String == productionBundleIdentifier,
            let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
            let key = info["SUPublicEDKey"] as? String, isPublicEDKey(key)
        else { return false }
        return true
    }

    /// An Ed25519 public key as Sparkle stores it: base64 of 32 bytes.
    public static func isPublicEDKey(_ text: String) -> Bool { Data(base64Encoded: text)?.count == 32 }

    /// Every way `info` departs from the policy and the manifest's Sparkle record; empty means consistent.
    public static func problems(info: [String: Any], sparkle: ReleaseManifest.Sparkle) -> [String] {
        var problems: [String] = []
        if info["SUFeedURL"] as? String != sparkle.feedURL { problems.append("SUFeedURL is not the manifest feed \(sparkle.feedURL).") }
        if info["SUPublicEDKey"] as? String != sparkle.publicEDKey { problems.append("SUPublicEDKey is not the manifest key.") }
        if (info["SUScheduledCheckInterval"] as? NSNumber)?.doubleValue != checkInterval { problems.append("SUScheduledCheckInterval is not \(Int(checkInterval)) (daily).") }
        for (key, value) in requiredInfoValues.sorted(by: { $0.key < $1.key }) where (info[key] as? Bool) != value { problems.append("\(key) must be \(value ? "YES" : "NO").") }
        for key in forbiddenInfoKeys where info[key] != nil { problems.append("\(key) must not be set.") }
        return problems
    }

    /// Puts the user's choice on the updater at launch and on every Apply. Whatever else Sparkle remembered, downloads
    /// never start on their own and no system profile is sent.
    @MainActor
    public static func apply(checksAutomatically: Bool, to updater: some UpdaterControlling) {
        updater.sendsSystemProfile = false
        updater.automaticallyDownloadsUpdates = false
        updater.updateCheckInterval = checkInterval
        updater.automaticallyChecksForUpdates = checksAutomatically
    }
}
