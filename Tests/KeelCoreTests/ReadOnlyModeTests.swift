import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// FR-SF01 / FR-SF07 in the data path: the read-only lock of an open session, the write events a tab's notice follows,
/// and the server replies that mean the server itself refuses writes.
final class ReadOnlyModeTests: XCTestCase {
    private let writable = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: false, production: true))

    /// Collects the service's write events.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [WriteEvent] = []
        var all: [WriteEvent] { lock.withLock { items } }
        func add(_ event: WriteEvent) { lock.withLock { items.append(event) } }
    }

    func testLockReadOnlyRefusesLaterWritesAndSendsNothing() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        _ = try await service.execute(.operation(.stringSet(key: Data("a".utf8), value: Data("1".utf8), keepTTL: false)), origin: .editor, context: writable)
        await service.lockReadOnly()
        let before = server.allCommands.count
        // The caller still holds a writable context: the lock wins for single commands and saves alike.
        for attempt in [DataOperation.stringSet(key: Data("a".utf8), value: Data("2".utf8), keepTTL: false), .delete(keys: [Data("a".utf8)]), .persist(key: Data("a".utf8))] {
            do {
                _ = try await service.execute(.operation(attempt), origin: .editor, context: writable)
                XCTFail("\(attempt) ran after the lock")
            } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        }
        do {
            _ = try await service.executeTransaction([.hashSetField(key: Data("h".utf8), field: Data("f".utf8), value: Data("v".utf8))], unchanged: nil, context: writable)
            XCTFail("a save ran after the lock")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        XCTAssertEqual(server.allCommands.count, before, "nothing is sent once locked")
        // Reads still work.
        _ = try await service.execute(.operation(.get(key: Data("a".utf8))), origin: .editor, context: writable)
        XCTAssertEqual(server.allCommands.last, ["GET", "a"])
        let locked = await service.isReadOnlyLocked
        XCTAssertTrue(locked)
    }

    func testWriteEventsFollowWritesOnly() async throws {
        let server = RecordingServer { $0[0] == "GET" ? "$1\r\n1\r\n" : "+OK\r\n" }
        let service = DataCommandService(session: server.session())
        let events = Events()
        await service.observeWrites { events.add($0) }
        _ = try await service.execute(.operation(.get(key: Data("a".utf8))), origin: .editor, context: writable)
        XCTAssertEqual(events.all, [], "a read is not a write")
        _ = try await service.execute(.operation(.stringSet(key: Data("a".utf8), value: Data("1".utf8), keepTTL: false)), origin: .editor, context: writable)
        XCTAssertEqual(events.all, [.sent])
        // A refused write never reports itself as sent.
        let readOnly = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true, production: true))
        _ = try? await service.execute(.operation(.persist(key: Data("a".utf8))), origin: .editor, context: readOnly)
        XCTAssertEqual(events.all, [.sent])
        await service.observeWrites(nil)
        _ = try await service.execute(.operation(.persist(key: Data("a".utf8))), origin: .editor, context: writable)
        XCTAssertEqual(events.all, [.sent], "a removed observer hears nothing")
    }

    func testServerRefusalIsReportedForCommandsAndSaves() async throws {
        // An ACL user that can read but not run SET; HSET queued in MULTI is refused the same way and aborts EXEC.
        let answer: @Sendable ([String]) -> String = { arguments in
            switch arguments[0] {
            case "SET": return "-NOPERM User reader has no permissions to run the 'set' command\r\n"
            case "HSET": return "-NOPERM this user has no permissions to run the 'hset' command or its subcommand\r\n"
            case "EXEC": return "-EXECABORT Transaction discarded because of previous errors.\r\n"
            default: return "+OK\r\n"
            }
        }
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: PipelineTransport(answer: answer))
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            return connection
        }
        let service = DataCommandService(session: session)
        let events = Events()
        await service.observeWrites { events.add($0) }
        let reply = try await service.execute(.operation(.stringSet(key: Data("a".utf8), value: Data("1".utf8), keepTTL: false)), origin: .editor, context: writable).reply
        XCTAssertTrue(ServerReadOnly.refusesWrites(reply))
        XCTAssertEqual(events.all, [.sent, .serverRefused])
        _ = try await service.executeTransaction([.hashSetField(key: Data("h".utf8), field: Data("f".utf8), value: Data("v".utf8))], unchanged: nil, context: writable)
        XCTAssertEqual(events.all, [.sent, .serverRefused, .sent, .serverRefused])
    }

    func testServerReadOnlyReplies() {
        func error(_ text: String) -> RESPValue { .error(Data(text.utf8)) }
        XCTAssertTrue(ServerReadOnly.refusesWrites(error("READONLY You can't write against a read only replica.")))
        XCTAssertTrue(ServerReadOnly.refusesWrites(error("NOPERM User u has no permissions to run the 'set' command")))
        XCTAssertTrue(ServerReadOnly.refusesWrites(.blobError(Data("NOPERM this user has no permissions to run the 'del' command or its subcommand".utf8))))
        // A key-pattern refusal leaves other keys writable; other errors say nothing about permissions.
        XCTAssertFalse(ServerReadOnly.refusesWrites(error("NOPERM No permissions to access a key")))
        XCTAssertFalse(ServerReadOnly.refusesWrites(error("NOPERM this user has no permissions to access one of the keys used as arguments")))
        XCTAssertFalse(ServerReadOnly.refusesWrites(error("WRONGTYPE Operation against a key holding the wrong kind of value")))
        XCTAssertFalse(ServerReadOnly.refusesWrites(.simpleString(Data("OK".utf8))))
    }
}

/// Answers every command frame in a chunk, so a pipelined `MULTI … EXEC` gets one reply per command.
private final class PipelineTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var parser = RESPParser()
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    private let answer: @Sendable ([String]) -> String

    init(answer: @escaping @Sendable ([String]) -> String) { self.answer = answer }

    func connect() async throws(TransportError) {}

    func send(_ data: Data) {
        let waiter: (CheckedContinuation<Result<Data, TransportError>, Never>, Data)? = lock.withLock {
            parser.append(data)
            var reply = Data()
            while case .array(let items)? = try? parser.next() {
                reply += Data(answer(items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }).utf8)
            }
            if let receiver { self.receiver = nil; return (receiver, reply) }
            pending.append(reply)
            return nil
        }
        if let (receiver, reply) = waiter { receiver.resume(returning: .success(reply)) }
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let ready: Data? = lock.withLock {
                if !pending.isEmpty { return pending.removeFirst() }
                receiver = waiter
                return nil
            }
            if let ready { waiter.resume(returning: .success(ready)) }
        }
        return try result.get()
    }

    func cancel() {
        let waiter = lock.withLock {
            defer { receiver = nil }; return receiver
        }
        waiter?.resume(returning: .failure(.cancelled))
    }
}
