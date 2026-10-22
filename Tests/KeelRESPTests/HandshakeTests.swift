import Foundation
import XCTest
@testable import KeelRESP

final class HandshakeTests: XCTestCase {
    /// A fake server answering each command from `answer`; nil leaves the command unanswered.
    private func connected(_ answer: @escaping @Sendable ([String]) -> String?, sleeper: ManualSleeper = ManualSleeper()) async throws -> (RedisConnection, FakeTransport) {
        let transport = FakeTransport(onSend: { transport, _ in
            if let command = transport.commands.last, let reply = answer(command) { transport.reply(reply) }
        })
        let connection = RedisConnection(transport: transport, sleep: { try await sleeper.sleep($0) })
        try await connection.connect()
        return (connection, transport)
    }

    private static func handshakeError(_ connection: RedisConnection, _ options: HandshakeOptions) async -> HandshakeError? {
        do throws(HandshakeError) { _ = try await connection.handshake(options); return nil } catch { return error }
    }

    /// A Redis 7 server: HELLO answers with a RESP3 map, everything else with +OK.
    private static func redis7(_ command: [String]) -> String {
        command[0] == "HELLO" ? "%2\r\n+server\r\n+redis\r\n+proto\r\n:3\r\n" : "+OK\r\n"
    }

    /// Redis 6.2+ phrasing of an unknown command, which echoes the arguments, password included.
    private static func unknownCommand(_ command: [String]) -> String {
        "-ERR unknown command '\(command[0])', with args beginning with: \(command.dropFirst().map { "'\($0)'" }.joined(separator: " "))\r\n"
    }

    /// A server without HELLO.
    private static func noHello(_ command: [String]) -> String { command[0] == "HELLO" ? unknownCommand(command) : "+OK\r\n" }

    // MARK: - Story tests

    func testUsesHelloWhenAvailable() async throws {
        let (connection, transport) = try await connected(Self.redis7)
        let result = try await connection.handshake(HandshakeOptions(username: "alice", password: "s3cret", database: 2))
        XCTAssertEqual(transport.commands, [["HELLO", "3", "AUTH", "alice", "s3cret", "SETNAME", "keel"], ["SELECT", "2"]])
        XCTAssertEqual(result.protocolVersion, 3)
        XCTAssertEqual(result.hello, .map([RESPPair(.simpleString(bytes("server")), .simpleString(bytes("redis"))), RESPPair(.simpleString(bytes("proto")), .integer(3))]))
    }

    func testFallsBackToAuthWhenHelloUnknown() async throws {
        let (connection, transport) = try await connected(Self.noHello)
        let result = try await connection.handshake(HandshakeOptions(username: "alice", password: "s3cret", database: 1))
        XCTAssertEqual(
            transport.commands,
            [["HELLO", "3", "AUTH", "alice", "s3cret", "SETNAME", "keel"], ["AUTH", "alice", "s3cret"], ["CLIENT", "SETNAME", "keel"], ["SELECT", "1"]])
        XCTAssertEqual(result, HandshakeResult(protocolVersion: 2, hello: nil))

        // `requirepass` / the default user: HELLO names `default`, the fallback is one-argument AUTH.
        let (other, otherTransport) = try await connected(Self.noHello)
        _ = try await other.handshake(HandshakeOptions(password: "s3cret"))
        XCTAssertEqual(otherTransport.commands, [["HELLO", "3", "AUTH", "default", "s3cret", "SETNAME", "keel"], ["AUTH", "s3cret"], ["CLIENT", "SETNAME", "keel"]])
    }

    func testSetNameCanBeDisabled() async throws {
        let (connection, transport) = try await connected(Self.redis7)
        _ = try await connection.handshake(HandshakeOptions(password: "s3cret", setName: false))
        XCTAssertEqual(transport.commands, [["HELLO", "3", "AUTH", "default", "s3cret"]])

        let (legacy, legacyTransport) = try await connected(Self.noHello)
        _ = try await legacy.handshake(HandshakeOptions(setName: false))
        XCTAssertEqual(legacyTransport.commands, [["HELLO", "3"]])
        XCTAssertFalse(legacyTransport.commands.contains { $0.contains("SETNAME") })
    }

    // MARK: - Failures

    func testWrongPasswordStopsAtHello() async throws {
        let (connection, transport) = try await connected { _ in "-WRONGPASS invalid username-password pair or user is disabled.\r\n" }
        let error = await Self.handshakeError(connection, HandshakeOptions(username: "alice", password: "s3cret", database: 3))
        XCTAssertEqual(error, .rejected(step: .hello, serverError: "WRONGPASS invalid username-password pair or user is disabled."))
        XCTAssertEqual(transport.commands.count, 1, "an auth error never falls back or selects")
    }

