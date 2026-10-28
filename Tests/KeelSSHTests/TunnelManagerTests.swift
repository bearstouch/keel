import Darwin
import XCTest
@testable import KeelSSH

/// Grace-period sleeps (≥ 1 s) wait until the test fires them; poll sleeps take 1 ms of real time.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        guard duration >= .seconds(1) else { try await Task.sleep(for: .milliseconds(1)); return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                pending.append(continuation); requested.append(duration)
            }
        }
    }

    var pendingCount: Int { lock.withLock { pending.count } }

    /// Lets every waiting grace period elapse.
    func fire() {
        let waiting = lock.withLock {
            defer { pending = [] }; return pending
        }
        waiting.forEach { $0.resume() }
    }
}

/// A process table entry the fake `readIdentity` serves; `reuse` simulates the PID now belonging to another process.
final class FakeProcess: TunnelProcess, @unchecked Sendable {
    static let owner: Int32 = 4_242
    private let lock = NSLock()
    private var finished: TunnelExit?
    private var waiters: [CheckedContinuation<TunnelExit, Never>] = []
    private var reused = false
    private(set) var signals: [Int32] = []
    private var processGroup: OwnedProcessGroup!
    var group: OwnedProcessGroup { processGroup }
    let arguments: [String]
    let environment: [String: String]
    /// Exits with this status when SIGTERM arrives (nil: ignores SIGTERM, dies only on SIGKILL).
    var exitOnTerm: Bool

    init(pid: Int32, arguments: [String], environment: [String: String], exitOnTerm: Bool = true) {
        self.arguments = arguments; self.environment = environment; self.exitOnTerm = exitOnTerm
        processGroup = OwnedProcessGroup(
            pid: pid, ownerPID: Self.owner,
            readIdentity: { [unowned self] pid in
                let started: UInt64 = lock.withLock { reused } ? 2_000 : 1_000
                return lock.withLock { finished } == nil ? OwnedProcessIdentity(pid: pid, parentPID: Self.owner, groupID: pid, startedSeconds: started, startedMicroseconds: 7) : nil
            },
            sendSignal: { [unowned self] _, signal in
                lock.withLock { signals.append(signal) }
                if signal == SIGKILL || (signal == SIGTERM && exitOnTerm) { finish(TunnelExit(status: .signaled(signal), lastErrorLine: nil)) }
            })
    }

    var exit: TunnelExit? { lock.withLock { finished } }
    var sentSignals: [Int32] { lock.withLock { signals } }
    func reusePID() { lock.withLock { reused = true } }

