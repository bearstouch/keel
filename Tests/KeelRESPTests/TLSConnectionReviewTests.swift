import Foundation
import XCTest
@testable import KeelRESP

/// A `FakeTransport` that claims to be TLS and answers the plain-text probe as told.
private final class TLSFakeTransport: Transport, @unchecked Sendable {
    let inner: FakeTransport
    let plainAnswer: Bool
    private let lock = NSLock()
    private var probes = 0

    init(_ inner: FakeTransport, plainAnswer: Bool) { self.inner = inner; self.plainAnswer = plainAnswer }

    var probeCount: Int { lock.withLock { probes } }
    var tlsVerified: Bool? { true }
    func answersPlainRESP() async -> Bool { lock.withLock { probes += 1 }; return plainAnswer }
    func connect() async throws(TransportError) { try await inner.connect() }
    func send(_ data: Data) { inner.send(data) }
    func receive() async throws(TransportError) -> Data { try await inner.receive() }
    func cancel() { inner.cancel() }
}

final class TLSConnectionReviewTests: XCTestCase {
    private func connectError(_ transport: any Transport, sleeper: ManualSleeper = ManualSleeper()) async -> RedisError? {
        let connection = RedisConnection(transport: transport, sleep: { try await sleeper.sleep($0) })
        do throws(RedisError) { try await connection.connect(); return nil } catch { return error }
    }

    func testHandshakeFailureAgainstPlainServerReportsPlaintext() async {
        let transport = TLSFakeTransport(FakeTransport(connectFailure: .tls(-9800)), plainAnswer: true)
        let error = await connectError(transport)
        XCTAssertEqual(error, .connectionFailed(.plaintextServer))
    }

    func testTimeoutAgainstPlainServerReportsPlaintext() async {
        // A Redis server reads a ClientHello as an unfinished inline command, so TLS never completes.
        let sleeper = ManualSleeper()
        let transport = TLSFakeTransport(FakeTransport(holdConnect: true), plainAnswer: true)
        let connection = RedisConnection(transport: transport, sleep: { try await sleeper.sleep($0) })
        let attempt = Task { () -> RedisError? in
            do throws(RedisError) { try await connection.connect(); return nil } catch { return error }
        }
        let waiting = await eventually { sleeper.count(.seconds(10)) == 1 }
        XCTAssertTrue(waiting)
        sleeper.fire(.seconds(10))
        let error = await attempt.value
        XCTAssertEqual(error, .connectionFailed(.plaintextServer))
        let state = await connection.state
        XCTAssertEqual(state, .failed(.connectionFailed(.plaintextServer)))
    }

    func testPreciseFailuresAreNotProbed() async {
        for failure in [TransportError.tlsRejected(.noServerName), .posix(61), .dns(-65554)] {
            let transport = TLSFakeTransport(FakeTransport(connectFailure: failure), plainAnswer: true)
            let error = await connectError(transport)
            XCTAssertEqual(error, .connectionFailed(failure))
            XCTAssertEqual(transport.probeCount, 0, "\(failure)")
        }
        // A TLS failure from a server that doesn't answer plain RESP keeps its status.
        let silent = TLSFakeTransport(FakeTransport(connectFailure: .tls(-9806)), plainAnswer: false)
        let silentError = await connectError(silent)
        XCTAssertEqual(silentError, .connectionFailed(.tls(-9806)))
        // Plain connections are never probed.
        let plain = await connectError(FakeTransport(connectFailure: .tls(-9800)))
        XCTAssertEqual(plain, .connectionFailed(.tls(-9800)))
    }

    func testClientCertificateRefusedAfterConnectReachesHandshake() async throws {
        // TLS 1.3: the server checks the client certificate after the client's handshake, ending the stream at HELLO.
        let transport = FakeTransport(onSend: { transport, _ in transport.drop(.tls(-9829)) })
        let connection = RedisConnection(transport: transport, sleep: { try await ManualSleeper().sleep($0) })
        try await connection.connect()
        do throws(HandshakeError) {
            _ = try await connection.handshake(HandshakeOptions())
            XCTFail("handshake succeeded")
        } catch {
            XCTAssertEqual(error, .connection(.connectionFailed(.tls(-9829)), step: .hello))
        }
    }

    func testTLSRecordWhereReplyExpectedIsFlagged() {
        var parser = RESPParser()
        parser.append(Data([0x15, 0x03, 0x01, 0x00, 0x02, 0x02, 0x46]))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? RESPError, .protocolError(.tlsRecord)) }
        XCTAssertEqual(RESPError.protocolError(.tlsRecord).code, "PROTOCOL_ERROR")
    }

    /// Profiles accept `[::1]` as typed; Network would look the bracketed text up as a DNS name.
    func testBracketedIPv6HostConnectsToTheAddress() {
        for host in ["[::1]", "::1", "[fe80::1%lo0]"] {
            guard case .hostPort(let resolved, let port) = NetworkTransport.nwEndpoint(.tcp(host: host, port: 6379)), case .ipv6 = resolved else { return XCTFail(host) }
            XCTAssertEqual(port, 6379)
        }
        guard case .hostPort(.name("cache.internal", _), _) = NetworkTransport.nwEndpoint(.tcp(host: "cache.internal", port: 6379)) else { return XCTFail("name") }
        XCTAssertEqual(RedisEndpoint.bareHost("[::1]"), "::1")
        for unchanged in ["[cache]", "[]", "10.0.0.5", "cache.internal", "[::1"] { XCTAssertEqual(RedisEndpoint.bareHost(unchanged), unchanged) }
    }

    /// A bracketed IPv6 host is matched against the certificate's IP names, and never sent as SNI (RFC 6066).
    func testBracketedIPv6HostMatchesIPSubjectAltName() throws {
        let anchor = TLSConfiguration(anchorCertificates: try TLSFixtures.ders("self-signed.pem"))
        for endpoint in [RedisEndpoint.tcp(host: "[::1]", port: 6380), .tcp(host: "::1", port: 6380)] {
            let name = anchor.expectedName(for: endpoint)
            XCTAssertEqual(name, "::1")
            XCTAssertNil(anchor.protocolSettings(for: endpoint).sniName)
            XCTAssertNil(anchor.evaluate(try TLSFixtures.trust("self-signed.pem"), serverName: name, at: TLSFixtures.date), "IP SAN ::1 matches")
        }
        // Through a tunnel the default name is the profile's host as typed (KeelCore passes it as the override).
        let tunnelled = TLSConfiguration(serverName: "[::1]", anchorCertificates: anchor.anchorCertificates)
        XCTAssertEqual(tunnelled.expectedName(for: .unixSocket(path: "/tmp/t.sock")), "::1")
        XCTAssertNil(tunnelled.protocolSettings(for: .unixSocket(path: "/tmp/t.sock")).sniName)
        let other = anchor.expectedName(for: .tcp(host: "[::2]", port: 6380))
        XCTAssertEqual(other, "::2")
        XCTAssertEqual(anchor.evaluate(try TLSFixtures.trust("self-signed.pem"), serverName: other, at: TLSFixtures.date)?.isHostnameMismatch, true, "Another address doesn't match")
    }
}

extension TLSTrustFailure {
    fileprivate var isHostnameMismatch: Bool { if case .hostnameMismatch = self { true } else { false } }
}
