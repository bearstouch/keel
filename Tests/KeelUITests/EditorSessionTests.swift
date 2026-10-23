import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// An in-memory string keyspace with real transaction semantics: `WATCH` remembers each key's version, `MULTI`
/// queues, and `EXEC` replies nil when a watched key changed. "Another client" changes keys with `set(_:_:)`.
/// Frames are parsed from every chunk, so pipelined `MULTI … EXEC` arrives as the server would see it.
final class TransactionalKeyspace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    /// Hash keys: fields in insertion order; `HSCAN`'s cursor is an offset.
    private var hashes: [String: [(String, String)]] = [:]
    private var versions: [String: Int] = [:]
    private var sent: [[String]] = []
    /// Another client's write, made right after the save's guard read (between `GET` and `EXEC`).
    var changeAfterGuardRead: (key: String, value: String)?

    init(_ values: [String: String]) { self.values = values }
    init(hashes: [String: [(String, String)]]) { values = [:]; self.hashes = hashes }

    func hash(_ key: String) -> [String: String]? { lock.withLock { hashes[key].map { Dictionary($0, uniquingKeysWith: { a, _ in a }) } } }
    /// Another client's `HSET`.
    func hset(_ key: String, _ field: String, _ value: String) {
        lock.withLock {
            setField(key, field, value); versions[key, default: 0] += 1
        }
    }
    private func setField(_ key: String, _ field: String, _ value: String) {
        var fields = hashes[key] ?? []
        if let index = fields.firstIndex(where: { $0.0 == field }) { fields[index].1 = value } else { fields.append((field, value)) }
        hashes[key] = fields
    }

    func set(_ key: String, _ value: String) {
        lock.withLock {
            values[key] = value; versions[key, default: 0] += 1
        }
    }
    func value(_ key: String) -> String? { lock.withLock { values[key] } }
    var commands: [[String]] { lock.withLock { sent } }
    var commandNames: [String] { commands.compactMap(\.first) }

    @MainActor func session(_ key: String, type: KeyType = .string, readOnly: Bool = false) -> EditorSession {
        let server = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: Transport(self))
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "")
            }
            return connection
        }
        let context = DataContext(profile: SafetyProfile(name: readOnly ? "payments-prod" : "local", readOnly: readOnly))
        return EditorSession(key: Data(key.utf8), type: type, binding: EditorBinding.editor(for: type), service: DataCommandService(session: server), context: context)
    }

    /// The string editor (KEEL-029): `STRLEN`, then `GET` (or `GETRANGE` over 1 MiB); `GET` guards, `SET … KEEPTTL` saves.
    static let stringBinding = StringEditor.binding

    /// One connection's view: its watched versions and queued commands.
    final class Transport: KeelRESP.Transport, @unchecked Sendable {
        private let keyspace: TransactionalKeyspace
        private let lock = NSLock()
        private var watched: [String: Int]?
        private var queued: [[String]]?
        private var pending: [Data] = []
        private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
        private var cancelled = false

        init(_ keyspace: TransactionalKeyspace) { self.keyspace = keyspace }

        func connect() async throws(TransportError) {}

        func send(_ data: Data) {
            var parser = RESPParser()
            parser.append(data)
            var reply = ""
            while case .array(let items)? = try? parser.next() {
                let arguments = items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }
                reply += answer(arguments)
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
            keyspace.lock.withLock { keyspace.sent.append(arguments) }
            let name = arguments.first ?? ""
            if queued != nil, !["EXEC", "MULTI", "WATCH"].contains(name) {
                queued?.append(arguments)
                return "+QUEUED\r\n"
            }
            switch name {
            case "WATCH":
                let version = keyspace.lock.withLock { keyspace.versions[arguments[1], default: 0] }
                watched = (watched ?? [:]).merging([arguments[1]: version]) { $1 }
                return "+OK\r\n"
            case "UNWATCH": watched = nil; return "+OK\r\n"
            case "MULTI": queued = []; return "+OK\r\n"
            case "EXEC":
                let commands = queued ?? []
                queued = nil
                defer { watched = nil }
                let changed = keyspace.lock.withLock { (watched ?? [:]).contains { keyspace.versions[$0.key, default: 0] != $0.value } }
                if changed { return "*-1\r\n" }
                return "*\(commands.count)\r\n" + commands.map(run).joined()
            default:
                let reply = run(arguments)
                if name == "GET", watched != nil, let change = keyspace.changeAfterGuardRead {
                    keyspace.changeAfterGuardRead = nil
                    keyspace.set(change.key, change.value)
                }
                return reply
            }
        }

        private func run(_ arguments: [String]) -> String {
            keyspace.lock.withLock {
                switch arguments.first {
                case "GET": return keyspace.values[arguments[1]].map { "$\($0.utf8.count)\r\n\($0)\r\n" } ?? "$-1\r\n"
                case "SET":
                    keyspace.values[arguments[1]] = arguments[2]; keyspace.versions[arguments[1], default: 0] += 1
                    return "+OK\r\n"
                case "PTTL": return keyspace.values[arguments[1]] == nil && keyspace.hashes[arguments[1]] == nil ? ":-2\r\n" : ":-1\r\n"
                case "HLEN": return ":\(keyspace.hashes[arguments[1]]?.count ?? 0)\r\n"
                case "HGETALL":
                    let fields = keyspace.hashes[arguments[1]] ?? []
                    return "*\(fields.count * 2)\r\n" + fields.map { Self.bulk($0.0) + Self.bulk($0.1) }.joined()
                case "HSCAN":
                    let fields = keyspace.hashes[arguments[1]] ?? [], start = Int(arguments[2])!, count = Int(arguments[4])!
                    let page = fields[min(start, fields.count)..<min(start + count, fields.count)]
                    let next = start + count >= fields.count ? 0 : start + count
                    return "*2\r\n" + Self.bulk(String(next)) + "*\(page.count * 2)\r\n" + page.map { Self.bulk($0.0) + Self.bulk($0.1) }.joined()
                case "HGET": return keyspace.hashes[arguments[1]]?.first { $0.0 == arguments[2] }.map { Self.bulk($0.1) } ?? "$-1\r\n"
                case "HSET":
                    keyspace.setField(arguments[1], arguments[2], arguments[3]); keyspace.versions[arguments[1], default: 0] += 1
                    return ":1\r\n"
                case "HDEL":
                    let removed = Set(arguments.dropFirst(2))
                    keyspace.hashes[arguments[1]]?.removeAll { removed.contains($0.0) }
                    if keyspace.hashes[arguments[1]]?.isEmpty == true { keyspace.hashes[arguments[1]] = nil }
                    keyspace.versions[arguments[1], default: 0] += 1
                    return ":\(removed.count)\r\n"
                case "STRLEN": return ":\(keyspace.values[arguments[1]]?.utf8.count ?? 0)\r\n"
                case "GETRANGE":
                    let bytes = Array((keyspace.values[arguments[1]] ?? "").utf8), end = min(Int(arguments[3])!, bytes.count - 1)
                    let text = end >= 0 ? String(decoding: bytes[0...end], as: UTF8.self) : ""
                    return "$\(text.utf8.count)\r\n\(text)\r\n"
                default: return "-ERR unexpected\r\n"
                }
            }
        }

        private static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }

        func receive() async throws(TransportError) -> Data {
            let result = await withCheckedContinuation { waiter in
                let ready: Result<Data, TransportError>? = lock.withLock {
                    if !pending.isEmpty { return .success(pending.removeFirst()) }
                    if cancelled { return .failure(.cancelled) }
                    receiver = waiter
                    return nil
                }
                if let ready { waiter.resume(returning: ready) }
            }
            return try result.get()
        }

        func cancel() {
            let waiter = lock.withLock {
                defer { cancelled = true; receiver = nil }
                return receiver
            }
            waiter?.resume(returning: .failure(.cancelled))
        }
    }
}

