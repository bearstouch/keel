import Foundation
import XCTest

@testable import KeelSSH

final class SSHConfigScanTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("keel-ssh-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh/conf.d"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(_ text: String, _ path: String) throws { try text.write(to: home.appendingPathComponent(path), atomically: true, encoding: .utf8) }

    private func scan(_ arguments: [String] = ["-G", "--", "ops"]) -> SSHConfigScan {
        // The system file is left out so the machine's /etc/ssh/ssh_config can't change the answer.
        SSHConfigScan.scan(arguments: arguments, home: home.path, read: { $0 == "/etc/ssh/ssh_config" ? nil : try SSHConfigDiscovery.readConfig(URL(fileURLWithPath: $0)) })
    }

    func testFindsForwardsAndMatchExecInAnyBlock() throws {
        try write("Host ops\n  User deploy\n", ".ssh/config")
        XCTAssertEqual(scan(), SSHConfigScan())
        try write("Host other\n  LocalForward 6380 localhost:6379\n", ".ssh/config")
        XCTAssertEqual(scan(), SSHConfigScan(forwards: true))
        try write("Match host x !exec \"test -f /x\"\n  DynamicForward=1080\n", ".ssh/config")
        XCTAssertEqual(scan(), SSHConfigScan(forwards: true, matchExec: true))
        try write("Match host exec.example.com\n  User x\n# Match exec \"true\"\n", ".ssh/config")
        XCTAssertEqual(scan(), SSHConfigScan(), "a host named exec.* and a comment aren't exec criteria")
    }

    func testFollowsIncludesLikeSSH() throws {
        try write("Include conf.d/*.conf ~/.ssh/extra /missing/file\n", ".ssh/config")
        try write("Host a\n  RemoteForward 9000 localhost:22\n", ".ssh/conf.d/a.conf")
        try write("Match exec true\n", ".ssh/extra")
        XCTAssertEqual(scan(), SSHConfigScan(forwards: true, matchExec: true), "relative, tilde and glob includes are read; a missing one is ignored as ssh does")
        try write("Include config\n", ".ssh/extra")
        XCTAssertEqual(scan(), SSHConfigScan(forwards: true), "a cycle ends")
        try write("Include ~/.ssh/%h.conf\n", ".ssh/config")
        XCTAssertFalse(scan().complete, "an include with %-tokens can't be resolved without ssh")
    }

    func testConfigFileArgument() throws {
        try write("Host ops\n  LocalForward 1 a:2\n", "custom")
        XCTAssertEqual(scan(["-F", home.appendingPathComponent("custom").path, "-G", "--", "ops"]), SSHConfigScan(forwards: true))
        XCTAssertEqual(scan(["-F", "none", "-G", "--", "ops"]), SSHConfigScan())
        XCTAssertFalse(scan(["-G", "-F", home.appendingPathComponent("missing").path]).complete, "a missing -F file is ssh's error, not an empty config")
        XCTAssertNil(SSHConfigScan.configFileArgument(["-G", "--", "-F"]), "nothing after -- is an option")
    }

    func testUnreadableFileIsIncomplete() {
        let result = SSHConfigScan.scan(arguments: ["-G"], home: home.path, read: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertFalse(result.complete)
    }

    /// The launcher decides from the scan whether `ssh -G` runs; an executable that can't start shows when it would have.
    func testLauncherRunsSSHOnlyWhenForwardsAndNoMatchExec() async {
        func answer(_ config: SSHConfigScan) async -> String? {
            await SSHProcessLauncher(scanConfig: { _ in config }).effectiveOptions(executable: "/nonexistent/ssh", arguments: ["-G"], environment: [:], timeout: .seconds(5))
        }
        let none = await answer(SSHConfigScan())
        XCTAssertEqual(none, "", "no forward anywhere: nothing to refuse, ssh isn't run")
        let exec = await answer(SSHConfigScan(forwards: true, matchExec: true))
        XCTAssertNil(exec, "Match exec: the check is skipped")
        let unread = await answer(SSHConfigScan(forwards: true, complete: false))
        XCTAssertNil(unread)
        let runs = await answer(SSHConfigScan(forwards: true))
        XCTAssertNil(runs, "forwards without Match exec run ssh -G (here it can't start)")
    }

    /// The real `/usr/bin/ssh -G` would run the `Match exec` command; the check must not.
    func testRealCheckNeverRunsMatchExec() async throws {
        let marker = home.appendingPathComponent("ran")
        try write("Match exec \"/usr/bin/touch \(marker.path)\"\n  User x\nHost ops\n  LocalForward 6380 localhost:6379\n", "config")
        let output = await SSHProcessLauncher().effectiveOptions(
            executable: SSHTunnelArguments.executable, arguments: ["-G", "-F", home.appendingPathComponent("config").path, "--", "ops"], environment: ["HOME": home.path],
            timeout: .seconds(10))
        XCTAssertNil(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "ssh -G ran the user's Match exec command")
    }
}
