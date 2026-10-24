import Foundation

/// `dist/release-evidence.json`, written by `scripts/package-release.sh` (MAC-10, MAC-11). Fields the checklist doesn't
/// read (`performance`, the tool output) are left to the file.
public struct ReleaseEvidence: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Ran and held.
        case passed
        /// Ran and didn't hold: the script exits non-zero and nothing is published.
        case failed
        /// Couldn't run in this build (ad-hoc signing, no notary profile, no EdDSA key, no benchmark evidence).
        case skipped
    }

    public enum Channel: String, Codable, Sendable { case release, prerelease }

    public struct Check: Codable, Equatable, Sendable {
        public var id: String, status: Status, detail: String

        public init(id: String, status: Status, detail: String = "") { self.id = id; self.status = status; self.detail = detail }
    }

    public var version: String
    public var channel: Channel
    public var checks: [Check]
    /// Published file name → SHA-256, as in `SHA256SUMS.txt`.
    public var artifacts: [String: String]

    public init(version: String, channel: Channel, checks: [Check], artifacts: [String: String] = [:]) {
        self.version = version; self.channel = channel; self.checks = checks; self.artifacts = artifacts
    }
}

/// What makes evidence complete (MAC-11, AC4). `scripts/release-evidence.py` applies the same rules when the script
/// finishes; `ReleaseChecklistTests` runs both on the same evidence.
public enum ReleaseChecklist {
    /// The channel a build may be published on: a release only when every check passed. Anything skipped (an ad-hoc,
    /// signed-but-not-notarized or keyless build) is at most a pre-release.
    public static func channel(for checks: [ReleaseEvidence.Check]) -> ReleaseEvidence.Channel {
        checks.allSatisfy { $0.status == .passed } ? .release : .prerelease
    }

    /// Every reason `evidence` can't be published as it says; empty means it can.
    public static func problems(_ evidence: ReleaseEvidence, manifest: ReleaseManifest) -> [String] {
        var problems: [String] = []
        if evidence.version != manifest.version { problems.append("Evidence is for \(evidence.version), the manifest is \(manifest.version).") }
        let ids = evidence.checks.map(\.id)
        for id in manifest.releaseChecks where !ids.contains(id) { problems.append("Missing check \(id).") }
        for id in Set(ids) where ids.filter({ $0 == id }).count > 1 { problems.append("Check \(id) is recorded more than once.") }
        for id in ids where !manifest.releaseChecks.contains(id) { problems.append("Unknown check \(id).") }
        for check in evidence.checks where check.status == .failed { problems.append("Check \(check.id) failed: \(check.detail)") }
        // A release channel claimed over a skipped check would publish an unverified build as final.
        if evidence.channel == .release && channel(for: evidence.checks) != .release { problems.append("A build with skipped checks can only be a pre-release.") }
        if evidence.artifacts.isEmpty { problems.append("No artifact checksums recorded.") }
        return problems.sorted()
    }
}