    func waitForExit() async -> TunnelExit {
        await withCheckedContinuation { continuation in
            let done: TunnelExit? = lock.withLock {
                if let finished { return finished }
                waiters.append(continuation); return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func finish(_ exit: TunnelExit) {
        let waiting = lock.withLock { () -> [CheckedContinuation<TunnelExit, Never>] in
            guard finished == nil else { return [] }
            finished = exit
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume(returning: exit) }
    }
}

final class FakeLauncher: TunnelProcessLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [FakeProcess] = []
    var exitOnTerm = true
    /// Called with each new process before `launch` returns (e.g. to make it exit at once).
    var onLaunch: (@Sendable (FakeProcess) -> Void)?

    func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess {
        let process = lock.withLock { () -> FakeProcess in
            let process = FakeProcess(pid: Int32(50_000 + launched.count), arguments: [executable] + arguments, environment: environment, exitOnTerm: exitOnTerm)
            launched.append(process)
            return process
        }
        onLaunch?(process)
        return process
    }

    /// `ssh -G` output, built from the socket path in the arguments; nil answers like an unreadable config.
    var options: (@Sendable (_ socketPath: String) -> String?)?
    private var optionQueries: [[String]] = []

    func effectiveOptions(executable: String, arguments: [String], environment: [String: String], timeout: Duration) async -> String? {
        lock.withLock { optionQueries.append([executable] + arguments) }
        let forward = arguments.firstIndex(of: "-L").map { arguments[$0 + 1] } ?? ""
        return options?(String(forward.prefix { $0 != ":" }))
    }

    var processes: [FakeProcess] { lock.withLock { launched } }
    var queries: [[String]] { lock.withLock { optionQueries } }
}

final class TunnelManagerTests: XCTestCase {
    private var runtime: RuntimeDirectory!
    private let clock = ManualClock()
    private let launcher = FakeLauncher()
    private let profile = UUID()
    private let configuration = SSHTunnelConfiguration(destination: "ops", user: "deploy", redisHost: "127.0.0.1", redisPort: 6379)

    override func setUpWithError() throws {
        runtime = try RuntimeDirectory.create(name: "keel-test-\(RuntimeDirectory.randomID())", owner: nil)
    }

    override func tearDown() { runtime.remove(); runtime = nil }

    private func manager(probe: @escaping @Sendable (String) -> Bool = { _ in true }) -> TunnelManager {
        let runtime = runtime!, clock = clock
        return TunnelManager(
            launcher: launcher, environment: ["HOME": "/Users/me", "SSH_AUTH_SOCK": "/agent", "SSH_ASKPASS": "/evil", "DISPLAY": ":0"], makeRuntime: { runtime }, probe: probe,
            sleep: { try await clock.sleep($0) })
    }

    /// Lets detached manager tasks (grace-period closes, exit watchers) run.
    private func eventually(_ message: String, _ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out: \(message)")
    }

    func testRefCountClosesAfterGracePeriod() async throws {
        let manager = manager()
        let first = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        let second = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 1, "One ssh per profile, shared by its connections")
        XCTAssertEqual(first.socketPath, second.socketPath)
        XCTAssertTrue(first.socketPath.hasPrefix(runtime.path + "/t-") && first.socketPath.hasSuffix(".sock"))
        let ssh = try XCTUnwrap(launcher.processes.first)
        XCTAssertEqual(ssh.arguments.first, "/usr/bin/ssh")
        XCTAssertEqual(ssh.environment["SSH_AUTH_SOCK"], "/agent", "The user's agent reaches ssh")
        XCTAssertNil(ssh.environment["SSH_ASKPASS"], "An inherited askpass program is never handed to ssh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.path + "/t-\(first.socketPath.dropFirst(runtime.path.count + 3).dropLast(5)).pid"), "Recorded for crash cleanup")

        await manager.release(first)
        await manager.release(first)
        let users = await manager.userCount(profileID: profile)
        XCTAssertEqual(users, 1, "A second release of the same lease is ignored")
        XCTAssertEqual(clock.pendingCount, 0, "No close while a lease is held")

        await manager.release(second)
        await eventually("grace period scheduled") { clock.pendingCount == 1 }
        XCTAssertEqual(clock.requested, [.seconds(10)])
        XCTAssertEqual(ssh.sentSignals, [], "Nothing is signalled before the grace period ends")

        // A new user inside the grace period keeps the same ssh; the old close is void.
        let third = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        clock.fire()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ssh.sentSignals, [])
        XCTAssertEqual(launcher.processes.count, 1)

        await manager.release(third)
        await eventually("second grace period scheduled") { clock.pendingCount == 1 }
        clock.fire()
        await eventually("ssh terminated") { ssh.sentSignals == [SIGTERM] }
        XCTAssertNotNil(ssh.exit)
        await eventually("tunnel files removed") { (try? FileManager.default.contentsOfDirectory(atPath: runtime.path).filter { $0.hasPrefix("t-") }) == [] }

        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 2, "After closing, the next connection starts a new ssh")
    }

    func testEscalatesToKillWhenTermIsIgnored() async throws {
        launcher.exitOnTerm = false
        let manager = manager()
        let lease = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        await manager.release(lease)
        await eventually("grace period scheduled") { clock.pendingCount == 1 }
        clock.fire()
        let ssh = try XCTUnwrap(launcher.processes.first)
        await eventually("SIGKILL after SIGTERM") { ssh.sentSignals == [SIGTERM, SIGKILL] }
    }

