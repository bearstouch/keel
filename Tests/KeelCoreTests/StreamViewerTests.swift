import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// One stream with `MULTI/EXEC`, answering `XRANGE` / `XREVRANGE` (`-`, `+`, inclusive and, with `exclusive`, `(`
/// bounds), `XLEN`, `XINFO STREAM` and `XADD` the way Redis does. `exclusive` false is a Redis 6.0 / 6.1, which refuses
/// `(` bounds (and the probe). `*` assigns `clock-0`, or the next sequence when the clock is behind the last entry.
final class StreamServer: Transport, @unchecked Sendable {
    typealias Entry = (ms: UInt64, seq: UInt64, fields: [(String, String)])
    private let lock = NSLock()
    private var entries: [Entry]
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    let exclusive: Bool
    var clock: UInt64 = 1_700_000_000_000

    init(_ entries: [Entry], exclusive: Bool = true) {
        self.entries = entries.sorted { ($0.ms, $0.seq) < ($1.ms, $1.seq) }; self.exclusive = exclusive
    }

    var commands: [[String]] { lock.withLock { sent } }
    /// The commands sent for the key itself (not the capability probe's key).
    var keyCommands: [[String]] { commands.filter { $0.count < 2 || !$0[1].hasPrefix("keel:probe:") } }
    var ids: [String] { lock.withLock { entries.map { "\($0.ms)-\($0.seq)" } } }

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
            case "WATCH", "UNWATCH": return "+OK\r\n"
            case "MULTI": queued = []; return "+OK\r\n"
            case "EXEC":
                defer { queued = nil }
                let commands = queued ?? []
                return "*\(commands.count)\r\n" + commands.map(run).joined()
            default:
                if queued != nil { queued?.append(arguments); return "+QUEUED\r\n" }
                return run(arguments)
            }
        }
    }

    private static func id(_ text: String) -> (UInt64, UInt64)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let ms = UInt64(parts[0]), let seq = UInt64(parts[1]) else { return nil }
        return (ms, seq)
    }

    /// Called with `lock` held.
    private func run(_ arguments: [String]) -> String {
        let invalid = "-ERR Invalid stream ID specified as stream command argument\r\n"
        /// A bound as (id, open); nil when this server can't read it.
        func bound(_ text: String) -> ((UInt64, UInt64), Bool)? {
            if text == "-" { return ((0, 0), false) }
            if text == "+" { return ((.max, .max), false) }
            if text.hasPrefix("(") { return exclusive ? Self.id(String(text.dropFirst())).map { ($0, true) } : nil }
            return Self.id(text).map { ($0, false) }
        }
        func range(low: String, high: String, reverse: Bool) -> String {
            guard let (lowID, lowOpen) = bound(low), let (highID, highOpen) = bound(high) else { return invalid }
            let count = Int(arguments[arguments.firstIndex(of: "COUNT")! + 1])!
            let inRange = entries.filter {
                let id = ($0.ms, $0.seq)
                return (id > lowID || (!lowOpen && id == lowID)) && (id < highID || (!highOpen && id == highID))
            }
            let page = (reverse ? Array(inRange.reversed()) : inRange).prefix(count)
            return "*\(page.count)\r\n" + page.map(Self.entry).joined()
        }
        if arguments.count > 1, arguments[1].hasPrefix("keel:probe:") { return exclusive ? "*0\r\n" : invalid }
        switch arguments.first {
        case "PTTL": return ":-1\r\n"
        case "XLEN": return ":\(entries.count)\r\n"
        case "XRANGE": return range(low: arguments[2], high: arguments[3], reverse: false)
        case "XREVRANGE": return range(low: arguments[3], high: arguments[2], reverse: true)
        case "XINFO":
            let first = entries.first.map(Self.entry) ?? "$-1\r\n", last = entries.last.map(Self.entry) ?? "$-1\r\n"
            return "*14\r\n" + Self.bulk("length") + ":\(entries.count)\r\n" + Self.bulk("radix-tree-keys") + ":1\r\n" + Self.bulk("radix-tree-nodes") + ":2\r\n"
                + Self.bulk("last-generated-id") + Self.bulk(entries.last.map { "\($0.ms)-\($0.seq)" } ?? "0-0") + Self.bulk("groups") + ":2\r\n"
                + Self.bulk("first-entry") + first + Self.bulk("last-entry") + last
        case "XADD":
            let top = entries.last.map { ($0.ms, $0.seq) } ?? (0, 0)
            let new: (UInt64, UInt64)
            if arguments[2] == "*" {
                new = clock > top.0 ? (clock, 0) : (top.0, top.1 + 1)
            } else {
                guard let id = Self.id(arguments[2]) else { return invalid }
                guard id > top else { return "-ERR The ID specified in XADD is equal or smaller than the target stream top item\r\n" }
                new = id
            }
            let rest = Array(arguments.dropFirst(3))
            entries.append((new.0, new.1, stride(from: 0, to: rest.count, by: 2).map { (rest[$0], rest[$0 + 1]) }))
            return Self.bulk("\(new.0)-\(new.1)")
        default: return "-ERR unexpected\r\n"
        }
    }

    private static func entry(_ entry: Entry) -> String {
        "*2\r\n" + bulk("\(entry.ms)-\(entry.seq)") + "*\(entry.fields.count * 2)\r\n" + entry.fields.map { bulk($0.0) + bulk($0.1) }.joined()
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

final class StreamViewerTests: XCTestCase {
    private let key = Data("s".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }
    private func words(_ operation: DataOperation?) -> [String]? { operation?.arguments.map { String(decoding: $0, as: UTF8.self) } }
    private func ids(_ rows: [EditorRow]) -> [String] { rows.map { String(decoding: $0.id, as: UTF8.self) } }

    /// 1,235 entries, three per millisecond, so page edges fall inside a millisecond and (newest first) on a sequence 0.
    private static let entries: [StreamServer.Entry] = (0..<1_235).map { (1_000 + UInt64($0 / 3), UInt64($0 % 3), [("n", "\($0)")]) }

    /// Every page until the end, in one direction.
    private func pageThrough(_ service: DataCommandService, descending: Bool) async throws -> [EditorRow] {
        var value = try await StreamEditor.load(key: key, descending: descending, service: service, context: context)
        var rows = value.rows
        while let next = value.next {
            let page = try await StreamEditor.loadMore(key: key, cursor: next, service: service, context: context)
            rows += page.rows; value.next = page.next
        }
        return rows
    }

    /// AC1: paging newest first and oldest first returns every entry exactly once, in order, on 6.2+ (exclusive `(id`
    /// bounds) and on 6.0 (the next possible ID as an inclusive bound, never a `(` the server would refuse).
    func testPagingWithoutDuplicates() async throws {
        for exclusive in [true, false] {
            let server = StreamServer(Self.entries, exclusive: exclusive)
            let service = server.service()
            let newest = try await pageThrough(service, descending: true)
            XCTAssertEqual(ids(newest), server.ids.reversed(), "newest first, exclusive \(exclusive)")
            let oldest = try await pageThrough(service, descending: false)
            XCTAssertEqual(ids(oldest), server.ids, "oldest first, exclusive \(exclusive)")
            XCTAssertEqual(StreamEditor.fields(of: oldest[7]), [DataOperation.FieldValue(field: d("n"), value: d("7"))])

            let pages = server.keyCommands.filter { ["XRANGE", "XREVRANGE"].contains($0[0]) }
            XCTAssertEqual(pages.count, 6, "three pages each way, the last one short")
            XCTAssertEqual(pages[0], ["XREVRANGE", "s", "+", "-", "COUNT", "500"], "newest first")
            // The 500th newest entry is 1245-0: the next page starts just below it.
            XCTAssertEqual(pages[1], ["XREVRANGE", "s", exclusive ? "(1245-0" : "1244-18446744073709551615", "-", "COUNT", "500"])
            XCTAssertEqual(pages[3], ["XRANGE", "s", "-", "+", "COUNT", "500"])
            XCTAssertEqual(pages[4], ["XRANGE", "s", exclusive ? "(1166-1" : "1166-2", "+", "COUNT", "500"])
            if !exclusive { XCTAssertFalse(pages.contains { $0[2].hasPrefix("(") }, "Redis 6.0 never gets an exclusive range") }
            XCTAssertEqual(server.commands.filter { $0.count > 1 && $0[1].hasPrefix("keel:probe:") }.count, 1, "probed once per session")
        }
    }

    /// 6.0 / 6.1 fallback: the next possible ID past the last one loaded, crossing into the neighbouring millisecond when
    /// the sequence runs out; nothing past the smallest or largest ID, so no page is read there.
    func testIdIncrementFallback() async throws {
        func bound(_ id: String, descending: Bool, exclusive: Bool = false) -> String? {
            StreamEditor.bound(after: d(id), descending: descending, exclusive: exclusive).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(bound("5-3", descending: false), "5-4")
        XCTAssertEqual(bound("5-18446744073709551615", descending: false), "6-0")
        XCTAssertNil(bound("18446744073709551615-18446744073709551615", descending: false))
        XCTAssertEqual(bound("5-3", descending: true), "5-2")
        XCTAssertEqual(bound("5-0", descending: true), "4-18446744073709551615")
        XCTAssertNil(bound("0-0", descending: true))
        XCTAssertEqual(bound("5-0", descending: true, exclusive: true), "(5-0")
        XCTAssertNil(bound("0-0", descending: true, exclusive: true), "(0-0 going down is an empty range")
        for invalid in ["5", "-1-0", "+5-0", "a-b", "5-0-1", ""] { XCTAssertNil(bound(invalid, descending: false), invalid) }

        let cursor = StreamEditor.Cursor(descending: true, lastID: d("7-0"))
        XCTAssertEqual(StreamEditor.Cursor(cursor.data), cursor)
        XCTAssertNil(StreamEditor.Cursor(d("x 7-0")))
        XCTAssertEqual(words(StreamEditor.pageOperation(key: key, after: cursor, exclusive: false)), ["XREVRANGE", "s", "6-18446744073709551615", "-", "COUNT", "500"])

        // The oldest possible entry was the last one loaded: the end, without a read.
        let server = StreamServer([(0, 0, [("a", "1")])], exclusive: false)
        let page = try await StreamEditor.loadMore(
            key: key, cursor: StreamEditor.Cursor(descending: true, lastID: d("0-0")).data, service: server.service(), context: context)
        XCTAssertEqual(page, EditorPage(rows: [], next: nil))
        XCTAssertFalse(server.keyCommands.contains { $0[0] == "XREVRANGE" })
    }

    /// Add entry: one `XADD key id field value …` with `*` or an explicit ID, run in the shell's transaction; the reply's
    /// ID is the new entry, which the newest-first read-back shows at the top (AC2). A smaller explicit ID is the server's
    /// error, and nothing is added.
    func testAddEntryBuildsXAdd() async throws {
        let fields = [DataOperation.FieldValue(field: d("event"), value: d("login")), DataOperation.FieldValue(field: d("user"), value: d("ann\n"))]
        let auto = StreamEditor.add(id: StreamEditor.autoID, fields: fields, key: key)
        XCTAssertEqual(auto, [.streamAdd(key: key, id: d("*"), fields: fields)])
        XCTAssertEqual(words(auto[0]), ["XADD", "s", "*", "event", "login", "user", "ann\n"])
        XCTAssertEqual(words(StreamEditor.add(id: d("5-1"), fields: fields, key: key)[0]), ["XADD", "s", "5-1", "event", "login", "user", "ann\n"])

        let server = StreamServer([(1_000, 0, [("a", "1")])])
        let service = server.service()
        let result = try await service.executeTransaction(auto, unchanged: nil, context: context)
        XCTAssertEqual(StreamEditor.addedID(result.reply), d("1700000000000-0"))
        let value = try await StreamEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(ids(value.rows), ["1700000000000-0", "1000-0"], "the new entry at the top")
        XCTAssertEqual(StreamEditor.fields(of: value.rows[0]), fields, "bytes kept exactly")

        let refused = try await service.executeTransaction(StreamEditor.add(id: d("5-1"), fields: fields, key: key), unchanged: nil, context: context)
        XCTAssertNil(StreamEditor.addedID(refused.reply))
        XCTAssertEqual(server.ids, ["1000-0", "1700000000000-0"])
        XCTAssertNil(StreamEditor.addedID(.array([.error(d("ERR"))])))
    }

    /// AC3: entries are read-only: a save writes nothing whatever the draft says, and the viewer never edits.
    func testEntriesAreReadOnly() async throws {
        let loaded = [StreamEditor.row(d("1-0"), fields: [.init(field: d("a"), value: d("1"))])]
        let edited = [StreamEditor.row(d("1-0"), fields: [.init(field: d("a"), value: d("2"))])]
        XCTAssertEqual(StreamEditor.writes(key: key, loaded: loaded, draft: edited), [])
        XCTAssertEqual(StreamEditor.writes(key: key, loaded: loaded, draft: []), [], "never XDEL")
        XCTAssertFalse(StreamEditor.binding.editsValues)
        XCTAssertNotNil(EditorBinding.editor(for: .stream))
    }

    /// Field packing keeps every byte, empty and binary parts included; foreign bytes don't parse.
    func testFieldPackingRoundTrip() {
        let fields = [DataOperation.FieldValue(field: Data(), value: Data([0, 0xFF, 0x3A])), .init(field: d("10:x"), value: Data())]
        XCTAssertEqual(StreamEditor.fields(of: StreamEditor.row(d("1-0"), fields: fields)), fields)
        XCTAssertEqual(StreamEditor.fields(of: StreamEditor.row(d("1-0"), fields: [])), [])
        XCTAssertNil(StreamEditor.fields(of: EditorRow(id: d("1-0"), value: d("5:ab"))))
        XCTAssertNil(StreamEditor.fields(of: EditorRow(id: d("1-0"), value: d("1:a"))), "a field without its value")
        XCTAssertTrue(StreamEditor.precedes(d("9-5"), d("10-0")))
        XCTAssertTrue(StreamEditor.precedes(d("10-2"), d("10-10")))
    }

    /// Details: the `XINFO STREAM` summary (RESP2 array or RESP3 map) and its line.
    func testStreamSummaryInDetails() async throws {
        let server = StreamServer([(1, 0, [("a", "1")]), (1_700_000_000_000, 3, [("b", "2")])])
        let details = await KeyDetails.load(key: key, memory: false, stream: true, service: server.service(), context: context)
        XCTAssertEqual(details.stream, .value(StreamSummary(length: 2, firstID: d("1-0"), lastID: d("1700000000000-3"), groups: 2)))
        XCTAssertEqual(details.streamText, "2 entries · first 1-0 · last 1700000000000-3 · 2 groups")
        let map = RESPValue.map([RESPPair(.bulkString(d("length")), .integer(0)), RESPPair(.bulkString(d("groups")), .integer(1)), RESPPair(.bulkString(d("first-entry")), .null)])
        XCTAssertEqual(StreamSummary(map), StreamSummary(length: 0, firstID: nil, lastID: nil, groups: 1))
        XCTAssertNil(StreamSummary(.error(d("ERR no such key"))))
        let other = await KeyDetails.load(key: key, memory: false, service: server.service(), context: context)
        XCTAssertNil(other.streamText, "only streams ask XINFO")
    }
}
