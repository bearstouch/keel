import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// One set with `MULTI/EXEC` and `WATCH`: members keep insertion order, `SSCAN`'s cursor is an offset that returns
/// `scanBatch` members a round (COUNT by default), and `EXEC` replies nil when the set changed after `WATCH`.
final class SetServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var members: [String]
    private var version = 0
    private var watched: Int?
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    /// Members per `SSCAN` round in place of COUNT, for a server that answers rounds with fewer members.
    var scanBatch: Int?
    /// Answer `SMEMBERS` with RESP3's set type (`~`) instead of an array.
    var resp3Set = false

    init(_ members: [String]) { self.members = members }

    var commands: [[String]] { lock.withLock { sent } }
    var set: Set<String> { lock.withLock { Set(members) } }

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

    /// Another client's `SADD` / `SREM`.
    func write(_ arguments: [String]) { lock.withLock { _ = run(arguments) } }

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
                return run(arguments)
            }
        }
    }

    /// Called with `lock` held.
    private func run(_ arguments: [String]) -> String {
        switch arguments.first {
        case "SCARD": return ":\(members.count)\r\n"
        case "PTTL": return ":-1\r\n"
        case "SMEMBERS": return (resp3Set ? "~" : "*") + "\(members.count)\r\n" + members.map(Self.bulk).joined()
        case "SSCAN":
            let start = Int(arguments[2])!, count = scanBatch ?? Int(arguments[4])!
            let page = members[min(start, members.count)..<min(start + count, members.count)]
            let next = start + count >= members.count ? 0 : start + count
            return "*2\r\n" + Self.bulk(String(next)) + "*\(page.count)\r\n" + page.map(Self.bulk).joined()
        case "SISMEMBER": return members.contains(arguments[2]) ? ":1\r\n" : ":0\r\n"
        case "SADD":
            let new = arguments.dropFirst(2).filter { !members.contains($0) }
            members += new
            if !new.isEmpty { version += 1 }
            return ":\(new.count)\r\n"
        case "SREM":
            let removed = Set(arguments.dropFirst(2)), before = members.count
            members.removeAll { removed.contains($0) }
            if members.count != before { version += 1 }
            return ":\(before - members.count)\r\n"
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

final class SetEditorTests: XCTestCase {
    private let key = Data("s".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }
    private func row(_ member: String) -> EditorRow { SetEditor.row(d(member)) }
    private static func numbered(_ count: Int) -> [String] { (0..<count).map { "m\($0)" } }

    /// `SCARD` first: up to 1,000 members `SMEMBERS`, more than that the first `SSCAN … COUNT 500` page (never `SMEMBERS`).
    func testChoosesSMembersOrSScan() async throws {
        let small = SetServer(["red", "green", "blue"])
        let value = try await SetEditor.load(key: key, service: small.service(), context: context)
        XCTAssertEqual(small.commands, [["SCARD", "s"], ["SMEMBERS", "s"]])
        XCTAssertEqual(value.rows, [row("red"), row("green"), row("blue")])
        XCTAssertNil(value.next, "fully loaded")

        let limit = SetServer(Self.numbered(1_000))
        let whole = try await SetEditor.load(key: key, service: limit.service(), context: context)
        XCTAssertEqual(whole.rows.count, 1_000, "exactly 1,000 members still use SMEMBERS")
        XCTAssertEqual(limit.commands.map { $0[0] }, ["SCARD", "SMEMBERS"])

        let large = SetServer(Self.numbered(1_001))
        let first = try await SetEditor.load(key: key, service: large.service(), context: context)
        XCTAssertEqual(large.commands, [["SCARD", "s"], ["SSCAN", "s", "0", "COUNT", "500"]])
        XCTAssertEqual(first.rows.count, 500)
        XCTAssertEqual(first.next, d("500"))
    }

    /// AC2: a large set pages with `SSCAN` until the cursor comes back to 0.
    func testLargeSetPagesWithSScan() async throws {
        let server = SetServer(Self.numbered(1_200))
        let service = server.service()
        let first = try await SetEditor.load(key: key, service: service, context: context)
        let second = try await SetEditor.loadMore(key: key, cursor: try XCTUnwrap(first.next), service: service, context: context)
        XCTAssertEqual(second.rows.first, row("m500"))
        XCTAssertEqual(second.next, d("1000"))
        let last = try await SetEditor.loadMore(key: key, cursor: d("1000"), service: service, context: context)
        XCTAssertEqual(last.rows.count, 200)
        XCTAssertNil(last.next, "cursor 0: every member loaded")
        XCTAssertEqual(Set((first.rows + second.rows + last.rows).map(\.id)).count, 1_200)
        XCTAssertFalse(server.commands.contains { $0[0] == "SMEMBERS" })
    }

    /// A server that answers `SSCAN` rounds with few members: a page keeps scanning, but a bounded number of rounds.
    func testScanPageIsBounded() async throws {
        let sparse = SetServer(Self.numbered(5_000))
        sparse.scanBatch = 10
        let page = try await SetEditor.load(key: key, service: sparse.service(), context: context)
        XCTAssertEqual(sparse.commands.filter { $0[0] == "SSCAN" }.count, SetEditor.scanRounds)
        XCTAssertEqual(page.rows.count, 10 * SetEditor.scanRounds)
        XCTAssertNotNil(page.next)
    }

    /// AC1: `SADD` of a member already there returns 0, read as "already a member"; a new one returns 1.
    func testAddExistingReportsAlreadyMember() async throws {
        let server = SetServer(["red", "green"])
        let service = server.service()
        let existing = try await service.executeTransaction(SetEditor.add(d("red"), key: key), unchanged: nil, context: context)
        XCTAssertEqual(SetEditor.addOutcome(existing.reply), .alreadyMember)
        XCTAssertEqual(server.set, ["red", "green"])

        let new = try await service.executeTransaction(SetEditor.add(d("blue"), key: key), unchanged: nil, context: context)
        XCTAssertEqual(SetEditor.addOutcome(new.reply), .added)
        XCTAssertEqual(server.set, ["red", "green", "blue"])
        XCTAssertEqual(server.commands.filter { $0[0] == "SADD" }, [["SADD", "s", "red"], ["SADD", "s", "blue"]])
        XCTAssertNil(SetEditor.addOutcome(.error(d("WRONGTYPE"))), "anything but an integer reply is no outcome")
    }

    /// Removed members save as one `SREM`; the read-back drops only them and keeps the pages loaded.
    func testRemoveSavesOneSRemAndRereadKeepsPages() async throws {
        let server = SetServer(Self.numbered(1_200))
        let service = server.service()
        let loaded = try await SetEditor.load(key: key, service: service, context: context)
        let draft = loaded.rows.filter { $0.id != d("m3") && $0.id != d("m7") }
        let writes = SetEditor.writes(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(writes, [.setRemove(key: key, members: [d("m3"), d("m7")])])
        XCTAssertEqual(SetEditor.writes(key: key, loaded: loaded.rows, draft: loaded.rows), [], "nothing removed, nothing sent")

        _ = try await service.executeTransaction(writes, unchanged: loaded.watch, context: context)
        XCTAssertFalse(server.set.contains("m3"))
        let after = try await SetEditor.reread(key: key, loaded: loaded, draft: draft, service: service, context: context)
        XCTAssertEqual(after.rows, draft)
        XCTAssertEqual(after.next, loaded.next, "the scan continues where it was")
        XCTAssertEqual(server.commands.filter { $0[0] == "SISMEMBER" }, [["SISMEMBER", "s", "m3"], ["SISMEMBER", "s", "m7"]])
    }

    /// RESP3 answers `SMEMBERS` with a set type; an empty set means the key went away.
    func testReadsResp3SetAndMissingKey() async throws {
        let server = SetServer(["a", "b"])
        server.resp3Set = true
        let value = try await SetEditor.load(key: key, service: server.service(), context: context)
        XCTAssertEqual(value.rows, [row("a"), row("b")])

        do {
            _ = try await SetEditor.load(key: key, service: SetServer([]).service(), context: context)
            XCTFail("expected the key to be gone")
        } catch { XCTAssertEqual(error, EditorReads.gone) }
    }

    /// Read-only profiles refuse `SADD` before anything is sent.
    func testReadOnlyRefusesAdd() async {
        let server = SetServer(["a"])
        let readOnly = DataContext(profile: SafetyProfile(name: "prod", readOnly: true))
        do {
            _ = try await server.service().executeTransaction(SetEditor.add(d("b"), key: key), unchanged: nil, context: readOnly)
            XCTFail("expected a refusal")
        } catch { if case .refused = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(server.commands, [], "nothing sent")
    }
}