private func row(_ text: String) -> [EditorRow] { [EditorRow(id: Data(), value: Data(text.utf8))] }

final class EditorSessionTests: XCTestCase {
    @MainActor func testDirtyStateDrivesSaveBar() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting")
        await editor.load()
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertEqual(editor.header.metadataLine, "No expiry · 5 bytes")
        XCTAssertFalse(editor.showsSaveBar)

        editor.update(row("hello, world"))
        XCTAssertTrue(editor.showsSaveBar)
        XCTAssertEqual(editor.saveBarText, "1 unsaved change")
        XCTAssertEqual(editor.changedRows, [Data()])

        // Typing the loaded value back is no change: the bar goes away.
        editor.update(row("hello"))
        XCTAssertFalse(editor.showsSaveBar)

        editor.update(row("hi"))
        await editor.save()
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertFalse(editor.showsSaveBar, "saved: nothing left unsaved")
        XCTAssertEqual(server.value("greeting"), "hi")
        XCTAssertEqual(editor.loaded?.rows, row("hi"))
        // Guarded whole-value save: WATCH, the guard read, then MULTI / SET KEEPTTL / EXEC.
        XCTAssertTrue(server.commands.contains(["SET", "greeting", "hi", "KEEPTTL"]))
        let tail = Array(server.commandNames.drop { $0 != "WATCH" }.prefix(5))
        XCTAssertEqual(tail, ["WATCH", "GET", "MULTI", "SET", "EXEC"])
    }

    @MainActor func testWatchConflictReported() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting")
        await editor.load()
        editor.update(row("mine"))

        // Another client changes the key between load and save: the guard read differs, nothing is queued.
        server.set("greeting", "theirs")
        await editor.save()
        XCTAssertEqual(editor.phase, .conflict)
        XCTAssertEqual(server.value("greeting"), "theirs")
        XCTAssertFalse(server.commandNames.contains("MULTI"))
        XCTAssertTrue(server.commandNames.contains("UNWATCH"))
        XCTAssertTrue(editor.showsSaveBar, "the draft stays for Reload or Overwrite")

        // Reload takes the server's value and drops the draft.
        await editor.reload()
        XCTAssertEqual(editor.loaded?.rows, row("theirs"))
        XCTAssertFalse(editor.showsSaveBar)
    }

    @MainActor func testChangeAfterGuardReadIsConflictAndOverwriteWins() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting")
        await editor.load()
        editor.update(row("mine"))

        // The change lands after the guard read but before EXEC: WATCH makes EXEC run nothing.
        server.changeAfterGuardRead = ("greeting", "theirs")
        await editor.save()
        XCTAssertEqual(editor.phase, .conflict)
        XCTAssertEqual(server.value("greeting"), "theirs", "nothing is overwritten unless the user chooses Overwrite")

        await editor.overwrite()
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertEqual(server.value("greeting"), "mine")
        XCTAssertFalse(editor.showsSaveBar)
    }

    @MainActor func testRevertRestoresLoadedValue() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting")
        await editor.load()
        editor.update(row("changed"))
        XCTAssertTrue(editor.hasUnsavedChanges)

        editor.revert()
        XCTAssertEqual(editor.draft, row("hello"))
        XCTAssertFalse(editor.showsSaveBar)
        XCTAssertFalse(server.commandNames.contains("SET"), "revert sends nothing")
    }

    @MainActor func testReadOnlyDisablesWrites() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting", readOnly: true)
        await editor.load()
        XCTAssertFalse(editor.allowsWrites)
        XCTAssertEqual(editor.header.metadataLine, "No expiry · 5 bytes · Read-only")

        editor.update(row("changed"))
        XCTAssertFalse(editor.showsSaveBar)
        await editor.save()
        await editor.overwrite()
        let loads = server.commandNames
        XCTAssertFalse(loads.contains { ["WATCH", "MULTI", "SET", "EXEC"].contains($0) }, "a read-only editor sends no writes")

        // The service refuses too, before anything is sent.
        do {
            _ = try await editor.service.executeTransaction(
                [.stringSet(key: Data("greeting".utf8), value: Data("x".utf8), keepTTL: true)], unchanged: nil, context: editor.context)
            XCTFail("expected READ_ONLY")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        XCTAssertEqual(server.commandNames, loads)
        XCTAssertEqual(server.value("greeting"), "hello")
    }
}
