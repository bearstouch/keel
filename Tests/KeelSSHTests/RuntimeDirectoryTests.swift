import Darwin
import XCTest
@testable import KeelSSH

final class RuntimeDirectoryTests: XCTestCase {
    private var base: String!

    override func setUpWithError() throws {
        base = (NSTemporaryDirectory() as NSString).appendingPathComponent("k\(RuntimeDirectory.randomID().prefix(6))")  // short: socket paths must fit sun_path
        XCTAssertEqual(mkdir(base, 0o700), 0)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: base) }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        return info.st_mode & 0o7777
    }

    func testOwnerOnlyAndSymlinkSafe() throws {
        let previous = umask(0o022)
        defer { umask(previous) }
        let directory = try RuntimeDirectory.create(base: base)
        XCTAssertTrue((directory.path as NSString).lastPathComponent.hasPrefix("keel-run-"))
        XCTAssertEqual(mode(directory.path), 0o700)
        XCTAssertTrue(RuntimeDirectory.isOwnerOnlyDirectory(directory.path))
        XCTAssertEqual(mode(directory.path + "/owner"), 0o600, "Records are owner-only")
        XCTAssertEqual(RuntimeDirectory.readRecord(directory.path + "/owner")?.pid, getpid())

        // A planted symlink (to a folder an attacker controls) is refused, never followed or reused.
        let elsewhere = base + "/elsewhere"
        XCTAssertEqual(mkdir(elsewhere, 0o777), 0)
        XCTAssertEqual(symlink(elsewhere, base + "/keel-run-planted"), 0)
        XCTAssertThrowsError(try RuntimeDirectory.create(base: base, name: "keel-run-planted")) { XCTAssertEqual($0 as? RuntimeDirectoryError, .unsafe) }
        XCTAssertFalse(RuntimeDirectory.isOwnerOnlyDirectory(base + "/keel-run-planted"), "lstat sees the link, not its target")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
        // An existing folder, even our own, is never reused; one open to others never counts as owner-only.
        XCTAssertThrowsError(try RuntimeDirectory.create(base: base, name: (directory.path as NSString).lastPathComponent))
        XCTAssertFalse(RuntimeDirectory.isOwnerOnlyDirectory(elsewhere))

        // Sockets: only a real socket owned by this user, never a symlink to one or a plain file.
        let socketPath = try directory.socketPath(id: "a1b2c3d4e5f6")
        let listener = try listen(at: socketPath)
        defer { close(listener) }
        XCTAssertEqual(mode(socketPath) & 0o077, 0)
        XCTAssertTrue(UnixSocketProbe.accepts(socketPath))
        XCTAssertEqual(symlink(socketPath, directory.path + "/t-link.sock"), 0)
        XCTAssertFalse(UnixSocketProbe.accepts(directory.path + "/t-link.sock"))
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path + "/t-file.sock", contents: Data()))
        XCTAssertFalse(UnixSocketProbe.accepts(directory.path + "/t-file.sock"))
        XCTAssertFalse(UnixSocketProbe.accepts(directory.path + "/t-missing.sock"))

        directory.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere), "Removal never follows a symlink out of the folder")
    }

    func testSocketPathMustFitSunPath() throws {
        let deep = base + "/" + String(repeating: "d", count: 80)
        XCTAssertEqual(mkdir(deep, 0o700), 0)
        let directory = try RuntimeDirectory.create(base: deep, owner: nil)
        defer { directory.remove() }
        XCTAssertThrowsError(try directory.socketPath(id: RuntimeDirectory.randomID())) { XCTAssertEqual($0 as? RuntimeDirectoryError, .pathTooLong) }
        // The real location ($TMPDIR) always fits.
        let real = try RuntimeDirectory.create(owner: nil)
        defer { real.remove() }
        XCTAssertNoThrow(try real.socketPath(id: RuntimeDirectory.randomID()))
    }

    func testStaleCleanupTerminatesOnlyOrphanedSSHOfDeadOwners() throws {
        let deadOwner = OwnedProcessIdentity(pid: 7_001, parentPID: 1, groupID: 7_001, startedSeconds: 100, startedMicroseconds: 0)
        let liveOwner = OwnedProcessIdentity(pid: 7_002, parentPID: 1, groupID: 7_002, startedSeconds: 100, startedMicroseconds: 0)
        let orphan = OwnedProcessIdentity(pid: 8_001, parentPID: 7_001, groupID: 8_001, startedSeconds: 200, startedMicroseconds: 0)
        let reused = OwnedProcessIdentity(pid: 8_002, parentPID: 7_001, groupID: 8_002, startedSeconds: 200, startedMicroseconds: 0)
        let ofLiveOwner = OwnedProcessIdentity(pid: 8_003, parentPID: 7_002, groupID: 8_003, startedSeconds: 200, startedMicroseconds: 0)
        // Live process table: the dead owner's PID is now someone else, the orphan was reparented to launchd,
        // 8002 is a different process with the same PID, the live owner and its ssh still run.
        let table: [Int32: OwnedProcessIdentity] = [
            7_001: OwnedProcessIdentity(pid: 7_001, parentPID: 1, groupID: 7_001, startedSeconds: 999, startedMicroseconds: 0), 7_002: liveOwner,
            8_001: OwnedProcessIdentity(pid: 8_001, parentPID: 1, groupID: 8_001, startedSeconds: 200, startedMicroseconds: 0),
            8_002: OwnedProcessIdentity(pid: 8_002, parentPID: 1, groupID: 8_002, startedSeconds: 555, startedMicroseconds: 0),
            8_003: ofLiveOwner
        ]
        let dead = try RuntimeDirectory.create(base: base, owner: deadOwner)
        try dead.writeRecord(orphan, named: dead.recordName(id: "aaaaaaaaaaaa"))
        try dead.writeRecord(reused, named: dead.recordName(id: "bbbbbbbbbbbb"))
        let live = try RuntimeDirectory.create(base: base, owner: liveOwner)
        try live.writeRecord(ofLiveOwner, named: live.recordName(id: "cccccccccccc"))
        let unrelated = base + "/keel-askpass-0123"
        XCTAssertEqual(mkdir(unrelated, 0o700), 0)

        let signalled = SignalLog()
        var cleanup = StaleTunnelCleanup(base: base)
        cleanup.readIdentity = { table[$0] }
        cleanup.executablePath = { _ in "/usr/bin/ssh" }
        cleanup.signalGroup = { pid, signal in
            signalled.append(pid); XCTAssertEqual(signal, SIGTERM)
        }
        XCTAssertEqual(cleanup.run(), 1)
        XCTAssertEqual(signalled.values, [8_001], "Only the orphan of the dead run; never a reused PID or a running Keel's ssh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path + "/t-cccccccccccc.pid"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))

        // Something other than ssh under a matching identity is left alone.
        let other = try RuntimeDirectory.create(base: base, owner: deadOwner)
        try other.writeRecord(orphan, named: other.recordName(id: "dddddddddddd"))
        cleanup.executablePath = { _ in "/bin/zsh" }
        XCTAssertEqual(cleanup.run(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    private func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let previous = umask(0o177)
        defer { umask(previous) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        return fd
    }
}

/// The real launcher, with `/bin/sh` standing in for ssh: argv without a shell's parsing, exit status, stderr tail,
/// and process-group termination.
final class SSHProcessLauncherTests: XCTestCase {
    func testReportsExitStatusAndSanitizedLastStderrLine() async throws {
        let script = "echo 'Warning: Permanently added host' >&2; printf 'channel 0: open failed: \\033[31madministratively prohibited\\033[0m\\r\\n\\n' >&2; exit 255"
        let process = try SSHProcessLauncher().launch(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
        let exit = await process.waitForExit()
        XCTAssertEqual(exit, TunnelExit(status: .exited(255), lastErrorLine: "channel 0: open failed: administratively prohibited"))
        XCTAssertFalse(process.group.signal(SIGTERM), "A reaped process is never signalled")
    }

    func testArgumentsReachTheProcessVerbatim() async throws {
        // `$1` is "a b; id": a shell never re-parses it, so the test command sees one argument.
        let process = try SSHProcessLauncher().launch(
            executable: "/bin/sh", arguments: ["-c", "[ \"$1\" = 'a b; id' ] && [ \"$#\" = 1 ] && [ \"$KEEL_T\" = v ] || exit 9", "sh", "a b; id"], environment: ["KEEL_T": "v"])
        let exit = await process.waitForExit()
        XCTAssertEqual(exit.status, .exited(0))
    }

    func testSignalsTheWholeProcessGroup() async throws {
        let process = try SSHProcessLauncher().launch(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"], environment: [:])
        let identity = try XCTUnwrap(process.group.identity)
        XCTAssertEqual(identity.groupID, identity.pid, "ssh leads its own group")
        XCTAssertEqual(identity.parentPID, getpid())
        XCTAssertTrue(process.group.signal(SIGTERM))
        let exit = await process.waitForExit()
        XCTAssertEqual(exit.status, .signaled(SIGTERM))
        // The background `sleep` (a ProxyCommand stand-in) went with it.
        var gone = false
        for _ in 0..<200 where !gone {
            gone = kill(-identity.pid, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(gone, "No member of the group survives")
    }

    func testLaunchFailureIsReported() {
        XCTAssertThrowsError(try SSHProcessLauncher().launch(executable: "/nonexistent/ssh", arguments: [], environment: [:])) {
            XCTAssertEqual($0 as? TunnelError, .launchFailed(ENOENT))
        }
    }

    func testSanitizedLastLine() {
        XCTAssertNil(TunnelExit.sanitizedLastLine(Data("\n\r\n  \n".utf8)))
        XCTAssertEqual(TunnelExit.sanitizedLastLine(Data("a\n\u{1B}]0;title\u{7}b\u{202E}c\t\u{0}d\n".utf8)), "b c d", "Escapes, bidi overrides and controls never reach the UI")
        let long = String(repeating: "x", count: 1_000)
        XCTAssertEqual(TunnelExit.sanitizedLastLine(Data(long.utf8))?.count, 240)
    }
}
