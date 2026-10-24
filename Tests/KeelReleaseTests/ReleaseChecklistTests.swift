import XCTest
@testable import KeelRelease

final class ReleaseChecklistTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func manifest() throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: root.appendingPathComponent("release/manifest.json")))
    }

    private func evidence(_ manifest: ReleaseManifest, _ status: (String) -> ReleaseEvidence.Status = { _ in .passed }) -> ReleaseEvidence {
        let checks = manifest.releaseChecks.map { ReleaseEvidence.Check(id: $0, status: status($0), detail: "detail") }
        return ReleaseEvidence(version: manifest.version, channel: ReleaseChecklist.channel(for: checks), checks: checks, artifacts: ["Keel-\(manifest.version).dmg": "00"])
    }

    /// AC4: evidence lists every check the manifest names; a missing, failed, duplicated or unknown check, or a release
    /// claimed over a skipped one, is a problem.
    func testEvidenceRequiresAllChecks() throws {
        let manifest = try manifest()
        XCTAssertEqual(
            Set(manifest.releaseChecks),
            [
                "manifest", "architectures", "minimumOS", "signature", "hardenedRuntime", "entitlements", "launch", "developerID", "notarization", "stapling", "gatekeeper",
                "updateSignature", "feedSignature", "checksums", "performance"
            ])
        let complete = evidence(manifest)
        XCTAssertEqual(complete.channel, .release)
        XCTAssertEqual(ReleaseChecklist.problems(complete, manifest: manifest), [])

        var missing = complete
        missing.checks.removeAll { $0.id == "notarization" }
        XCTAssertEqual(ReleaseChecklist.problems(missing, manifest: manifest), ["Missing check notarization."])

        let failed = evidence(manifest) { $0 == "notarization" ? .failed : .passed }
        XCTAssertEqual(ReleaseChecklist.problems(failed, manifest: manifest), ["Check notarization failed: detail"])

        var claimed = evidence(manifest) { $0 == "gatekeeper" ? .skipped : .passed }
        XCTAssertEqual(claimed.channel, .prerelease, "A skipped check makes a pre-release")
        XCTAssertEqual(ReleaseChecklist.problems(claimed, manifest: manifest), [])
        claimed.channel = .release
        XCTAssertEqual(ReleaseChecklist.problems(claimed, manifest: manifest), ["A build with skipped checks can only be a pre-release."])

        var odd = complete
        odd.checks += [ReleaseEvidence.Check(id: "signature", status: .passed), ReleaseEvidence.Check(id: "vibes", status: .passed)]
        odd.artifacts = [:]
        odd.version = "9.9.9"
        XCTAssertEqual(
            ReleaseChecklist.problems(odd, manifest: manifest),
            ["Check signature is recorded more than once.", "Evidence is for 9.9.9, the manifest is \(manifest.version).", "No artifact checksums recorded.", "Unknown check vibes."])
    }

    /// The script finishes with `scripts/release-evidence.py`; it must judge evidence exactly as `ReleaseChecklist` does.
    func testScriptAgreesWithChecklist() throws {
        let manifest = try manifest()
        var claimed = evidence(manifest) { $0 == "gatekeeper" ? .skipped : .passed }
        claimed.channel = .release
        var missing = evidence(manifest)
        missing.checks.removeLast()
        let cases = [evidence(manifest), evidence(manifest) { $0 == "notarization" ? .failed : .passed }, evidence(manifest) { $0 == "developerID" ? .skipped : .passed }, claimed, missing]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keel-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, evidence) in cases.enumerated() {
            let file = folder.appendingPathComponent("\(index).json")
            try JSONEncoder().encode(evidence).write(to: file)
            let status = try run("/usr/bin/python3", ["-I", root.appendingPathComponent("scripts/release-evidence.py").path, "check", file.path])
            XCTAssertEqual(status == 0, ReleaseChecklist.problems(evidence, manifest: manifest).isEmpty, "case \(index)")
        }
    }

    /// Every check the manifest names is recorded by `package-release.sh`, so the evidence can be complete.
    func testPackageScriptRecordsEveryCheck() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/package-release.sh"), encoding: .utf8)
        for id in try manifest().releaseChecks { XCTAssertTrue(script.contains("record \(id) "), "package-release.sh records \(id)") }
    }

    /// MAC-11 / NFR-SC07: every action in every workflow is pinned to a full commit SHA, and the release workflow
    /// packages through the script that writes the evidence.
    func testWorkflowActionsArePinned() throws {
        let folder = root.appendingPathComponent(".github/workflows")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".yml") }
        XCTAssertTrue(files.contains("release.yml"))
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("uses:") {
                XCTAssertNotNil(line.range(of: #"uses: [\w.-]+/[\w./-]+@[0-9a-f]{40}( |$)"#, options: .regularExpression), "\(file): \(line)")
            }
        }
        let release = try String(contentsOf: folder.appendingPathComponent("release.yml"), encoding: .utf8)
        XCTAssertTrue(release.contains("scripts/package-release.sh"))
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
}
