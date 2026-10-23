import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Redis's list commands over an array, as both fake servers run them. Indexes may be negative (from the tail).
enum ListCommands {
    static func run(_ arguments: [String], on items: inout [String]) -> String {
        func position(_ text: String) -> Int { let index = Int(text)!; return index < 0 ? items.count + index : index }
        switch arguments.first {
        case "LLEN": return ":\(items.count)\r\n"
        case "LRANGE":
            let start = max(position(arguments[2]), 0), stop = min(position(arguments[3]), items.count - 1)
            let page = start <= stop ? Array(items[start...stop]) : []
            return "*\(page.count)\r\n" + page.map(bulk).joined()
        case "LSET":
            let index = position(arguments[2])
            guard items.indices.contains(index) else { return "-ERR index out of range\r\n" }
            items[index] = arguments[3]
            return "+OK\r\n"
        case "LREM":
            // Count 1 only: the editor's delete.
            guard let index = items.firstIndex(of: arguments[3]) else { return ":0\r\n" }
            items.remove(at: index)
            return ":1\r\n"
        case "LPUSH": items.insert(contentsOf: arguments.dropFirst(2).reversed(), at: 0); return ":\(items.count)\r\n"
        case "RPUSH": items += arguments.dropFirst(2); return ":\(items.count)\r\n"
        case "LPOP": return items.isEmpty ? "$-1\r\n" : bulk(items.removeFirst())
        case "RPOP": return items.isEmpty ? "$-1\r\n" : bulk(items.removeLast())
        case "LINSERT":
            guard let pivot = items.firstIndex(of: arguments[3]) else { return ":-1\r\n" }
            items.insert(arguments[4], at: arguments[2] == "BEFORE" ? pivot : pivot + 1)
            return ":\(items.count)\r\n"
        default: return "-ERR unexpected\r\n"
        }
    }

    static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }
}

/// One list with `MULTI/EXEC` and `WATCH`: `EXEC` replies nil when the list changed after `WATCH`.
final class ListServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]
    private var version = 0
    private var watched: Int?
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?

    init(_ items: [String]) { self.items = items }

    var commands: [[String]] { lock.withLock { sent } }
    var list: [String] { lock.withLock { items } }

    /// Another client's write.
    func external(_ arguments: [String]) {
        lock.withLock {
            _ = ListCommands.run(arguments, on: &items); version += 1
        }
    }

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
        while case .array(let parts)? = try? parser.next() {
            reply += answer(parts.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } })
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
                return run(arguments)
            }
        }
    }

    private func run(_ arguments: [String]) -> String {
        if arguments.first == "PTTL" { return ":-1\r\n" }
        if !["LLEN", "LRANGE"].contains(arguments.first) { version += 1 }
        return ListCommands.run(arguments, on: &items)
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
}

final class ListEditorTests: XCTestCase {
    private let key = Data("q".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }
    private static func numbered(_ count: Int) -> [String] { (0..<count).map { "item\($0)" } }

    /// Saves `draft` as the shell does: the binding's writes under its guard, in one transaction.
    private func save(_ loaded: LoadedValue, _ draft: [EditorRow], _ service: DataCommandService) async throws(DataCommandError) {
        let writes = ListEditor.writes(key: key, loaded: loaded.rows, draft: draft)
        _ = try await service.executeTransaction(writes, unchanged: ListEditor.saveGuard(key: key, loaded: loaded.rows, draft: draft), context: context)
    }

    /// `LLEN`, then `LRANGE` pages of 500 (one extra item tells whether more follow); Load more and Jump to index
    /// continue from any index, and rows are named by their index.
    func testPagesWithLRange() async throws {
        let server = ListServer(Self.numbered(1_200))
        let service = server.service()
        let first = try await ListEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(server.commands, [["LLEN", "q"], ["LRANGE", "q", "0", "500"]])
        XCTAssertEqual(first.rows.count, 500)
        XCTAssertEqual(first.rows.first, EditorRow(id: d("0"), value: d("item0")))
        XCTAssertEqual(first.rows.last?.id, d("499"))
        XCTAssertEqual(first.next, d("500"))

        let second = try await ListEditor.loadMore(key: key, cursor: d("500"), service: service, context: context)
        XCTAssertEqual(second.rows.first, EditorRow(id: d("500"), value: d("item500")))
        XCTAssertEqual(second.next, d("1000"))
        let last = try await ListEditor.loadMore(key: key, cursor: d("1000"), service: service, context: context)
        XCTAssertEqual(last.rows.count, 200)
        XCTAssertNil(last.next, "the end of the list")

        let jumped = try await ListEditor.load(key: key, from: 1_150, service: service, context: context)
        XCTAssertEqual(jumped.rows.map(\.id), (1_150..<1_200).map(ListEditor.rowID))
        XCTAssertNil(jumped.next)
        do {
            _ = try await ListEditor.load(key: key, from: 1_200, service: service, context: context)
            XCTFail("past the end")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }

        let exact = ListServer(Self.numbered(500))
        let whole = try await ListEditor.load(key: key, service: exact.service(), context: context)
        XCTAssertEqual(whole.rows.count, 500)
        XCTAssertNil(whole.next, "exactly one page: no empty Load more")
    }

