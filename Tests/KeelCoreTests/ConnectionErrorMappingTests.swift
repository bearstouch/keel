import Darwin
import Foundation
import KeelCore
import KeelRESP
import XCTest

final class ConnectionErrorMappingTests: XCTestCase {
    private let endpoint = RedisEndpoint.tcp(host: "cache.internal", port: 6379)
    private let alice = HandshakeOptions(username: "alice", password: "s3cret", database: 20)

    private func failure(_ error: HandshakeError, _ options: HandshakeOptions? = nil) -> ConnectionFailure {
        ConnectionFailure(handshake: error, endpoint: endpoint, options: options ?? alice)
    }

    // MARK: - Story tests

    func testMapsServerErrorsToCategories() {
        let wrongPass = failure(.rejected(step: .hello, serverError: "WRONGPASS invalid username-password pair or user is disabled."))
        XCTAssertEqual(wrongPass.category, .authFailed)
        XCTAssertTrue(wrongPass.message.contains("“alice”"), wrongPass.message)

        let noAuth = failure(.rejected(step: .hello, serverError: "NOAUTH HELLO must be called with the client already authenticated"), HandshakeOptions())
        XCTAssertEqual(noAuth.category, .authFailed)
        XCTAssertTrue(noAuth.message.contains("requires a password"), noAuth.message)

        let noPerm = failure(.rejected(step: .select, serverError: "NOPERM User alice has no permissions to run the 'select' command"))
        XCTAssertEqual(noPerm.category, .permissionDenied)
        XCTAssertTrue(noPerm.message.contains("SELECT") && noPerm.message.contains("alice"), noPerm.message)

        let outOfRange = failure(.databaseOutOfRange(index: 20, count: 16))
        XCTAssertEqual(outOfRange.category, .databaseOutOfRange)
        XCTAssertTrue(outOfRange.message.contains("20") && outOfRange.message.contains("16 databases"), outOfRange.message)
        XCTAssertEqual(failure(.databaseOutOfRange(index: 20, count: nil)).category, .databaseOutOfRange)

        XCTAssertEqual(failure(.rejected(step: .auth, serverError: "ERR invalid password")).category, .authFailed)
        XCTAssertEqual(failure(.rejected(step: .auth, serverError: "ERR AUTH <password> called without any password configured for the default user.")).category, .authFailed)
        XCTAssertEqual(failure(.rejected(step: .setName, serverError: "ERR Syntax error")).category, .serverError)
    }

    func testMessagesNeverContainPassword() {
        // Server text that echoes the password, a username containing it, and every category in between.
        let errors: [HandshakeError] = [
            .rejected(step: .hello, serverError: "WRONGPASS invalid username-password pair or user is disabled."),
            .rejected(step: .auth, serverError: "ERR unknown command 'AUTH', with args beginning with: 's3cret'"),
            .rejected(step: .auth, serverError: "ERR something about s3cret"),
            .rejected(step: .select, serverError: "NOPERM no select for s3cret"),
            .connection(.timeout(.auth), step: .auth), .connection(.codec(.protocolError(.unknownType)), step: .hello),
            .connection(.connectionLost, step: .hello), .databaseOutOfRange(index: 20, count: 16)
        ]
        for options in [alice, HandshakeOptions(username: "s3cret-admin", password: "s3cret")] {
            for error in errors {
                let failure = failure(error, options)
                for text in [failure.message, failure.suggestion, failure.serverError ?? "", failure.description] {
                    XCTAssertFalse(text.contains("s3cret"), "\(failure.category): \(text)")
                }
            }
        }
    }

    // MARK: - Connect and transport failures

    func testMapsConnectFailures() {
        func connecting(_ error: RedisError) -> ConnectionFailure { ConnectionFailure(connecting: error, endpoint: endpoint, timeout: .seconds(10)) }
        let dns = connecting(.connectionFailed(.dns(-65554)))
        XCTAssertEqual(dns.category, .dnsFailed)
        XCTAssertTrue(dns.message.contains("cache.internal"))
        let refused = connecting(.connectionFailed(.posix(ECONNREFUSED)))
        XCTAssertEqual(refused.category, .connectionRefused)
        XCTAssertTrue(refused.message.contains("cache.internal:6379"))
        let timeout = connecting(.timeout(.connect))
        XCTAssertEqual(timeout.category, .timeout)
        XCTAssertEqual(timeout.phase, .connect)
        XCTAssertTrue(timeout.message.contains("10 s") && timeout.message.contains("TCP"), timeout.message)
        XCTAssertEqual(connecting(.connectionFailed(.other)).category, .connectionFailed)
    }

    func testMapsHandshakeTransportFailures() {
        let http = failure(.connection(.codec(.protocolError(.unknownType)), step: .hello))
        XCTAssertEqual(http.category, .protocolError)
        XCTAssertEqual(http.message, "This port doesn't look like a Redis server.")
        let timeout = failure(.connection(.timeout(.auth), step: .hello), HandshakeOptions(timeout: .milliseconds(1_500)))
        XCTAssertEqual(timeout.category, .timeout)
        XCTAssertEqual(timeout.phase, .auth)
        XCTAssertTrue(timeout.message.contains("HELLO") && timeout.message.contains("1500 ms") && timeout.message.contains("AUTH"), timeout.message)
        XCTAssertEqual(failure(.connection(.connectionLost, step: .hello)).category, .connectionFailed)
    }
}