    func testNoPasswordOnProtectedServer() async throws {
        let (connection, _) = try await connected { _ in "-NOAUTH HELLO must be called with the client already authenticated\r\n" }
        let error = await Self.handshakeError(connection, HandshakeOptions())
        guard case .rejected(.hello, let text)? = error else { return XCTFail("unexpected \(String(describing: error))") }
        XCTAssertTrue(text.hasPrefix("NOAUTH"))
    }

    func testNoProtoFallsBackToResp2() async throws {
        let (connection, transport) = try await connected { $0[0] == "HELLO" ? "-NOPROTO unsupported protocol version\r\n" : "+OK\r\n" }
        let result = try await connection.handshake(HandshakeOptions())
        XCTAssertEqual(result.protocolVersion, 2)
        XCTAssertEqual(transport.commands, [["HELLO", "3", "SETNAME", "keel"], ["CLIENT", "SETNAME", "keel"]])
    }

    func testDatabaseOutOfRangeReportsCount() async throws {
        let (connection, transport) = try await connected { command in
            switch command[0] {
            case "SELECT": return "-ERR DB index is out of range\r\n"
            case "CONFIG": return "*2\r\n$9\r\ndatabases\r\n$2\r\n16\r\n"
            default: return Self.redis7(command)
            }
        }
        let error = await Self.handshakeError(connection, HandshakeOptions(database: 20))
        XCTAssertEqual(error, .databaseOutOfRange(index: 20, count: 16))
        XCTAssertEqual(transport.commands.last, ["CONFIG", "GET", "databases"])
    }

    func testDatabaseOutOfRangeWithoutConfigPermission() async throws {
        let (connection, _) = try await connected { command in
            switch command[0] {
            case "SELECT": return "-ERR DB index is out of range\r\n"
            case "CONFIG": return "-NOPERM User alice has no permissions to run the 'config|get' command\r\n"
            default: return Self.redis7(command)
            }
        }
        let error = await Self.handshakeError(connection, HandshakeOptions(database: 20))
        XCTAssertEqual(error, .databaseOutOfRange(index: 20, count: nil))
    }

    func testSelectPermissionDenied() async throws {
        let (connection, _) = try await connected { $0[0] == "SELECT" ? "-NOPERM User alice has no permissions to run the 'select' command\r\n" : Self.redis7($0) }
        let error = await Self.handshakeError(connection, HandshakeOptions(username: "alice", password: "pw", database: 1))
        XCTAssertEqual(error, .rejected(step: .select, serverError: "NOPERM User alice has no permissions to run the 'select' command"))
    }

    func testDatabaseZeroSendsNoSelect() async throws {
        let (connection, transport) = try await connected(Self.redis7)
        _ = try await connection.handshake(HandshakeOptions())
        XCTAssertEqual(transport.commands, [["HELLO", "3", "SETNAME", "keel"]])
    }

    func testHttpPortIsProtocolError() async throws {
        let (connection, _) = try await connected { _ in "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" }
        let error = await Self.handshakeError(connection, HandshakeOptions())
        XCTAssertEqual(error, .connection(.codec(.protocolError(.unknownType)), step: .hello))
    }

    func testUnansweredHandshakeTimesOutInAuthPhase() async throws {
        let sleeper = ManualSleeper()
        let connection = try await connected({ _ in nil }, sleeper: sleeper).0
        let options = HandshakeOptions(timeout: .seconds(7))
        let task = Task { () -> HandshakeError? in
            do throws(HandshakeError) { _ = try await connection.handshake(options); return nil } catch { return error }
        }
        let armed = await eventually { sleeper.count(.seconds(7)) == 1 }
        XCTAssertTrue(armed)
        sleeper.fire(.seconds(7))
        let error = await task.value
        XCTAssertEqual(error, .connection(.timeout(.auth), step: .hello))
    }

    func testFallbackAuthErrorIsRedacted() async throws {
        // A compatible server without HELLO or AUTH echoes the password in both errors.
        let (connection, _) = try await connected(Self.unknownCommand)
        let error = await Self.handshakeError(connection, HandshakeOptions(password: "s3cret"))
        guard case .rejected(.auth, let text)? = error else { return XCTFail("unexpected \(String(describing: error))") }
        XCTAssertEqual(text, "ERR unknown command 'AUTH'")
        XCTAssertFalse(String(describing: error).contains("s3cret"))
    }

    func testOptionsDescriptionHidesPassword() {
        let options = HandshakeOptions(username: "alice", password: "s3cret")
        XCTAssertFalse("\(options)".contains("s3cret"))
        XCTAssertFalse(String(reflecting: options).contains("s3cret"))
    }
}
