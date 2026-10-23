import XCTest
@testable import KeelSSH

final class SSHTunnelArgumentsTests: XCTestCase {
    private let socket = "/var/folders/xy/T/keel-run-0123456789ab/t-a1b2c3d4e5f6.sock"

    func testBuildsArgumentArrayWithoutShell() throws {
        let configuration = SSHTunnelConfiguration(destination: "ops", user: "deploy", port: 2222, identityFile: "/Users/me/.ssh/id ed25519", redisHost: "127.0.0.1", redisPort: 6379)
        XCTAssertEqual(
            try SSHTunnelArguments.arguments(for: configuration, socketPath: socket),
            [
                "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "StreamLocalBindUnlink=yes",
                "-L", "\(socket):127.0.0.1:6379", "-p", "2222", "-l", "deploy", "-i", "/Users/me/.ssh/id ed25519", "--", "ops"
            ], "One argv element per value: the space in the identity path is never split by a shell")
        XCTAssertEqual(SSHTunnelArguments.executable, "/usr/bin/ssh")

        let minimal = try SSHTunnelArguments.arguments(for: SSHTunnelConfiguration(destination: "bastion.example.com", redisHost: "redis.internal", redisPort: 6380), socketPath: socket)
        XCTAssertEqual(minimal.suffix(4), ["-L", "\(socket):redis.internal:6380", "--", "bastion.example.com"])
        XCTAssertFalse(minimal.contains("-p") || minimal.contains("-l") || minimal.contains("-i"))
    }

    func testForwardIsAlwaysAUnixSocket() throws {
        let arguments = try SSHTunnelArguments.arguments(for: SSHTunnelConfiguration(destination: "ops", redisHost: "::1", redisPort: 6379), socketPath: socket)
        let forward = try XCTUnwrap(arguments.firstIndex(of: "-L").map { arguments[$0 + 1] })
        XCTAssertEqual(forward, "\(socket):[::1]:6379", "IPv6 Redis hosts are bracketed so ssh splits the spec correctly")
        XCTAssertTrue(forward.hasPrefix("/"), "The local side is a socket path, never a TCP port (AC5)")
        XCTAssertEqual(arguments.filter { $0 == "-L" }.count, 1)
        XCTAssertFalse(arguments.contains("-D") || arguments.contains("-R") || arguments.contains("-g"))
    }

    func testRejectsOptionInjectionDestinations() {
        for destination in ["-oProxyCommand=sh -c 'touch /tmp/pwned'", "-oProxyCommand=nc %h %p", "-F/dev/null", "-", "", "ops host", "ops\nProxyCommand x", "ops;id", "$(id)", "ops`id`"] {
            XCTAssertThrowsError(try SSHTunnelArguments.arguments(for: SSHTunnelConfiguration(destination: destination, redisHost: "127.0.0.1", redisPort: 6379), socketPath: socket)) {
                XCTAssertEqual($0 as? SSHTunnelArgumentError, .invalidDestination, destination)
            }
        }
        for destination in ["ops", "deploy@bastion", "10.0.0.5", "[fe80::1%en0]", "my_host.example-1.com"] {
            XCTAssertNoThrow(try SSHTunnelArguments.arguments(for: SSHTunnelConfiguration(destination: destination, redisHost: "127.0.0.1", redisPort: 6379), socketPath: socket), destination)
        }
    }

    func testRejectsInjectionInOtherFields() {
        func error(_ configuration: SSHTunnelConfiguration) -> SSHTunnelArgumentError? {
            do { _ = try SSHTunnelArguments.arguments(for: configuration, socketPath: socket); return nil } catch { return error }
        }
        XCTAssertEqual(error(.init(destination: "ops", user: "-oProxyCommand=x", redisHost: "127.0.0.1", redisPort: 1)), .invalidUser)
        XCTAssertEqual(error(.init(destination: "ops", user: "de ploy", redisHost: "127.0.0.1", redisPort: 1)), .invalidUser)
        XCTAssertEqual(error(.init(destination: "ops", identityFile: "-oProxyCommand=x", redisHost: "127.0.0.1", redisPort: 1)), .invalidIdentityFile)
        XCTAssertEqual(error(.init(destination: "ops", identityFile: "/k\n", redisHost: "127.0.0.1", redisPort: 1)), .invalidIdentityFile)
        XCTAssertEqual(error(.init(destination: "ops", port: 0, redisHost: "127.0.0.1", redisPort: 1)), .invalidPort)
        XCTAssertEqual(error(.init(destination: "ops", port: 70_000, redisHost: "127.0.0.1", redisPort: 1)), .invalidPort)
        XCTAssertEqual(error(.init(destination: "ops", redisHost: "127.0.0.1", redisPort: 0)), .invalidRedisPort)
        for host in ["", "-x", "host:6379", "a b", "/tmp/sock", "[host]", "h\u{0}"] {
            XCTAssertEqual(error(.init(destination: "ops", redisHost: host, redisPort: 6379)), .invalidRedisHost, host)
        }
    }

    func testNeverEmitsTrustBypassOptions() throws {
        let configuration = SSHTunnelConfiguration(destination: "ops", user: "u", port: 22, identityFile: "/k", redisHost: "localhost", redisPort: 6379)
        let arguments = try SSHTunnelArguments.arguments(for: configuration, socketPath: socket)
        for option in SSHTunnelArguments.forbiddenOptions {
            XCTAssertFalse(arguments.contains { $0.localizedCaseInsensitiveContains(option) }, option)
        }
        XCTAssertEqual(arguments.enumerated().filter { $0.element == "-o" }.map { arguments[$0.offset + 1] }, ["ExitOnForwardFailure=yes", "ServerAliveInterval=30", "StreamLocalBindUnlink=yes"])
    }

    func testSavedHostFieldsCarryOver() throws {
        let draft = try HostDraft(name: "Ops", destination: "ops.example.com", user: "deploy", port: "2200", identityFile: "/k").validated { _ in true }
        let configuration = SSHTunnelConfiguration(host: SavedHost(id: UUID(), draft: draft, revision: 1), redisHost: "127.0.0.1", redisPort: 6379)
        XCTAssertEqual(configuration, SSHTunnelConfiguration(destination: "ops.example.com", user: "deploy", port: 2200, identityFile: "/k", redisHost: "127.0.0.1", redisPort: 6379))
    }
}
