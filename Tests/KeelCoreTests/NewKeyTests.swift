import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A keyspace of typed keys that answers the new-key sheet's commands the way Redis does: `SET … NX [PX]`, `EXISTS`,
/// `HSET`, `RPUSH`, `SADD`, `ZADD`, `XADD`, `PEXPIRE` and `WATCH` / `MULTI` / `EXEC`. `appearsAfterWatch` makes "another
/// client" create the key between `WATCH` and `EXEC`.
private final class NewKeyspace: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var types: [String: String]
    private var expiries: [String: Int64] = [:]
    private var queued: [[String]]?
    private var watchedChanged = false
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    var appearsAfterWatch: String?

    init(_ types: [String: String] = [:]) { self.types = types }

    var keys: [String: String] { lock.withLock { types } }
    func ttl(_ key: String) -> Int64? { lock.withLock { expiries[key] } }
    var commands: [[String]] { lock.withLock { sent } }

    func service() -> DataCommandService {
        DataCommandService(
            session: ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
                let connection = RedisConnection(transport: self)
                do throws(RedisError) { try await connection.connect() } catch {
                    throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "")
                }
                return connection
            })
    }

    func connect() async throws(TransportError) {}

    /// A pipeline arrives as one write: every frame in it is answered, in order.
    func send(_ data: Data) {
        var parser = RESPParser()
        parser.append(data)
        var reply = ""
        while case .array(let items)? = try? parser.next() {
            let arguments = items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }
            reply += lock.withLock {
                sent.append(arguments); return answer(arguments)
            }
        }
        let bytes = Data(reply.utf8)
        let waiter: CheckedContinuation<Result<Data, TransportError>, Never>? = lock.withLock {
            if let receiver { self.receiver = nil; return receiver }
            pending.append(bytes)
            return nil
        }
        waiter?.resume(returning: .success(bytes))
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let ready: Result<Data, TransportError>? = lock.withLock {
                if !pending.isEmpty { return .success(pending.removeFirst()) }
                receiver = waiter
                return nil
            }
            if let ready { waiter.resume(returning: ready) }
        }
        return try result.get()
    }

    func cancel() {
        let waiter = lock.withLock {
            defer { receiver = nil }
            return receiver
        }
        waiter?.resume(returning: .failure(.cancelled))
    }

    /// Called with `lock` held.
    private func answer(_ arguments: [String]) -> String {
        switch arguments[0] {
        case "WATCH":
            watchedChanged = false
            return "+OK\r\n"
        case "UNWATCH": return "+OK\r\n"
        case "MULTI":
            queued = []
            if let key = appearsAfterWatch { types[key] = "string"; watchedChanged = true }
            return "+OK\r\n"
        case "EXEC":
            defer { queued = nil }
            if watchedChanged { return "*-1\r\n" }
            let commands = queued ?? []
            return "*\(commands.count)\r\n" + commands.map(run).joined()
        default:
            if queued != nil { queued?.append(arguments); return "+QUEUED\r\n" }
            return run(arguments)
        }
    }

    private func run(_ arguments: [String]) -> String {
        let key = arguments[1]
        func create(_ type: String) -> String? {
            if let existing = types[key], existing != type { return "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n" }
            types[key] = type
            return nil
        }
        switch arguments[0] {
        case "EXISTS": return types[key] == nil ? ":0\r\n" : ":1\r\n"
        case "SET":
            if arguments.contains("NX"), types[key] != nil { return "$-1\r\n" }
            types[key] = "string"
            if let px = arguments.firstIndex(of: "PX") { expiries[key] = Int64(arguments[px + 1]) }
            return "+OK\r\n"
        case "HSET": return create("hash") ?? ":\((arguments.count - 2) / 2)\r\n"
        case "RPUSH": return create("list") ?? ":\(arguments.count - 2)\r\n"
        case "SADD": return create("set") ?? ":\(arguments.count - 2)\r\n"
        case "ZADD": return create("zset") ?? ":\((arguments.count - 2) / 2)\r\n"
        case "XADD":
            guard arguments[2] == "*" || arguments[2] > "0-0" else { return "-ERR The ID specified in XADD must be greater than 0-0\r\n" }
            return create("stream") ?? "$15\r\n1700000000000-0\r\n"
        case "PEXPIRE":
            guard types[key] != nil else { return ":0\r\n" }
            expiries[key] = Int64(arguments[2])
            return ":1\r\n"
        default: return "-ERR unexpected \(arguments[0])\r\n"
        }
    }
}

final class NewKeyTests: XCTestCase {
    private let writable = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func pair(_ field: String, _ value: String) -> DataOperation.FieldValue { DataOperation.FieldValue(field: data(field), value: data(value)) }