    /// AC1: deleting index 3 of 10 items leaves 9 in their order: `LSET 3 sentinel` + `LREM 1 sentinel` in one MULTI.
    func testDeleteByIndexPreservesOrder() async throws {
        // Duplicates around index 3, so a delete by value would take the wrong one.
        let items = ["a", "b", "c", "b", "e", "f", "g", "h", "i", "j"]
        let server = ListServer(items)
        let service = server.service()
        let loaded = try await ListEditor.load(key: key, service: service, context: context)
        let draft = loaded.rows.filter { $0.id != d("3") }
        try await save(loaded, draft, service)

        var expected = items
        expected.remove(at: 3)
        XCTAssertEqual(server.list, expected)
        let transaction = Array(server.commands.drop { $0[0] != "WATCH" })
        XCTAssertEqual(transaction.map { $0[0] }, ["WATCH", "LRANGE", "MULTI", "LSET", "LREM", "EXEC"])
        XCTAssertEqual(transaction[1], ["LRANGE", "q", "3", "3"], "the touched span is guarded")
        XCTAssertEqual(transaction[3][2], "3")
        XCTAssertEqual(transaction[4][2], "1", "LREM 1")
        XCTAssertEqual(transaction[3][3], transaction[4][3], "LREM removes the sentinel LSET put in")

        // An edit and two deletes in one save: every LSET runs before the LREMs, so the indexes stay the loaded ones.
        let reloaded = try await ListEditor.reread(key: key, loaded: loaded, draft: draft, service: service, context: context)
        XCTAssertEqual(reloaded.rows.map { String(decoding: $0.value, as: UTF8.self) }, expected)
        var edited = reloaded.rows.filter { $0.id != d("0") && $0.id != d("8") }
        edited[1].value = d("C")
        try await save(reloaded, edited, service)
        XCTAssertEqual(server.list, ["b", "C", "e", "f", "g", "h", "i"])
    }

    /// AC2: a list changed elsewhere since the page loaded (an item pushed at the head shifts every index) is a
    /// `CONFLICT`; nothing is written. A change past the touched span doesn't block the save.
    func testIndexEditConflict() async throws {
        let server = ListServer(["a", "b", "c", "d"])
        let service = server.service()
        let loaded = try await ListEditor.load(key: key, service: service, context: context)
        var draft = loaded.rows
        draft[1].value = d("B")
        server.external(["LPUSH", "q", "z"])
        do {
            try await save(loaded, draft, service)
            XCTFail("expected a conflict")
        } catch { XCTAssertEqual(error, .conflict) }
        XCTAssertEqual(server.list, ["z", "a", "b", "c", "d"], "nothing written")

        let deleting = loaded.rows.filter { $0.id != d("2") }
        do {
            try await save(loaded, deleting, service)
            XCTFail("expected a conflict")
        } catch { XCTAssertEqual(error.code, "CONFLICT") }
        XCTAssertFalse(server.commands.contains { $0[0] == "LREM" }, "a refused delete sends no write")

        let other = ListServer(["a", "b", "c", "d"])
        let fresh = try await ListEditor.load(key: key, service: other.service(), context: context)
        var change = fresh.rows
        change[1].value = d("B")
        other.external(["RPUSH", "q", "e"])
        try await save(fresh, change, other.service())
        XCTAssertEqual(other.list, ["a", "B", "c", "d", "e"], "a push at the tail doesn't move index 1")
    }

    /// Every delete and every insert gets a sentinel of its own, which no stored value can be mistaken for.
    func testSentinelIsUniquePerOperation() {
        let rows = (0..<4).map { EditorRow(id: ListEditor.rowID($0), value: d("v\($0)")) }
        let draft = [rows[0], rows[3]]
        let first = ListEditor.writes(key: key, loaded: rows, draft: draft)
        let second = ListEditor.writes(key: key, loaded: rows, draft: draft)
        func sentinels(_ writes: [DataOperation]) -> [Data] {
            writes.compactMap { if case .listRemove(_, 1, let value) = $0 { value } else { nil } }
        }
        XCTAssertEqual(sentinels(first).count, 2)
        XCTAssertEqual(Set(sentinels(first)).count, 2, "two deletes, two sentinels")
        XCTAssertTrue(Set(sentinels(first)).isDisjoint(with: sentinels(second)), "a new sentinel every save")
        XCTAssertFalse(sentinels(first).contains { rows.map(\.value).contains($0) })
        XCTAssertEqual(first.prefix(2), [.listSet(key: key, index: 1, value: sentinels(first)[0]), .listSet(key: key, index: 2, value: sentinels(first)[1])])

        let insertA = ListEditor.insert(d("x"), key: key, at: 1, before: true, loaded: rows)
        let insertB = ListEditor.insert(d("x"), key: key, at: 1, before: true, loaded: rows)
        guard case .listSet(_, _, let pivotA)? = insertA?.writes.first, case .listSet(_, _, let pivotB)? = insertB?.writes.first else {
            return XCTFail("inserts pivot on a sentinel")
        }
        XCTAssertNotEqual(pivotA, pivotB)
    }
}
