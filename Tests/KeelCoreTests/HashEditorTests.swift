import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// One hash with `MULTI/EXEC` and `WATCH`: fields keep insertion order, `HSCAN`'s cursor is an offset that returns
/// `scanBatch` fields a round (COUNT by default), and `EXEC` replies nil when the hash changed after `WATCH`.
final class HashServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [(String, String)]
    private var version = 0
    private var watched: Int?
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    /// Fields per `HSCAN` round in place of COUNT, for a server that answers rounds with fewer fields.
    var scanBatch: Int?
    /// Another client's `HSET`, made right after the save's last guard read (between `WATCH` and `EXEC`).
    var changeAfterGuardRead: (field: String, value: String)?
    /// Answer a missing field with RESP3's null (`_`) instead of RESP2's nil bulk string.
    var resp3Null = false

    init(_ fields: [(String, String)]) { self.fields = fields }

    var commands: [[String]] { lock.withLock { sent } }
    var hash: [String: String] { lock.withLock { Dictionary(fields, uniquingKeysWith: { a, _ in a }) } }

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

    func send(_ data: Data) {
        var parser = RESPParser()
        parser.append(data)
        var reply = ""
        while case .array(let items)? = try? parser.next() {
            reply += answer(items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } })
        }
        let bytes = Data(reply.utf8)
        let waiter: CheckedContinuation<Result<Data, TransportError>, Never>? = lock.withLock {
            if let receiver { self.receiver = nil; return receiver }
            pending.append(bytes)
            return nil
        }
        waiter?.resume(returning: .success(bytes))
    }

    private func answer(_ arguments: [String]) -> String {
        lock.withLock {
            sent.append(arguments)
            switch arguments.first {
            case "WATCH": watched = version; return "+OK\r\n"
            case "UNWATCH": watched = nil; return "+OK\r\n"
            case "MULTI": queued = []; return "+OK\r\n"
            case "EXEC":
                defer { queued = nil; watched = nil }
                if let watched, watched != version { return "*-1\r\n" }
                let commands = queued ?? []
                return "*\(commands.count)\r\n" + commands.map(run).joined()
            default:
                if queued != nil { queued?.append(arguments); return "+QUEUED\r\n" }
                let reply = run(arguments)
                if arguments.first == "HGET", watched != nil, let change = changeAfterGuardRead {
                    changeAfterGuardRead = nil
                    _ = run(["HSET", "h", change.field, change.value])
                }
                return reply
            }
        }
    }

    private func run(_ arguments: [String]) -> String {
        switch arguments.first {
        case "HLEN": return ":\(fields.count)\r\n"
        case "PTTL": return ":-1\r\n"
        case "HGETALL": return "*\(fields.count * 2)\r\n" + fields.map { Self.bulk($0.0) + Self.bulk($0.1) }.joined()
        case "HSCAN":
            let start = Int(arguments[2])!, count = scanBatch ?? Int(arguments[4])!
            let page = fields[min(start, fields.count)..<min(start + count, fields.count)]
            let next = start + count >= fields.count ? 0 : start + count
            return "*2\r\n" + Self.bulk(String(next)) + "*\(page.count * 2)\r\n" + page.map { Self.bulk($0.0) + Self.bulk($0.1) }.joined()
        case "HGET": return fields.first { $0.0 == arguments[2] }.map { Self.bulk($0.1) } ?? (resp3Null ? "_\r\n" : "$-1\r\n")
        case "HSET":
            let field = arguments[2], value = arguments[3]
            version += 1
            if let index = fields.firstIndex(where: { $0.0 == field }) { fields[index].1 = value; return ":0\r\n" }
            fields.append((field, value))
            return ":1\r\n"
        case "HDEL":
            let removed = Set(arguments.dropFirst(2))
            let before = fields.count
            fields.removeAll { removed.contains($0.0) }
            version += 1
            return ":\(before - fields.count)\r\n"
        default: return "-ERR unexpected\r\n"
        }
    }

    private static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }

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
}

final class HashEditorTests: XCTestCase {
    private let key = Data("h".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }
    private func row(_ field: String, _ value: String) -> EditorRow { EditorRow(id: d(field), value: d(value)) }
    private static func numbered(_ count: Int) -> [(String, String)] { (0..<count).map { ("f\($0)", "v\($0)") } }

    func testSmallHashUsesHGetAll() async throws {
        let server = HashServer([("name", "Ada"), ("city", "London"), ("plan", "pro")])
        let value = try await HashEditor.load(key: key, service: server.service(), context: context)
        XCTAssertEqual(server.commands, [["HLEN", "h"], ["HGETALL", "h"]])
        XCTAssertEqual(value.rows, [row("name", "Ada"), row("city", "London"), row("plan", "pro")])
        XCTAssertNil(value.next, "fully loaded")
        XCTAssertNil(value.partial, "editable")

        let limit = HashServer(Self.numbered(1_000))
        let whole = try await HashEditor.load(key: key, service: limit.service(), context: context)
        XCTAssertEqual(whole.rows.count, 1_000, "exactly 1,000 fields still use HGETALL")
        XCTAssertEqual(limit.commands.map { $0[0] }, ["HLEN", "HGETALL"])
    }

