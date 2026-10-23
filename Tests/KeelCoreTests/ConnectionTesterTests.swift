import Foundation
import KeelRESP
import KeelSSH
import XCTest

@testable import KeelCore

final class ConnectionTesterTests: XCTestCase {
    private static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }

    /// A Redis 7.4 server that answers the handshake, PING and INFO; `override` replaces any answer.
    private static func server(_ override: @escaping @Sendable ([String]) -> String? = { _ in nil }) -> @Sendable ([String]) -> String {
        { words in
            if let answer = override(words) { return answer }
            switch words.first?.uppercased() {
            case "HELLO": return "%1\r\n+server\r\n+redis\r\n"
            case "PING": return "+PONG\r\n"
            case "INFO" where words.last == "server": return bulk("# Server\r\nredis_version:7.4.1\r\nredis_mode:standalone\r\n")
            case "INFO": return bulk("# Replication\r\nrole:master\r\n")
            default: return "+OK\r\n"
            }
        }
    }

    /// A tester whose connections run over `RecordingTransport`s, which it collects.
    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [(RedisEndpoint, TLSConfiguration?, RecordingTransport)] = []
        var all: [(endpoint: RedisEndpoint, tls: TLSConfiguration?, transport: RecordingTransport)] { lock.withLock { made.map { ($0.0, $0.1, $0.2) } } }

        func tester(answer: @escaping @Sendable ([String]) -> String, readCAFile: @escaping @Sendable (String) throws(KnownCAError) -> Data = { path throws(KnownCAError) in throw .missing(path: path) })
            -> ConnectionTester
        {
            ConnectionTester(
                clientIdentity: { _ in nil }, readCAFile: readCAFile,
                makeConnection: { endpoint, tls, options in
                    let transport = RecordingTransport(answer: answer)
                    self.lock.withLock { self.made.append((endpoint, tls, transport)) }
                    return RedisConnection(transport: transport, options: options)
                })
        }
    }

    private func waitUntilClosed(_ transport: RecordingTransport) async {
        // The close runs in a deferred task; poll briefly for it.
        for _ in 0..<200 {
            if transport.isClosed { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The test connection was never closed")
    }

    func testSuccessReportsServerModeAndLatencyAndCloses() async throws {
        let connections = Connections()
        let result = await connections.tester(answer: Self.server()).test(ConnectionSettings(name: "local"), password: nil, profileID: nil)
        let found = try result.get()
        XCTAssertEqual(found.identity.kind, .redis)
        XCTAssertEqual(found.identity.mode, .standalone)
        XCTAssertTrue(found.summary.hasPrefix("✓ Connected · Redis 7.4.1 · standalone · "), found.summary)
        XCTAssertTrue(found.summary.hasSuffix(" ms"), found.summary)
        let transport = try XCTUnwrap(connections.all.first?.transport)
        XCTAssertEqual(transport.commands.map { $0.prefix(2).joined(separator: " ") }, ["HELLO 3", "PING", "INFO server", "INFO replication"])
        await waitUntilClosed(transport)
    }

    func testAuthFailureIsCategorizedWithoutThePassword() async {
        let connections = Connections()
        let tester = connections.tester(answer: Self.server { $0.first == "HELLO" ? "-WRONGPASS invalid username-password pair or user is disabled.\r\n" : nil })
        let result = await tester.test(ConnectionSettings(name: "x", username: "app"), password: Data("s3cret-pw".utf8), profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure.category, .authFailed)
        XCTAssertTrue(failure.message.contains("app"))
        XCTAssertFalse(failure.message.contains("s3cret-pw"))
        XCTAssertFalse(connections.all[0].transport.commands.contains { $0.first == "PING" }, "Nothing is sent after a failed handshake")
    }

    func testNoPermOnInfoIsPermissionDenied() async {
        let tester = Connections().tester(answer: Self.server { $0 == ["INFO", "server"] ? "-NOPERM this user has no permissions to run the 'info' command\r\n" : nil })
        let result = await tester.test(ConnectionSettings(name: "x"), password: nil, profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure.category, .permissionDenied)
        XCTAssertTrue(failure.message.contains("INFO server"), failure.message)
    }

    func testOldRedisIsUnsupported() async {
        let tester = Connections().tester(answer: Self.server { $0 == ["INFO", "server"] ? Self.bulk("redis_version:5.0.7\r\n") : nil })
        let result = await tester.test(ConnectionSettings(name: "x"), password: nil, profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure.category, .unsupportedServer)
    }

    /// A missing CA file fails before any socket is opened, and nothing is recorded anywhere.
    func testUnreadableCAFileOpensNothing() async {
        let connections = Connections()
        let settings = ConnectionSettings(name: "x", tls: TLSSettings(caFile: "/nowhere/ca.pem"))
        let result = await connections.tester(answer: Self.server()).test(settings, password: nil, profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure.category, .tlsCAUnavailable)
        XCTAssertTrue(connections.all.isEmpty)
    }

    func testMissingSavedSSHHostOpensNothing() async {
        let connections = Connections()
        let settings = ConnectionSettings(name: "x", tunnel: .savedHost(id: UUID()))
        let result = await connections.tester(answer: Self.server()).test(settings, password: nil, profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(failure.category, .tunnelFailed)
        XCTAssertTrue(connections.all.isEmpty)
    }

    /// FR-CN06: a saved host's password lookup reaches the tunnel launch; an inline destination never gets one.
    func testSavedHostTunnelCarriesItsPasswordLookup() async throws {
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Bastion", destination: "bastion").validated(isRegularFile: { _ in true }), revision: 1)
        let secret = Data("s3cret".utf8)
        let tester = ConnectionTester(resolveSavedHost: { $0 == host.id ? host : nil }, savedHostPassword: { saved in saved.id == host.id ? { @Sendable in secret } : nil })
        let settings = ConnectionSettings(name: "x", tunnel: .savedHost(id: host.id))
        let resolved = try await tester.resolve(.savedHost(id: host.id), settings: settings)
        XCTAssertEqual(resolved.destination, "bastion")
        let lookup = try XCTUnwrap(resolved.savedPassword)
        let value = await lookup()
        XCTAssertEqual(value, secret)
        let inline = try await tester.resolve(.inline(destination: "bastion", user: nil, port: nil, identityFile: nil), settings: settings)
        XCTAssertNil(inline.savedPassword)
    }

    func testSubMillisecondRoundTripReadsLessThanOne() {
        XCTAssertEqual(ConnectionTestResult.milliseconds(.microseconds(300)), "<1 ms")
        XCTAssertEqual(ConnectionTestResult.milliseconds(.milliseconds(42)), "42 ms")
        let unverified = ConnectionTestResult(
            identity: ServerIdentity(kind: .valkey, version: ServerVersion("8.1.1"), redisCompatibleVersion: nil, mode: .replica, role: "slave"), roundTrip: .milliseconds(3),
            tlsVerified: false)
        XCTAssertEqual(unverified.summary, "✓ Connected · Valkey 8.1.1 · replica · 3 ms · TLS not verified")
    }
}
