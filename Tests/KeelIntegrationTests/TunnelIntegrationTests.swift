import Darwin
import Foundation
import KeelCore
import KeelRESP
import KeelSSH
import XCTest

/// KEEL-009 acceptance checks through a real `/usr/bin/ssh`. Needs `KEEL_INTEGRATION=1` and an sshd fixture (folder in
/// `KEEL_INTEGRATION_SSH_FIXTURE`): KEEL-048's sshd container from `scripts/integration-matrix.py` (ports in
/// `KEEL_INTEGRATION_SSH_PORT` / `KEEL_INTEGRATION_SSH_REDIS_PORT`), or by hand `Tests/Fixtures/SSH/serve.sh`, an
/// unprivileged sshd on 22422 with Redis behind it on 26399 (the defaults).
///
/// The fixture's host key is pinned in its own known_hosts, so the test launcher adds `-F <fixture>/client_config`
/// in front of Keel's arguments; the user's `~/.ssh` is never read or written. Keel itself never adds options.
final class TunnelIntegrationTests: XCTestCase {
    private var fixture = "", sshPort = 22_422, redisPort: UInt16 = 26_399

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1")
        fixture = try XCTUnwrap(environment["KEEL_INTEGRATION_SSH_FIXTURE"], "run scripts/integration-matrix.py, or start Tests/Fixtures/SSH/serve.sh and pass its folder")
        sshPort = Int(environment["KEEL_INTEGRATION_SSH_PORT"] ?? "") ?? sshPort
        redisPort = UInt16(environment["KEEL_INTEGRATION_SSH_REDIS_PORT"] ?? "") ?? redisPort
    }

    private final class FixtureLauncher: TunnelProcessLauncher, @unchecked Sendable {
        let config: String
        private let lock = NSLock()
        private var launched: [any TunnelProcess] = []
        init(config: String) { self.config = config }
        func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess {
            let process = try SSHProcessLauncher().launch(executable: executable, arguments: ["-F", config] + arguments, environment: environment)
            lock.withLock { launched.append(process) }
            return process
        }
        var processes: [any TunnelProcess] { lock.withLock { launched } }
    }

    private func configuration(identity: String = "client_key") -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(destination: "127.0.0.1", port: sshPort, identityFile: fixture + "/" + identity, redisHost: "127.0.0.1", redisPort: redisPort)
    }

    private func gone(_ pid: Int32, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// AC1 + AC5: Redis on the bastion's loopback is reached through the socket; ssh listens on no TCP port.
    func testReachesRedisBehindBastionThroughUnixSocket() async throws {
        let launcher = FixtureLauncher(config: fixture + "/client_config")
        let manager = TunnelManager(launcher: launcher)
        let lease = try await manager.acquire(profileID: UUID(), configuration: configuration(), connectTimeout: .seconds(10))
        let connection = RedisConnection(endpoint: .unixSocket(path: lease.socketPath))
        try await connection.connect()
        _ = try await connection.handshake(HandshakeOptions())
        let pong = try await connection.send([Data("PING".utf8)], mayWrite: false)
        XCTAssertEqual(pong, .simpleString(Data("PONG".utf8)))
        _ = try await connection.send([Data("SET".utf8), Data("keel:tunnel".utf8), Data("ok".utf8)], mayWrite: true)
        let scan = try await connection.send([Data("SCAN".utf8), Data("0".utf8), Data("MATCH".utf8), Data("keel:*".utf8)], mayWrite: false)
        guard case .array(let page) = scan, page.count == 2, case .array(let keys) = page[1] else { return XCTFail("Unexpected SCAN reply \(scan)") }
        XCTAssertTrue(keys.contains(.bulkString(Data("keel:tunnel".utf8))), "Browsing (SCAN) works through the tunnel")
        await connection.close()

        let pid = try XCTUnwrap(launcher.processes.first?.group.pid)
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"]
        let output = Pipe()
        lsof.standardOutput = output; lsof.standardError = FileHandle.nullDevice
        try lsof.run(); lsof.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "", "AC5: no local TCP port is opened")
        await manager.shutdown()
    }

    /// AC3: the last release terminates ssh within 11 s; shutdown (quit) leaves no ssh child.
    func testClosesAfterLastReleaseAndOnShutdown() async throws {
        let launcher = FixtureLauncher(config: fixture + "/client_config")
        let manager = TunnelManager(launcher: launcher)
        let lease = try await manager.acquire(profileID: UUID(), configuration: configuration(), connectTimeout: .seconds(10))
        let pid = try XCTUnwrap(launcher.processes.first?.group.pid)
        let released = Date()
        await manager.release(lease)
        let closed = await gone(pid, within: 11)
        XCTAssertTrue(closed, "ssh terminated within 11 s of the last release")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(released), 9.5, "…and not before the grace period")

        _ = try await manager.acquire(profileID: UUID(), configuration: configuration(), connectTimeout: .seconds(10))
        let second = try XCTUnwrap(launcher.processes.last?.group.pid)
        await manager.shutdown()
        let quit = await gone(second, within: 2)
        XCTAssertTrue(quit, "No ssh -N outlives shutdown")
    }

    /// AC4: ssh failing (here: the key isn't authorized) is TUNNEL_FAILED with its exit status and last stderr line.
    func testFailureReportsExitStatusAndStderr() async throws {
        let manager = TunnelManager(launcher: FixtureLauncher(config: fixture + "/client_config"))
        do {
            _ = try await manager.acquire(profileID: UUID(), configuration: configuration(identity: "host_key"), connectTimeout: .seconds(10))
            XCTFail("Expected TUNNEL_FAILED")
        } catch {
            let failure = ConnectionFailure(tunnel: error, destination: "127.0.0.1")
            XCTAssertEqual(failure.category, .tunnelFailed)
            XCTAssertEqual(failure.tunnelExit?.status, .exited(255))
            XCTAssertTrue(failure.message.contains("Permission denied"), failure.message)
        }
        await manager.shutdown()
    }
}
