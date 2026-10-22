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
}
