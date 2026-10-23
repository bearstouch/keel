import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A string keyspace with TTLs and `MULTI/EXEC`: `SET` without `KEEPTTL` drops the TTL, as Redis does. Every frame of
/// a pipelined write is answered, so a save's `MULTI … EXEC` runs as on a server.
private final class StringServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var ttls: [String: Int64]
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    /// `STRLEN`'s answer in place of the real length, to stand for a value too big to hold in a test.
    var reportedLength: Int64?

    init(_ values: [String: String], ttls: [String: Int64] = [:]) { self.values = values; self.ttls = ttls }

    var commands: [[String]] { lock.withLock { sent } }
    func value(_ key: String) -> String? { lock.withLock { values[key] } }
    func ttl(_ key: String) -> Int64? { lock.withLock { ttls[key] } }

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
        var parser = RESPParser(limits: RESPLimits(maxReplyBytes: 128 * 1_024 * 1_024, maxDepth: 8, maxElements: 64))
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
            case "MULTI": queued = []; return "+OK\r\n"
            case "EXEC":
                defer { queued = nil }
                let commands = queued ?? []
                return "*\(commands.count)\r\n" + commands.map(run).joined()
            case "WATCH", "UNWATCH": return "+OK\r\n"
            default:
                if queued != nil { queued?.append(arguments); return "+QUEUED\r\n" }
                return run(arguments)
            }
        }
    }

    private func run(_ arguments: [String]) -> String {
        let key = arguments.count > 1 ? arguments[1] : ""
        switch arguments.first {
        case "STRLEN": return ":\(reportedLength ?? Int64(values[key]?.utf8.count ?? 0))\r\n"
        case "GET": return values[key].map(Self.bulk) ?? "$-1\r\n"
        case "GETRANGE":
            let bytes = Array((values[key] ?? "").utf8), start = Int(arguments[2])!, end = min(Int(arguments[3])!, bytes.count - 1)
            return Self.bulk(start <= end ? String(decoding: bytes[start...end], as: UTF8.self) : "")
        case "PTTL": return values[key] == nil ? ":-2\r\n" : ":\(ttls[key] ?? -1)\r\n"
        case "SET":
            values[key] = arguments[2]
            if !arguments.dropFirst(3).contains("KEEPTTL") { ttls[key] = nil }
            return "+OK\r\n"
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

final class StringEditorTests: XCTestCase {
    private let key = Data("blob".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))
    private static let mebibyte = 1_024 * 1_024

    /// AC1: a 2 MiB string loads its first 1 MiB with `GETRANGE` (never `GET`) and is marked partial; "Load all" reads it whole.
    func testPartialLoadDisablesEditing() async throws {
        let server = StringServer(["blob": String(repeating: "a", count: 2 * Self.mebibyte)])
        let service = server.service()
        let value = try await StringEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(value.partial, PartialLoad(loadedBytes: Int64(Self.mebibyte), totalBytes: Int64(2 * Self.mebibyte), canLoadAll: true))
        XCTAssertEqual(value.partial?.text, "Partial (1 MiB of 2 MiB)")
        XCTAssertEqual(value.rows.first?.value.count, Self.mebibyte)
        XCTAssertEqual(server.commands.map { $0.first ?? "" }, ["STRLEN", "GETRANGE"])
        XCTAssertEqual(server.commands.last, ["GETRANGE", "blob", "0", "1048575"])

        let whole = try await StringEditor.loadAll(key: key, service: service, context: context)
        XCTAssertNil(whole.partial, "fully loaded: editable")
        XCTAssertEqual(whole.rows.first?.value.count, 2 * Self.mebibyte)
        XCTAssertEqual(whole.watch.reads, [.get(key: key)])
    }

    func testSmallValueLoadsWhole() async throws {
        let server = StringServer(["blob": String(repeating: "b", count: Self.mebibyte)])
        let value = try await StringEditor.load(key: key, service: server.service(), context: context)
        XCTAssertNil(value.partial, "exactly 1 MiB still loads whole")
        XCTAssertEqual(server.commands.map { $0.first ?? "" }, ["STRLEN", "GET"])
    }

    /// Over the reply bound, "Load all" is not offered and refuses before reading the value.
    func testOverLimitIsNotLoadedWhole() async throws {
        let server = StringServer(["blob": String(repeating: "c", count: 2 * Self.mebibyte)])
        server.reportedLength = 96 * Int64(Self.mebibyte)
        let service = server.service()
        let value = try await StringEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(value.partial?.canLoadAll, false)
        XCTAssertEqual(value.partial?.text, "Partial (1 MiB of 96 MiB)")
        do {
            _ = try await StringEditor.loadAll(key: key, service: service, context: context)
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        XCTAssertEqual(server.commands.last?.first, "STRLEN", "refused before GET")
        XCTAssertLessThan(StringEditor.loadAllLimit, Int64(RESPLimits.standard.maxReplyBytes))
        XCTAssertEqual(PartialLoad.binary(96 * Int64(Self.mebibyte)), "96 MiB")
        XCTAssertEqual(PartialLoad.binary(1_536 * 1_024), "1.5 MiB")
        XCTAssertEqual(PartialLoad.binary(640 * 1_024), "640 KiB")
    }

    func testMissingKeyFailsLoad() async {
        let server = StringServer([:])
        do {
            _ = try await StringEditor.load(key: key, service: server.service(), context: context)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error, .invalidRequest("The key no longer exists.")) }
    }

    /// AC2: the save is `SET … KEEPTTL` inside `WATCH`/`MULTI`/`EXEC`, and the key's TTL survives it.
    func testSaveKeepsTTL() async throws {
        let server = StringServer(["blob": "old"], ttls: ["blob": 60_000])
        let service = server.service()
        let loaded = try await StringEditor.load(key: key, service: service, context: context)
        let draft = [EditorRow(id: Data(), value: Data("new".utf8))]
        let writes = StringEditor.writes(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(writes, [.stringSet(key: key, value: Data("new".utf8), keepTTL: true)])

        _ = try await service.executeTransaction(writes, unchanged: loaded.watch, context: context)
        XCTAssertTrue(server.commands.contains(["SET", "blob", "new", "KEEPTTL"]))
        XCTAssertEqual(Array(server.commands.map { $0.first ?? "" }.drop { $0 != "WATCH" }), ["WATCH", "GET", "MULTI", "SET", "EXEC"])
        XCTAssertEqual(server.value("blob"), "new")
        XCTAssertEqual(server.ttl("blob"), 60_000)
    }

    /// AC3: an unchanged draft yields no writes, so the shell sends nothing (and the service refuses an empty save).
    func testNoOpSaveSendsNothing() async throws {
        let server = StringServer(["blob": "same"])
        let service = server.service()
        let loaded = try await StringEditor.load(key: key, service: service, context: context)
        let before = server.commands.count
        let writes = StringEditor.writes(key: key, loaded: loaded.rows, draft: loaded.rows)
        XCTAssertTrue(writes.isEmpty)
        do {
            _ = try await service.executeTransaction(writes, unchanged: loaded.watch, context: context)
            XCTFail("an empty save is refused")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        XCTAssertEqual(server.commands.count, before, "nothing sent")
    }

    func testOnlyBuiltEditorsAreOffered() {
        XCTAssertNotNil(EditorBinding.editor(for: .string))
        XCTAssertNotNil(EditorBinding.editor(for: .hash))
        XCTAssertNil(EditorBinding.editor(for: .list))
        XCTAssertNil(EditorBinding.editor(for: .other))
    }
}