    /// AC2: over 1,000 fields only the first `HSCAN … COUNT 500` page is read (never `HGETALL`); Load more continues.
    func testLargeHashPagesWithHScan() async throws {
        let server = HashServer(Self.numbered(1_200))
        let service = server.service()
        let first = try await HashEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(server.commands, [["HLEN", "h"], ["HSCAN", "h", "0", "COUNT", "500"]])
        XCTAssertEqual(first.rows.count, 500)
        XCTAssertEqual(first.next, d("500"))

        let second = try await HashEditor.loadMore(key: key, cursor: d("500"), service: service, context: context)
        XCTAssertEqual(second.rows.first, row("f500", "v500"))
        XCTAssertEqual(second.next, d("1000"))
        let last = try await HashEditor.loadMore(key: key, cursor: d("1000"), service: service, context: context)
        XCTAssertEqual(last.rows.count, 200)
        XCTAssertNil(last.next, "cursor 0: every field loaded")
        XCTAssertFalse(server.commands.contains { $0[0] == "HGETALL" })
    }

    /// A server that answers `HSCAN` rounds with few fields: a page keeps scanning up to 500 fields, but a bounded number of rounds.
    func testScanPageIsBounded() async throws {
        let server = HashServer(Self.numbered(5_000))
        server.scanBatch = 200
        let value = try await HashEditor.load(key: key, service: server.service(), context: context)
        XCTAssertEqual(value.rows.count, 600, "three rounds reach the page size")
        XCTAssertEqual(value.next, d("600"))

        let sparse = HashServer(Self.numbered(5_000))
        sparse.scanBatch = 10
        let page = try await HashEditor.load(key: key, service: sparse.service(), context: context)
        XCTAssertEqual(sparse.commands.filter { $0[0] == "HSCAN" }.count, HashEditor.scanRounds)
        XCTAssertEqual(page.rows.count, 10 * HashEditor.scanRounds)
    }

    /// AC3: a rename is HSET new + HDEL old in one `MULTI … EXEC`, guarded by both fields.
    func testRenameFieldIsAtomic() async throws {
        let server = HashServer([("email", "ada@example.com"), ("name", "Ada")])
        let service = server.service()
        let loaded = try await HashEditor.load(key: key, service: service, context: context)
        guard case .applied(let draft) = HashEditor.rename(d("email"), to: d("mail"), in: loaded.rows, overwrite: false) else { return XCTFail("renamed") }
        XCTAssertEqual(draft, [row("mail", "ada@example.com"), row("name", "Ada")], "the value keeps its place")

        let writes = HashEditor.writes(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(writes, [.hashSetField(key: key, field: d("mail"), value: d("ada@example.com")), .hashDeleteFields(key: key, fields: [d("email")])])
        let guardReads = HashEditor.saveGuard(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(guardReads.reads, [.hashGet(key: key, field: d("email")), .hashGet(key: key, field: d("mail"))])
        XCTAssertEqual(guardReads.expected, [.bulkString(d("ada@example.com")), .nullBulkString])

        _ = try await service.executeTransaction(writes, unchanged: guardReads, context: context)
        XCTAssertEqual(
            Array(server.commands.drop { $0[0] != "WATCH" }),
            [["WATCH", "h"], ["HGET", "h", "email"], ["HGET", "h", "mail"], ["MULTI"], ["HSET", "h", "mail", "ada@example.com"], ["HDEL", "h", "email"], ["EXEC"]])
        XCTAssertEqual(server.hash, ["mail": "ada@example.com", "name": "Ada"])
    }

    /// AC3: a rename whose transaction fails (another client wrote the hash before `EXEC`) leaves both fields as they were.
    func testFailedRenameLeavesBothFields() async throws {
        let server = HashServer([("a", "1"), ("b", "2")])
        let service = server.service()
        let loaded = try await HashEditor.load(key: key, service: service, context: context)
        guard case .applied(let draft) = HashEditor.rename(d("a"), to: d("c"), in: loaded.rows, overwrite: false) else { return XCTFail("renamed") }
        server.changeAfterGuardRead = ("b", "3")
        do {
            _ = try await service.executeTransaction(
                HashEditor.writes(key: key, loaded: loaded.rows, draft: draft), unchanged: HashEditor.saveGuard(key: key, loaded: loaded.rows, draft: draft),
                context: context)
            XCTFail("expected a conflict")
        } catch { XCTAssertEqual(error, .conflict) }
        XCTAssertEqual(server.hash, ["a": "1", "b": "3"], "neither HSET c nor HDEL a ran")
    }

    /// AC1: renaming onto an existing field asks; nothing changes until the user confirms.
    func testRenameOntoExistingAsks() {
        let draft = [row("a", "1"), row("b", "2"), row("c", "3")]
        XCTAssertEqual(HashEditor.rename(d("a"), to: d("b"), in: draft, overwrite: false), .confirmOverwrite(field: d("b")))
        XCTAssertEqual(HashEditor.rename(d("a"), to: d("b"), in: draft, overwrite: true), .applied([row("b", "1"), row("c", "3")]))
        XCTAssertEqual(
            HashEditor.writes(key: key, loaded: draft, draft: [row("b", "1"), row("c", "3")]),
            [.hashSetField(key: key, field: d("b"), value: d("1")), .hashDeleteFields(key: key, fields: [d("a")])])
        XCTAssertEqual(HashEditor.add(field: d("c"), value: d("9"), to: draft, overwrite: false), .confirmOverwrite(field: d("c")), "add asks too")
        XCTAssertEqual(HashEditor.add(field: d("c"), value: d("9"), to: draft, overwrite: true), .applied([row("a", "1"), row("b", "2"), row("c", "9")]))
    }
}
