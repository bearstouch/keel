import Foundation
import KeelCore
import KeelRESP
import KeelSSH
import XCTest

/// KEEL-048's sshd container (NFR-QA03): an Alpine bastion with Redis on its own loopback, reached through a real
/// `/usr/bin/ssh -N` with a Unix-socket forward. The fixture's host key is pinned in its own known_hosts, so the
/// launcher puts `-F <fixture>/client_config` in front of Keel's arguments; the user's `~/.ssh` is never read.
final class TunnelMatrixTests: XCTestCase {
    private var fixture = "", sshPort: UInt16 = 0, redisPort: UInt16 = 0, user: String?

    override func setUpWithError() throws {
        _ = try IntegrationMatrix.current()
        fixture = try IntegrationMatrix.required("KEEL_INTEGRATION_SSH_FIXTURE")
        sshPort = try IntegrationMatrix.port("KEEL_INTEGRATION_SSH_PORT")
        redisPort = try IntegrationMatrix.port("KEEL_INTEGRATION_SSH_REDIS_PORT")
        // The container's login (`keel`); the hand-started serve.sh fixture runs as the current user, so none.
        user = ProcessInfo.processInfo.environment["KEEL_INTEGRATION_SSH_USER"]
    }

    private struct FixtureLauncher: TunnelProcessLauncher {
        let config: String
        func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess {
            try SSHProcessLauncher().launch(executable: executable, arguments: ["-F", config] + arguments, environment: environment)
        }
    }

    func testBrowseThroughSSH() async throws {
        let manager = TunnelManager(launcher: FixtureLauncher(config: fixture + "/client_config"))
        // Test Connection through the tunnel: the Redis host is the bastion's loopback, which only ssh can reach.
        let identityFile = fixture + "/client_key"
        let tunnel = TunnelSettings.inline(destination: IntegrationMatrix.host, user: user, port: Int(sshPort), identityFile: identityFile)
        let settings = ConnectionSettings(name: "bastion", host: "127.0.0.1", port: redisPort, tunnel: tunnel)
        let tested = try await ConnectionTester(tunnels: manager).test(settings, password: nil, profileID: nil).get()
        XCTAssertEqual(tested.identity.kind, .redis)

        // Browse and edit over a lease, as a connected profile does.
        let configuration = SSHTunnelConfiguration(
            destination: IntegrationMatrix.host, user: user, port: Int(sshPort), identityFile: identityFile, redisHost: "127.0.0.1", redisPort: redisPort)
        let lease = try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .seconds(10))
        let session = MatrixConnections.session(.unixSocket(path: lease.socketPath))
        let service = DataCommandService(session: session), context = DataContext(profile: MatrixConnections.profile)
        let prefix = MatrixConnections.prefix("ssh")
        let names = (0..<12).map { bytes("\(prefix)k:\($0)") }
        for name in names {
            let outcome = try await NewKey.create(name, .string(bytes("v")), service: service, context: context)
            XCTAssertEqual(outcome, .created)
        }
        let index = KeyIndex(service: service, context: context, configuration: KeyIndexConfiguration(pageSize: 5, filter: KeyFilter(pattern: prefix + "*")))
        let status = await index.autoPage()
        XCTAssertEqual(status.phase, .complete)
        let count = await index.count
        let listed = await index.keys(in: 0..<count)
        XCTAssertEqual(Set(listed), Set(names))
        let report = try await MatrixConnections.deleteAll(under: prefix, service)
        XCTAssertEqual(report.deleted, names.count)
        await session.closeAll()
        await manager.release(lease)
        await manager.shutdown()
    }
}
