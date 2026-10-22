import Foundation
import KeelCore
import KeelRESP
import XCTest

final class TLSErrorMappingTests: XCTestCase {
    private let endpoint = RedisEndpoint.tcp(host: "cache.internal", port: 6380)

    private func connecting(_ error: TransportError, _ tls: TLSConfiguration? = TLSConfiguration()) -> ConnectionFailure {
        ConnectionFailure(connecting: .connectionFailed(error), endpoint: endpoint, timeout: .seconds(10), tls: tls)
    }

    // MARK: - Story tests

    func testMapsTrustResultsToCategories() {
        let untrusted = connecting(.tlsRejected(.untrusted(issuer: "Keel Fixture CA", customCA: false)))
        XCTAssertEqual(untrusted.category, .tlsUntrusted)
        XCTAssertTrue(untrusted.message.contains("“Keel Fixture CA”"), untrusted.message)
        XCTAssertTrue(untrusted.suggestion.contains("custom CA"), untrusted.suggestion)
        let wrongCA = connecting(.tlsRejected(.untrusted(issuer: "Keel Fixture CA", customCA: true)))
        XCTAssertTrue(wrongCA.suggestion.contains("selected CA"), wrongCA.suggestion)

        let mismatch = connecting(.tlsRejected(.hostnameMismatch(expected: "10.0.0.5", certificateNames: ["redis.keel.test", "redis.internal"])))
        XCTAssertEqual(mismatch.category, .tlsHostnameMismatch)
        XCTAssertTrue(mismatch.message.contains("“10.0.0.5”") && mismatch.message.contains("“redis.keel.test”, “redis.internal”"), mismatch.message)
        XCTAssertTrue(mismatch.suggestion.contains("SNI") && mismatch.suggestion.contains("redis.keel.test"), mismatch.suggestion)
        XCTAssertEqual(connecting(.tlsRejected(.noServerName)).category, .tlsHostnameMismatch)

        let noIdentity = connecting(.tls(-9829))
        XCTAssertEqual(noIdentity.category, .tlsHandshakeFailed)
        XCTAssertTrue(noIdentity.message.contains("requires a client certificate"), noIdentity.message)
        XCTAssertEqual(connecting(.tls(-9863)).category, .tlsHandshakeFailed)
        XCTAssertTrue(connecting(.tls(-9824)).suggestion.contains("client certificate"))
        XCTAssertTrue(connecting(.tls(-9836)).suggestion.contains("TLS 1.2"))
        XCTAssertEqual(connecting(.tls(-9810)).category, .tlsHandshakeFailed)

        let plain = connecting(.plaintextServer)
        XCTAssertEqual(plain.category, .tlsHandshakeFailed)
        XCTAssertTrue(plain.message.hasPrefix("Server may not be using TLS"), plain.message)

        XCTAssertEqual(ConnectionErrorCategory.tlsUntrusted.rawValue, "TLS_UNTRUSTED")
        XCTAssertEqual(ConnectionErrorCategory.tlsHostnameMismatch.rawValue, "TLS_HOSTNAME_MISMATCH")
        XCTAssertEqual(ConnectionErrorCategory.tlsHandshakeFailed.rawValue, "TLS_HANDSHAKE_FAILED")
        XCTAssertEqual(ConnectionErrorCategory.notTLSExpected.rawValue, "NOT_TLS_EXPECTED")
    }

    // MARK: - Handshake-phase TLS failures

    func testClientCertificateWordingDependsOnIdentity() throws {
        let failure = ConnectionFailure(handshake: .connection(.connectionFailed(.tls(-9829)), step: .hello), endpoint: endpoint, options: HandshakeOptions(), tls: TLSConfiguration())
        XCTAssertEqual(failure.category, .tlsHandshakeFailed)
        XCTAssertTrue(failure.suggestion.contains("Choose a client certificate"), failure.suggestion)

        let identity = try XCTUnwrap(TLSFixturePaths.memoryIdentity())
        let rejected = connecting(.tls(-9831), TLSConfiguration(clientIdentity: TLSClientIdentity(identity)))
        XCTAssertTrue(rejected.message.contains("rejected the client certificate"), rejected.message)
    }

    func testTLSServerReachedWithoutTLS() {
        let alert = ConnectionFailure(handshake: .connection(.codec(.protocolError(.tlsRecord)), step: .hello), endpoint: endpoint, options: HandshakeOptions())
        XCTAssertEqual(alert.category, .notTLSExpected)
        XCTAssertTrue(alert.suggestion.contains("Turn on TLS"), alert.suggestion)
        // A server that just closes (Redis on a TLS port) stays CONNECTION_FAILED with the TLS hint (FR-CN10).
        let closed = ConnectionFailure(handshake: .connection(.connectionLost, step: .hello), endpoint: endpoint, options: HandshakeOptions())
        XCTAssertEqual(closed.category, .connectionFailed)
        XCTAssertTrue(closed.suggestion.contains("TLS"))
    }

    func testNonTLSErrorsKeepTheirCategories() {
        XCTAssertEqual(connecting(.posix(61)).category, .connectionRefused)
        XCTAssertEqual(connecting(.dns(-65554)).category, .dnsFailed)
        let timeout = ConnectionFailure(connecting: .timeout(.connect), endpoint: endpoint, timeout: .seconds(10), tls: TLSConfiguration())
        XCTAssertEqual(timeout.category, .timeout)
        XCTAssertTrue(timeout.message.contains("TCP and TLS"), timeout.message)
    }
}
