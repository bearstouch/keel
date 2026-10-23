import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class DataCommandServiceTests: XCTestCase {
    private let readOnly = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true), consoleID: UUID(), jobID: UUID())
    private let writable = DataContext(profile: SafetyProfile(name: "api-staging", readOnly: false), consoleID: UUID(), jobID: UUID())

    // MARK: - Story tests

    func testBlockedCommandSendsNothing() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let refused: [(DataCommand, CommandOrigin, DataContext, String)] = [
            (.operation(.stringSet(key: Data("k".utf8), value: Data("v".utf8), keepTTL: false)), .editor, readOnly, "READ_ONLY"),
            (.raw(args("SET", "k", "v")), .console, readOnly, "READ_ONLY"),
            (.operation(.delete(keys: [Data("a".utf8), Data("b".utf8)])), .bulk, readOnly, "READ_ONLY"),
            (.raw(args("HSET", "h", "f", "v")), .agent(grantID: UUID()), readOnly, "READ_ONLY"),
            (.raw(args("EVAL", "return 0", "0")), .console, readOnly, "READ_ONLY"),
            (.raw(args("FLUSHDB")), .console, writable, "CONFIRMATION_REQUIRED"),
            (.raw(args("FLUSHALL")), .agent(grantID: UUID()), writable, "APPROVAL_REQUIRED"),
            (.raw(args("CONFIG", "SET", "maxmemory", "1")), .agent(grantID: UUID()), writable, "BLOCKED_COMMAND"),
            (.raw(args("KEYS", "*")), .browser, writable, "BLOCKED_COMMAND"),
            (.raw(args("NOSUCHCOMMAND")), .editor, writable, "BLOCKED_COMMAND"),
            (.raw([]), .console, writable, "INVALID_PARAMS")
        ]
        for (command, origin, context, code) in refused {
            do {
                _ = try await service.execute(command, origin: origin, context: context)
                XCTFail("\(command) from \(origin) should be refused")
            } catch {
                XCTAssertEqual(error.code, code, "\(command) from \(origin)")
            }
        }
        // Refused before routing: no connection was even opened, so no byte reached any socket.
        XCTAssertTrue(server.opened.isEmpty)
        XCTAssertTrue(server.allCommands.isEmpty)

        // The same path sends an allowed command exactly once.
        let result = try await service.execute(.raw(args("GET", "k")), origin: .editor, context: readOnly)
        XCTAssertEqual(result.safetyClass, .read)
        XCTAssertEqual(server.allCommands, [["GET", "k"]])
    }

    func testRoutesToConnectionRoles() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let grant = UUID()
        var db2 = writable
        db2.database = 2
        let expected: [(DataCommand, CommandOrigin, DataContext, ConnectionRole)] = [
            (.operation(.get(key: Data("k".utf8))), .editor, writable, .browser(database: 0)),
            (.operation(.scan(cursor: Data("0".utf8), match: nil, count: 100, type: nil)), .browser, writable, .browser(database: 0)),
            (.raw(args("GET", "k")), .browser, db2, .browser(database: 2)),
            (.raw(args("SELECT", "4")), .console, writable, .console(writable.consoleID!)),
            (.raw(args("SUBSCRIBE", "ch")), .console, writable, .stream(writable.consoleID!)),
            (.raw(args("SCAN", "0", "MATCH", "tmp:*")), .bulk, writable, .job(writable.jobID!)),
            (.raw(args("GET", "k")), .agent(grantID: grant), db2, .agent(grantID: grant, database: 2)),
            (.raw(args("GET", "k")), .editor, writable, .browser(database: 0))
        ]
        for (command, origin, context, role) in expected {
            let result = try await service.execute(command, origin: origin, context: context)
            XCTAssertEqual(result.role, role, "\(command) from \(origin)")
        }
        // One connection per role, reused: the editor and the browser share db0's.
        XCTAssertEqual(server.opened.map(\.role), [.browser(database: 0), .browser(database: 2), .console(writable.consoleID!), .stream(writable.consoleID!), .job(writable.jobID!), .agent(grantID: grant, database: 2)])
        XCTAssertEqual(server.opened.map(\.database), [0, 2, 0, 0, 0, 2])
        XCTAssertEqual(server.opened[0].transport.commands, [["GET", "k"], ["SCAN", "0", "COUNT", "100"], ["GET", "k"]])
        XCTAssertEqual(server.opened[3].transport.commands, [["SUBSCRIBE", "ch"]])

        // A console or bulk command without its console or job is malformed, and nothing is sent.
        var orphan = writable
        orphan.consoleID = nil; orphan.jobID = nil
        for origin in [CommandOrigin.console, .bulk] {
            do {
                _ = try await service.execute(.raw(args("GET", "k")), origin: origin, context: orphan)
                XCTFail("\(origin) without its id")
            } catch {
                XCTAssertEqual(error.code, "INVALID_PARAMS")
            }
        }
        XCTAssertEqual(server.opened.count, 6)
    }

    // MARK: - Data path

    func testConfirmedDestructiveCommandRuns() async throws {
        let server = RecordingServer { _ in ":2\r\n" }
        let service = DataCommandService(session: server.session())
        var context = writable
        context.confirmation = CommandConfirmation(source: .user, scope: .pattern(Data("tmp:*".utf8)), database: 0)
        let result = try await service.execute(.operation(.delete(keys: [Data("tmp:1".utf8), Data("tmp:2".utf8)])), origin: .bulk, context: context)
        XCTAssertEqual(result.safetyClass, .destructive)
        XCTAssertEqual(server.allCommands, [["UNLINK", "tmp:1", "tmp:2"]])
        if case .integer(2) = result.reply {} else { XCTFail("\(result.reply)") }
    }

    func testTypedOperationsCompileToCommands() {
        let k = Data("k".utf8), v = Data("v".utf8)
        let table: [(DataOperation, [String])] = [
            (.scan(cursor: Data("0".utf8), match: Data("user:*".utf8), count: 500, type: Data("hash".utf8)), ["SCAN", "0", "MATCH", "user:*", "COUNT", "500", "TYPE", "hash"]),
            (.stringSet(key: k, value: v, keepTTL: true), ["SET", "k", "v", "KEEPTTL"]), (.hashDeleteFields(key: k, fields: [v]), ["HDEL", "k", "v"]),
            (.listPush(key: k, values: [v], atHead: false), ["RPUSH", "k", "v"]), (.listSet(key: k, index: -1, value: v), ["LSET", "k", "-1", "v"]),
            (.listRemove(key: k, count: 0, value: v), ["LREM", "k", "0", "v"]), (.setRemove(key: k, members: [v]), ["SREM", "k", "v"]),
            (
                .sortedSetAdd(key: k, members: [.init(score: 1.5, member: v), .init(score: 2, member: k), .init(score: -.infinity, member: v)]),
                ["ZADD", "k", "1.5", "v", "2", "k", "-inf", "v"]
            ), (.sortedSetRemove(key: k, members: [v]), ["ZREM", "k", "v"]),
            (.streamDelete(key: k, ids: [Data("1-0".utf8)]), ["XDEL", "k", "1-0"]), (.rename(key: k, newKey: v, overwrite: true), ["RENAME", "k", "v"]),
            (.rename(key: k, newKey: v, overwrite: false), ["RENAMENX", "k", "v"]), (.expire(key: k, milliseconds: 90_000), ["PEXPIRE", "k", "90000"]),
            (.type(key: k), ["TYPE", "k"]), (.pttl(key: k), ["PTTL", "k"]), (.memoryUsage(key: k), ["MEMORY", "USAGE", "k", "SAMPLES", "0"]), (.flushDatabase(async: true), ["FLUSHDB", "ASYNC"]),
            (.flushAll(async: false), ["FLUSHALL"]), (.databaseSize, ["DBSIZE"]), (.info(section: Data("keyspace".utf8)), ["INFO", "keyspace"])
        ]
        for (operation, expected) in table {
            XCTAssertEqual(operation.arguments.map { String(decoding: $0, as: UTF8.self) }, expected, "\(operation)")
        }
        // Bytes pass through untouched (keys aren't strings).
        let binary = Data([0x00, 0xFF, 0x0D, 0x0A])
        XCTAssertEqual(DataOperation.hashSetField(key: binary, field: binary, value: binary).arguments, [Data("HSET".utf8), binary, binary, binary])
    }

    func testCatalogRefreshTakesThePolicyPath() async throws {
        let server = RecordingServer { arguments in
            switch arguments {
            case ["COMMAND"]: return "*1\r\n*6\r\n$8\r\njson.get\r\n:-2\r\n*1\r\n+readonly\r\n:1\r\n:1\r\n:1\r\n"
            case ["COMMAND", "DOCS"]: return "*0\r\n"
            default: return "+OK\r\n"
            }
        }
        let service = DataCommandService(session: server.session())
        let before = await service.catalog
        XCTAssertEqual(before.access(of: args("JSON.GET", "k")), .unknown)
        try await service.refreshCatalog(context: readOnly)
        XCTAssertEqual(server.allCommands, [["COMMAND"], ["COMMAND", "DOCS"]], "read-only allows the metadata commands")
        let after = await service.catalog
        XCTAssertEqual(after.access(of: args("JSON.GET", "k")), .read)
        _ = try await service.execute(.raw(args("JSON.GET", "k")), origin: .editor, context: readOnly)
        XCTAssertEqual(server.allCommands.last, ["JSON.GET", "k"])
    }

    func testClosedConnectionIsReplacedNotReplayed() async throws {
        let server = RecordingServer()
        let session = server.session()
        let service = DataCommandService(session: session)
        _ = try await service.execute(.raw(args("SET", "a", "1")), origin: .editor, context: writable)
        await session.close(.browser(database: 0))
        let afterClose = await session.readyRoles()
        XCTAssertEqual(afterClose, [])
        _ = try await service.execute(.raw(args("GET", "a")), origin: .editor, context: writable)
        XCTAssertEqual(server.opened.count, 2)
        XCTAssertEqual(server.opened[0].transport.commands, [["SET", "a", "1"]])
        XCTAssertEqual(server.opened[1].transport.commands, [["GET", "a"]], "the earlier write isn't re-sent")
        let reopened = await session.readyRoles()
        XCTAssertEqual(reopened, [.browser(database: 0)])
    }
}