    func testCreateOnlySemanticsPerType() async throws {
        let values: [(String, NewKey.Value, String)] = [
            ("s", .string(data("hello")), "string"), ("h", .hash([pair("name", "Ada")]), "hash"), ("l", .list([data("a"), data("b")]), "list"),
            ("set", .set([data("x")]), "set"), ("z", .sortedSet([DataOperation.ScoredMember(score: 1.5, member: data("m"))]), "zset"),
            ("x", .stream(id: StreamEditor.autoID, fields: [pair("f", "v")]), "stream")
        ]
        for (key, value, type) in values {
            let keyspace = NewKeyspace()
            let created = try await NewKey.create(data(key), value, service: keyspace.service(), context: writable)
            XCTAssertEqual(created, .created, key)
            XCTAssertEqual(keyspace.keys, [key: type], key)
        }

        // A string is one SET NX; the others are guarded by EXISTS under WATCH and written in one MULTI/EXEC.
        let strings = NewKeyspace()
        _ = try await NewKey.create(data("s"), .string(data("v")), service: strings.service(), context: writable)
        XCTAssertEqual(strings.commands, [["SET", "s", "v", "NX"]])
        let lists = NewKeyspace()
        _ = try await NewKey.create(data("l"), .list([data("a"), data("b")]), service: lists.service(), context: writable)
        XCTAssertEqual(lists.commands, [["WATCH", "l"], ["EXISTS", "l"], ["MULTI"], ["RPUSH", "l", "a", "b"], ["EXEC"]])

        // AC1: an existing key, of the same or another type, says "exists" and nothing is written.
        for (key, value, _) in values {
            let keyspace = NewKeyspace([key: "string"])
            let outcome = try await NewKey.create(data(key), value, service: keyspace.service(), context: writable)
            XCTAssertEqual(outcome, .exists, key)
            XCTAssertEqual(keyspace.keys, [key: "string"], key)
            XCTAssertFalse(keyspace.commands.contains { ["MULTI", "HSET", "RPUSH", "SADD", "ZADD", "XADD", "PEXPIRE"].contains($0[0]) }, key)
        }

        // The key appearing between WATCH and EXEC: EXEC runs nothing, and the re-read says it exists.
        let raced = NewKeyspace()
        raced.appearsAfterWatch = "h"
        let outcome = try await NewKey.create(data("h"), .hash([pair("f", "v")]), service: raced.service(), context: writable)
        XCTAssertEqual(outcome, .exists)
        XCTAssertEqual(raced.keys, ["h": "string"])
    }

    func testTTLAppliesWithTheValue() async throws {
        let strings = NewKeyspace()
        _ = try await NewKey.create(data("s"), .string(data("v")), ttlMilliseconds: 60_000, service: strings.service(), context: writable)
        XCTAssertEqual(strings.commands, [["SET", "s", "v", "NX", "PX", "60000"]])
        XCTAssertEqual(strings.ttl("s"), 60_000)

        let sets = NewKeyspace()
        _ = try await NewKey.create(data("t"), .set([data("a")]), ttlMilliseconds: 3_600_000, service: sets.service(), context: writable)
        XCTAssertEqual(sets.commands.suffix(4), [["MULTI"], ["SADD", "t", "a"], ["PEXPIRE", "t", "3600000"], ["EXEC"]])
        XCTAssertEqual(sets.ttl("t"), 3_600_000)
    }

    func testPrefillsNamespace() {
        XCTAssertEqual(NewKey.prefill(namespace: data("user"), separator: .default), data("user:"))
        XCTAssertEqual(NewKey.prefill(namespace: data("app:session"), separator: NamespaceSeparator(data("/"))!), data("app:session/"))
        // The root, or nothing selected, starts empty.
        XCTAssertEqual(NewKey.prefill(namespace: nil, separator: .default), Data())
        XCTAssertEqual(NewKey.prefill(namespace: Data(), separator: .default), Data())
        // Bytes pass through unchanged.
        XCTAssertEqual(NewKey.prefill(namespace: Data([0xFF, 0x00]), separator: .default), Data([0xFF, 0x00, 0x3A]))
    }

    func testBlockedOnReadOnly() async throws {
        let readOnly = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true))
        for value: NewKey.Value in [.string(data("v")), .hash([pair("f", "v")]), .stream(id: StreamEditor.autoID, fields: [pair("f", "v")])] {
            let keyspace = NewKeyspace()
            do {
                _ = try await NewKey.create(data("k"), value, ttlMilliseconds: 1_000, service: keyspace.service(), context: readOnly)
                XCTFail("a read-only profile must not create a key")
            } catch {
                XCTAssertEqual(error.code, "READ_ONLY")
            }
            XCTAssertEqual(keyspace.commands, [], "a blocked create sends nothing")
            XCTAssertEqual(keyspace.keys, [:])
        }
    }

    func testInvalidInputIsRefusedBeforeSending() async throws {
        let cases: [(Data, NewKey.Value, Int64?)] = [
            (Data(), .string(data("v")), nil), (data("k"), .string(data("v")), 0), (data("k"), .hash([]), nil), (data("k"), .hash([pair("", "v")]), nil),
            (data("k"), .list([]), nil), (data("k"), .set([]), nil), (data("k"), .sortedSet([]), nil),
            (data("k"), .sortedSet([DataOperation.ScoredMember(score: .nan, member: data("m"))]), nil),
            (data("k"), .stream(id: data("MAXLEN"), fields: [pair("f", "v")]), nil), (data("k"), .stream(id: StreamEditor.autoID, fields: []), nil)
        ]
        for (key, value, ttl) in cases {
            let keyspace = NewKeyspace()
            XCTAssertNotNil(NewKey.problem(key: key, value: value, ttlMilliseconds: ttl))
            do {
                _ = try await NewKey.create(key, value, ttlMilliseconds: ttl, service: keyspace.service(), context: writable)
                XCTFail("\(value) must be refused")
            } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
            XCTAssertEqual(keyspace.commands, [])
        }
        // An empty string is a valid value.
        XCTAssertNil(NewKey.problem(key: data("k"), value: .string(Data()), ttlMilliseconds: nil))
    }

    func testServerErrorInsideExecIsReported() async throws {
        let keyspace = NewKeyspace()
        do {
            _ = try await NewKey.create(data("x"), .stream(id: data("0-0"), fields: [pair("f", "v")]), service: keyspace.service(), context: writable)
            XCTFail("an ID the server refuses must fail")
        } catch {
            guard case .invalidRequest(let message) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(message.contains("greater than 0-0"))
        }
        XCTAssertEqual(keyspace.keys, [:])
    }
}
