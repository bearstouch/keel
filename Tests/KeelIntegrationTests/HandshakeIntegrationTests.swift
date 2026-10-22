import Foundation
import KeelCore
import KeelRESP
import XCTest

/// KEEL-006 checks. Needs `KEEL_INTEGRATION=1` and a disposable server on 127.0.0.1 at
/// `KEEL_INTEGRATION_REDIS_PORT` (default 6379) whose default user needs no password; the test creates its own
/// ACL users there. The KEEL-053 container matrix replaces this with the ACL fixture.
final class HandshakeIntegrationTests: XCTestCase {
    private var port: UInt16 = 6_379

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1")
        port = UInt16(environment["KEEL_INTEGRATION_REDIS_PORT"] ?? "") ?? 6_379
        let admin = try await open(HandshakeOptions())
        for user in [["keel-alice", "on", ">right", "~*", "+@all"], ["keel-noselect", "on", ">pw", "~*", "+@all", "-select"]] {
            _ = try await admin.send((["ACL", "SETUSER"] + user).map { Data($0.utf8) })
        }
        await admin.close()
    }

    override func tearDown() async throws {
        guard IntegrationGate.isEnabled(ProcessInfo.processInfo.environment) else { return }
        let admin = try await open(HandshakeOptions())
        _ = try await admin.send(["ACL", "DELUSER", "keel-alice", "keel-noselect"].map { Data($0.utf8) })
        await admin.close()
    }

    private func open(_ options: HandshakeOptions) async throws -> RedisConnection {
        let connection = RedisConnection(endpoint: .tcp(host: "127.0.0.1", port: port))
        try await connection.connect()
        _ = try await connection.handshake(options)
        return connection
    }

    private func failure(_ options: HandshakeOptions) async throws -> ConnectionFailure? {
        let connection = RedisConnection(endpoint: .tcp(host: "127.0.0.1", port: port))
        try await connection.connect()
        defer { Task { await connection.close() } }
        do throws(HandshakeError) {
            _ = try await connection.handshake(options); return nil
        } catch {
            return ConnectionFailure(handshake: error, endpoint: .tcp(host: "127.0.0.1", port: port), options: options)
        }
    }

    func testHelloAuthenticatesAclUser() async throws {
        let connection = try await open(HandshakeOptions(username: "keel-alice", password: "right", database: 1))
        let name = try await connection.send(["CLIENT", "GETNAME"].map { Data($0.utf8) }, mayWrite: false)
        XCTAssertEqual(name, .bulkString(Data("keel".utf8)))
        await connection.close()
    }

    func testWrongPasswordIsAuthFailed() async throws {
        let result = try await failure(HandshakeOptions(username: "keel-alice", password: "wrong"))
        XCTAssertEqual(result?.category, .authFailed)
        XCTAssertTrue(result?.message.contains("keel-alice") == true)
        XCTAssertFalse(result?.description.contains("wrong") == true)
    }

    func testAclUserWithoutSelectIsPermissionDenied() async throws {
        let result = try await failure(HandshakeOptions(username: "keel-noselect", password: "pw", database: 1))
        XCTAssertEqual(result?.category, .permissionDenied)
        XCTAssertTrue(result?.message.contains("SELECT") == true, result?.message ?? "")
    }

    func testSelectOutOfRangeNamesDatabaseCount() async throws {
        let result = try await failure(HandshakeOptions(database: 20))
        XCTAssertEqual(result?.category, .databaseOutOfRange)
        XCTAssertTrue(result?.message.contains("16 databases") == true, result?.message ?? "")
    }

    func testSetNameOffSendsNoName() async throws {
        let connection = try await open(HandshakeOptions(setName: false))
        let name = try await connection.send(["CLIENT", "GETNAME"].map { Data($0.utf8) }, mayWrite: false)
        XCTAssertTrue(name.isNull)
        await connection.close()
    }
}