    func testNeverSignalsReusedPID() async throws {
        // The rule itself: a different start time, parent or group means another process.
        let identity = OwnedProcessIdentity(pid: 900, parentPID: 1, groupID: 900, startedSeconds: 10, startedMicroseconds: 5)
        XCTAssertTrue(identity.permitsSignal(current: identity, ownerPID: 1))
        XCTAssertFalse(identity.permitsSignal(current: OwnedProcessIdentity(pid: 900, parentPID: 1, groupID: 900, startedSeconds: 11, startedMicroseconds: 5), ownerPID: 1))
        XCTAssertFalse(identity.permitsSignal(current: nil, ownerPID: 1))
        XCTAssertFalse(identity.permitsSignal(current: identity, ownerPID: 2), "Not our child")
        let notLeader = OwnedProcessIdentity(pid: 900, parentPID: 1, groupID: 1, startedSeconds: 10, startedMicroseconds: 5)
        XCTAssertFalse(notLeader.permitsSignal(current: notLeader, ownerPID: 1), "Never signal a group we don't lead")

        // A reaped child is never signalled, even if the identity still reads the same.
        let sent = SignalLog()
        let group = OwnedProcessGroup(pid: 900, ownerPID: 1, readIdentity: { _ in identity }, sendSignal: { sent.append($1) })
        group.markReaped()
        XCTAssertFalse(group.signal(SIGTERM))
        XCTAssertEqual(sent.values, [])

        // Through the manager: the PID now belongs to another process when the grace period ends.
        let manager = manager()
        let lease = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        let ssh = try XCTUnwrap(launcher.processes.first)
        ssh.reusePID()
        await manager.release(lease)
        await eventually("grace period scheduled") { clock.pendingCount == 1 }
        clock.fire()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ssh.sentSignals, [], "A reused PID is never signalled")
    }

    func testReportsForwardFailure() async throws {
        let stderr = Data("Warning: Permanently added 'ops' (ED25519) to the list of known hosts.\r\nError: \u{1B}[31mlocal forwarding failed\u{1B}[0m\u{7} for /x.sock\r\n".utf8)
        launcher.onLaunch = { $0.finish(TunnelExit(status: .exited(255), stderr: stderr)) }
        let probing = Flag()
        let manager = manager(probe: { _ in probing.value })
        do {
            _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
            XCTFail("Expected TUNNEL_FAILED")
        } catch {
            XCTAssertEqual(error, .exited(TunnelExit(status: .exited(255), lastErrorLine: "Error: local forwarding failed for /x.sock")))
        }
        let users = await manager.userCount(profileID: profile)
        XCTAssertEqual(users, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.path).filter { $0.hasPrefix("t-") }, [], "No record left for a dead ssh")
        XCTAssertEqual(launcher.processes.first?.sentSignals, [], "An exited ssh is never signalled")

        launcher.onLaunch = nil; probing.value = true
        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 2, "A failed start leaves nothing behind; the next attempt starts again")
    }

    func testTimesOutAndTerminatesWhenSocketNeverAccepts() async throws {
        let manager = manager(probe: { _ in false })
        do {
            _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .milliseconds(200))
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error, .timeout(.milliseconds(200)))
        }
        XCTAssertEqual(launcher.processes.first?.sentSignals, [SIGTERM])
    }

    func testInvalidDestinationLaunchesNothing() async {
        let manager = manager()
        do {
            _ = try await manager.acquire(profileID: profile, configuration: .init(destination: "-oProxyCommand=id", redisHost: "127.0.0.1", redisPort: 6379), connectTimeout: .seconds(1))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error, .invalidArguments(.invalidDestination))
        }
        XCTAssertEqual(launcher.processes.count, 0)
    }

    /// INT-06: forwards from the user's ssh_config would open TCP ports and break a second profile through the same host.
    func testRefusesToLaunchWhenConfigAddsForwards() async throws {
        launcher.options = { "user deploy\nlocalforward \($0) [127.0.0.1]:6379\nlocalforward 6380 [localhost]:6379\n" }
        let manager = manager()
        do {
            _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error, .configuredForwards(["LocalForward 6380 [localhost]:6379"]))
        }
        XCTAssertEqual(launcher.processes.count, 0, "Nothing is launched")
        let query = try XCTUnwrap(launcher.queries.first)
        XCTAssertEqual(Array(query.prefix(2)), ["/usr/bin/ssh", "-G"])
        let tunnelArguments = try SSHTunnelArguments.arguments(for: configuration, socketPath: "/s.sock")
        XCTAssertEqual(query.count, tunnelArguments.count + 2, "-G checks exactly the arguments the launch uses")
        XCTAssertEqual(query.last, "ops")
        let users = await manager.userCount(profileID: profile)
        XCTAssertEqual(users, 0)

        launcher.options = { "user deploy\nlocalforward \($0) [127.0.0.1]:6379\n" }
        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 1, "Only Keel's own forward: ssh starts")
        launcher.options = { _ in nil }
        _ = try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 2, "Unreadable ssh -G output doesn't block the launch; ssh reports its own errors")
    }

    func testConcurrentAcquiresShareOneStart() async throws {
        let ready = Flag()
        let manager = manager(probe: { _ in ready.value })
        let profile = profile, configuration = configuration
        async let first = manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        async let second = manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(30))
        ready.value = true
        let leases = try await [first, second]
        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertEqual(Set(leases.map(\.socketPath)).count, 1)
        let users = await manager.userCount(profileID: profile)
        XCTAssertEqual(users, 2)
    }

    func testSSHExitingLaterStartsAFreshTunnel() async throws {
        let manager = manager()
        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        let ssh = try XCTUnwrap(launcher.processes.first)
        ssh.finish(TunnelExit(status: .exited(255), lastErrorLine: "Connection closed by remote host"))
        await eventually("dead tunnel forgotten") { await manager.userCount(profileID: self.profile) == 0 }
        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        XCTAssertEqual(launcher.processes.count, 2)
    }

    func testSSHDyingRightAfterReadyIsNeverReportedAsShutdown() async throws {
        // The probe kills ssh as it reports ready, so the exit watcher may forget the tunnel before acquire resumes.
        let launcher = launcher
        let manager = manager(probe: { _ in
            launcher.processes.last?.finish(TunnelExit(status: .exited(255), lastErrorLine: "Connection reset"))
            return true
        })
        do {
            _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        } catch {
            XCTAssertEqual(error, .exited(TunnelExit(status: .exited(255), lastErrorLine: "Connection reset")))
        }
    }

    func testShutdownTerminatesEverySSHAndRemovesRuntimeFolder() async throws {
        let manager = manager()
        _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
        _ = try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .seconds(10))
        await manager.shutdown()
        XCTAssertEqual(launcher.processes.map(\.sentSignals), [[SIGTERM], [SIGTERM]], "Quitting leaves no ssh behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        do {
            _ = try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(10))
            XCTFail("Expected shutDown")
        } catch {
            XCTAssertEqual(error, .shutDown)
        }
    }

    func testShutdownDuringStartTerminatesTheStartingSSH() async throws {
        let manager = manager(probe: { _ in false })
        let start = Task { [profile, configuration] in try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(30)) }
        await eventually("ssh launched") { !launcher.processes.isEmpty }
        await manager.shutdown()
        if case .failure(let error) = await start.result { XCTAssertEqual(error as? TunnelError, .shutDown) } else { XCTFail("Expected shutDown") }
        XCTAssertEqual(launcher.processes.first?.sentSignals, [SIGTERM])
    }
}

final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Int32] = []
    func append(_ signal: Int32) { lock.withLock { log.append(signal) } }
    var values: [Int32] { lock.withLock { log } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
