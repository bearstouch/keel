import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A console's `MULTI` in the data path: `EXEC` can't run writes queued before the profile became read-only (FR-SF01).
final class ConsoleTransactionTests: XCTestCase {
    private let writable = SafetyProfile(name: "payments-prod", readOnly: false, production: true, server: "cache:6379")

    func testExecRefusedAfterLockWhenWritesWereQueued() async throws {
        let server = TransactionServer()
        let service = DataCommandService(session: server.session())
        let console = ConsoleSession(service: service, profile: writable, database: 0)
        _ = await console.run(args("MULTI"))
        _ = await console.run(args("SET", "k", "v"))
        let flush = await console.run(args("FLUSHDB"), confirmation: CommandConfirmation(scope: .command(args("FLUSHDB")), database: 0))
        XCTAssertEqual(flush, .printed([ConsoleLine("QUEUED", kind: .output, reply: 3)]))
        // A nested MULTI is an error that leaves the transaction (and what it queued) as it was.
        _ = await console.run(args("MULTI"))
        await service.lockReadOnly()
        let sent = server.commands.count
        guard case .printed(let lines) = await console.run(args("EXEC")) else { return XCTFail("EXEC must print its refusal") }
        XCTAssertEqual(lines.first, ConsoleLine("(error) KEEL_READ_ONLY write commands are blocked on this connection", kind: .error, reply: 5))
        XCTAssertEqual(lines.last?.kind, .notice)
        XCTAssertTrue(lines.last?.text.contains("DISCARD") == true)
        XCTAssertEqual(server.commands.count, sent, "a refused EXEC sends nothing")
        // DISCARD ends it; EXEC then has nothing to run and goes to the server, which says so.
        _ = await console.run(args("DISCARD"))
        _ = await console.run(args("EXEC"))
        XCTAssertEqual(server.commands.suffix(2), [["DISCARD"], ["EXEC"]])
        XCTAssertEqual(server.executed, 0)
    }

    func testExecOfQueuedReadsRunsAfterLock() async throws {
        let server = TransactionServer()
        let service = DataCommandService(session: server.session())
        let console = ConsoleSession(service: service, profile: writable, database: 0)
        _ = await console.run(args("MULTI"))
        _ = await console.run(args("GET", "k"))
        await service.lockReadOnly()
        let exec = await console.run(args("EXEC"))
        XCTAssertEqual(exec, .printed([ConsoleLine("1) (nil)", kind: .output, reply: 3)]))
        XCTAssertEqual(server.commands.last, ["EXEC"])
        XCTAssertEqual(server.executed, 1)
    }

    func testReadOnlyTransactionOfReadsRuns() async throws {
        let server = TransactionServer()
        var readOnly = writable
        readOnly.readOnly = true
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: readOnly, database: 0)
        _ = await console.run(args("MULTI"))
        _ = await console.run(args("GET", "k"))
        let refused = await console.run(args("SET", "k", "v"))
        XCTAssertEqual(refused, .printed([ConsoleLine("(error) KEEL_READ_ONLY write commands are blocked on this connection", kind: .error, reply: 3)]))
        _ = await console.run(args("EXEC"))
        XCTAssertEqual(server.commands, [["MULTI"], ["GET", "k"], ["EXEC"]])
        XCTAssertEqual(server.executed, 1)
    }

    func testClosedConnectionTakesItsTransaction() async throws {
        let server = TransactionServer()
        let service = DataCommandService(session: server.session())
        let console = ConsoleSession(service: service, profile: writable, database: 0)
        _ = await console.run(args("MULTI"))
        _ = await console.run(args("SET", "k", "v"))
        // Stop closes the connection, and the server drops the MULTI with it: the next EXEC runs on a new connection.
        await console.cancel()
        await service.lockReadOnly()
        _ = await console.run(args("EXEC"))
        XCTAssertEqual(server.commands.last, ["EXEC"])
        XCTAssertEqual(server.connections, 2)
        XCTAssertEqual(server.executed, 0)
    }
}

/// An in-memory server that keeps `MULTI` state per connection: queues commands, answers `EXEC` with one reply per
/// queued command (`:7` for a length, `$-1` for a GET, `+OK` otherwise), and answers a length outside it with 20,000.
final class TransactionServer: @unchecked Sendable {
    private final class Connection: @unchecked Sendable {
        let lock = NSLock()
        var queued: [[String]]?
        weak var server: TransactionServer?

        func answer(_ arguments: [String]) -> String {
            let name = arguments[0].uppercased()
            let reply: String = lock.withLock {
                switch name {
                case "MULTI":
                    if queued != nil { return "-ERR MULTI calls can not be nested\r\n" }
                    queued = []; return "+OK\r\n"
                case "EXEC":
                    guard let commands = queued else { return "-ERR EXEC without MULTI\r\n" }
                    queued = nil
                    server?.didExecute(commands.count)
                    return "*\(commands.count)\r\n" + commands.map { Self.reply($0) }.joined()
                case "DISCARD":
                    guard queued != nil else { return "-ERR DISCARD without MULTI\r\n" }
                    queued = nil; return "+OK\r\n"
                default:
                    if queued != nil { queued?.append(arguments); return "+QUEUED\r\n" }
                    return ["HLEN", "SCARD", "LLEN", "DBSIZE"].contains(name) ? ":20000\r\n" : Self.reply(arguments)
                }
            }
            return reply
        }

        static func reply(_ arguments: [String]) -> String {
            switch arguments[0].uppercased() {
            case "HLEN", "SCARD", "LLEN", "DBSIZE": return ":7\r\n"
            case "GET": return "$-1\r\n"
            case "HGETALL": return "*0\r\n"
            default: return "+OK\r\n"
            }
        }
    }

    private let lock = NSLock()
    private var transports: [RecordingTransport] = []
    private var executions = 0

    /// Every command sent, on every connection, in order of connection.
    var commands: [[String]] { lock.withLock { transports }.flatMap(\.commands) }
    var connections: Int { lock.withLock { transports.count } }
    /// Commands an `EXEC` ran.
    var executed: Int { lock.withLock { executions } }

    fileprivate func didExecute(_ count: Int) { lock.withLock { executions += count } }

    func session() -> ServerSession {
        ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let state = Connection()
            state.server = self
            let transport = RecordingTransport { state.answer($0) }
            self.lock.withLock { self.transports.append(transport) }
            let connection = RedisConnection(transport: transport)
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake connect failed", suggestion: "")
            }
            return connection
        }
    }
}
