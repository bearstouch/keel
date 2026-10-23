import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class DataCommandServiceReviewTests: XCTestCase {
    private let writable = DataContext(profile: SafetyProfile(name: "api-staging", readOnly: false), consoleID: UUID(), jobID: UUID())

    private func code(_ service: DataCommandService, _ command: DataCommand, _ origin: CommandOrigin, _ context: DataContext) async -> String? {
        do { _ = try await service.execute(command, origin: origin, context: context); return nil } catch { return error.code }
    }

    /// A failed open must not stay registered: the next use opens again instead of replaying the old failure.
    func testFailedOpenIsRetried() async throws {
        final class Attempts: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let attempts = Attempts()
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let attempt = attempts.lock.withLock {
                attempts.count += 1; return attempts.count
            }
            guard attempt > 1 else { throw ConnectionFailure(category: .connectionRefused, message: "refused", suggestion: "") }
            let connection = RedisConnection(transport: RecordingTransport())
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            return connection
        }
        let service = DataCommandService(session: session)
        let first = await code(service, .raw(args("GET", "k")), .editor, writable)
        XCTAssertEqual(first, "CONNECTION_FAILED")
        let result = try await service.execute(.raw(args("GET", "k")), origin: .editor, context: writable)
        XCTAssertEqual(result.role, .browser(database: 0))
        XCTAssertEqual(attempts.lock.withLock { attempts.count }, 2)
    }

    /// After the console's own `SELECT 5`, a FLUSHDB confirmed for db0 must not flush db5: the connection's database
    /// is tracked, and a command for another database sends nothing.
    func testConsoleDatabaseFollowsItsSelect() async throws {
        let server = RecordingServer { arguments in
            switch arguments {
            case ["SELECT", "99"]: return "-ERR DB index is out of range\r\n"
            case ["SELECT", "7"]: return "+QUEUED\r\n"
            default: return "+OK\r\n"
            }
        }
        let service = DataCommandService(session: server.session())
        let console = writable.consoleID!
        var db0 = writable
        db0.confirmation = CommandConfirmation(scope: .command(args("FLUSHDB")), database: 0)
        _ = try await service.execute(.raw(args("PING")), origin: .console, context: db0)
        _ = try await service.execute(.raw(args("SELECT", "5")), origin: .console, context: db0)
        let stale = await code(service, .raw(args("FLUSHDB")), .console, db0)
        XCTAssertEqual(stale, "INVALID_PARAMS")
        XCTAssertEqual(server.allCommands, [["PING"], ["SELECT", "5"]], "FLUSHDB never reached db5")

        var db5 = writable
        db5.database = 5
        db5.confirmation = CommandConfirmation(scope: .command(args("FLUSHDB")), database: 5)
        _ = try await service.execute(.raw(args("FLUSHDB")), origin: .console, context: db5)
        // A refused SELECT leaves the database as it was.
        _ = try await service.execute(.raw(args("SELECT", "99")), origin: .console, context: db5)
        _ = try await service.execute(.raw(args("GET", "k")), origin: .console, context: db5)
        // A queued SELECT (MULTI) makes it unknown: data commands wait for a SELECT, connection state still runs.
        _ = try await service.execute(.raw(args("SELECT", "7")), origin: .console, context: db5)
        let unknown = await code(service, .raw(args("SET", "k", "v")), .console, db5)
        XCTAssertEqual(unknown, "INVALID_PARAMS")
        _ = try await service.execute(.raw(args("EXEC")), origin: .console, context: db5)
        _ = try await service.execute(.raw(args("RESET")), origin: .console, context: db5)
        _ = try await service.execute(.raw(args("GET", "k")), origin: .console, context: writable)
        XCTAssertEqual(server.opened.map(\.role), [.console(console)])
        XCTAssertEqual(
            server.allCommands, [["PING"], ["SELECT", "5"], ["FLUSHDB"], ["SELECT", "99"], ["GET", "k"], ["SELECT", "7"], ["EXEC"], ["RESET"], ["GET", "k"]])
    }

    /// A job's connection stays on the database it opened with; the same job id with another database sends nothing.
    func testJobOnAnotherDatabaseSendsNothing() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        _ = try await service.execute(.raw(args("SCAN", "0")), origin: .bulk, context: writable)
        var db3 = writable
        db3.database = 3
        db3.confirmation = CommandConfirmation(scope: .keys([Data("a".utf8), Data("b".utf8)]), database: 3)
        let moved = await code(service, .operation(.delete(keys: [Data("a".utf8), Data("b".utf8)])), .bulk, db3)
        XCTAssertEqual(moved, "INVALID_PARAMS")
        XCTAssertEqual(server.allCommands, [["SCAN", "0"]])
    }

    /// UNSUBSCRIBE goes to the console's stream connection, whatever database the console is on.
    func testUnsubscribeRoutesToStream() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let console = writable.consoleID!
        _ = try await service.execute(.raw(args("SUBSCRIBE", "a", "b")), origin: .console, context: writable)
        var db2 = writable
        db2.database = 2
        let result = try await service.execute(.raw(args("UNSUBSCRIBE", "a", "b")), origin: .console, context: db2)
        XCTAssertEqual(result.role, .stream(console))
        XCTAssertEqual(server.opened.map(\.role), [.stream(console)])
        let editor = await code(service, .raw(args("UNSUBSCRIBE", "a", "b")), .editor, writable)
        XCTAssertEqual(editor, "BLOCKED_COMMAND")
    }
}
