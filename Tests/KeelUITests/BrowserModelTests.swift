import AppKit
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// An in-memory server for the browser: a keyspace per database that "another client" changes between calls,
/// answering `SCAN` (one page, `MATCH` applied), `TYPE`, `DBSIZE`, `SET … NX` and `INFO keyspace` for the connection's database.
final class BrowserKeyspace: @unchecked Sendable {
    private let lock = NSLock()
    private var databases: [Int: Set<String>]
    private var sent: [(Int, [String])] = []

    init(_ databases: [Int: Set<String>]) { self.databases = databases }

    func add(_ key: String, in database: Int = 0) { lock.withLock { _ = databases[database, default: []].insert(key) } }
    func delete(_ key: String, in database: Int = 0) { lock.withLock { _ = databases[database]?.remove(key) } }
    /// Commands sent, with the database of their connection.
    var commands: [(database: Int, arguments: [String])] { lock.withLock { sent.map { ($0.0, $0.1) } } }

    @MainActor func list(database: Int = 0, readOnly: Bool = true) -> KeyListDataSource {
        let session = ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: FakeTransport { self.answer(database, $0) })
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "")
            }
            return connection
        }
        let context = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: readOnly), database: database)
        return KeyListDataSource(index: KeyIndex(service: DataCommandService(session: session), context: context))
    }

    private func answer(_ database: Int, _ arguments: [String]) -> String {
        lock.withLock {
            sent.append((database, arguments))
            let keys = databases[database] ?? []
            switch arguments.first {
            case "SCAN":
                let match = arguments.firstIndex(of: "MATCH").map { Data(arguments[$0 + 1].utf8) }
                let listed = keys.filter { key in match.map { GlobPattern.matches($0, Data(key.utf8)) } ?? true }.sorted()
                return "*2\r\n$1\r\n0\r\n*\(listed.count)\r\n" + listed.map { "$\($0.utf8.count)\r\n\($0)\r\n" }.joined()
            case "TYPE": return keys.contains(arguments[1]) ? "+string\r\n" : "+none\r\n"
            case "DBSIZE": return ":\(keys.count)\r\n"
            case "PTTL": return keys.contains(arguments[1]) ? ":-1\r\n" : ":-2\r\n"
            case "RENAMENX", "RENAME":
                guard keys.contains(arguments[1]) else { return "-ERR no such key\r\n" }
                if arguments[0] == "RENAMENX", keys.contains(arguments[2]) { return ":0\r\n" }
                databases[database]?.remove(arguments[1]); databases[database]?.insert(arguments[2])
                return arguments[0] == "RENAME" ? "+OK\r\n" : ":1\r\n"
            case "SET":
                // The new-key sheet's `SET key value NX`: nil when the name is taken.
                if arguments.contains("NX"), keys.contains(arguments[1]) { return "$-1\r\n" }
                databases[database, default: []].insert(arguments[1])
                return "+OK\r\n"
            case "UNLINK":
                let removed = arguments.dropFirst().filter { databases[database]?.remove($0) != nil }.count
                return ":\(removed)\r\n"
            case "INFO":
                let lines = databases.keys.sorted().compactMap { db in databases[db].flatMap { $0.isEmpty ? nil : "db\(db):keys=\($0.count),expires=0,avg_ttl=0" } }
                let text = (["# Keyspace"] + lines).joined(separator: "\r\n") + "\r\n"
                return "$\(text.utf8.count)\r\n\(text)\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
    }
}

/// Answers each command frame at once with `answer(arguments)`.
private final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    private var cancelled = false
    private let answer: @Sendable ([String]) -> String

    init(answer: @escaping @Sendable ([String]) -> String) { self.answer = answer }

    func connect() async throws(TransportError) {}

    func send(_ data: Data) {
        var parser = RESPParser()
        parser.append(data)
        let arguments: [String]
        if case .array(let items)? = try? parser.next() {
            arguments = items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }
        } else {
            arguments = []
        }
        let reply = Data(answer(arguments).utf8)
        let waiter: CheckedContinuation<Result<Data, TransportError>, Never>? = lock.withLock {
            if let receiver { self.receiver = nil; return receiver }
            pending.append(reply)
            return nil
        }
        waiter?.resume(returning: .success(reply))
    }

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

final class BrowserModelTests: XCTestCase {
    @MainActor func testRefreshShowsNewKeysWithDbsizeAndKeepsSelection() async throws {
        let server = BrowserKeyspace([0: ["user:1", "user:2", "order:1"], 2: ["a"]])
        let list = server.list()
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        XCTAssertEqual(list.footer.text, "All keys loaded")
        XCTAssertEqual(list.totalKeys, 3)
        XCTAssertEqual(model.databases.entry(0)?.title, "db0 · 3 keys")
        XCTAssertEqual(model.databases.entry(2)?.title, "db2 · 1 key")

        let selectedIndex = await list.index.index(of: Data("user:2".utf8))
        await list.select(key: try XCTUnwrap(selectedIndex))
        // Another client adds a key that sorts first, so the selected key moves; ⌘R shows it and DBSIZE grows (AC2).
        server.add("a:0")
        await model.refresh()
        XCTAssertEqual(list.totalKeys, 4)
        XCTAssertEqual(list.keyCountForTests, 4)
        let restored = await list.selectedKeyName()
        XCTAssertEqual(restored, Data("user:2".utf8), "the selection follows the key, not its old row")
        XCTAssertEqual(model.databases.entry(0)?.title, "db0 · 4 keys")
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "KEYS" })
    }

    @MainActor func testSwitchingDatabaseClearsTheListAndOnlyOffersKnownDatabases() async throws {
        let server = BrowserKeyspace([0: ["user:1", "user:2"], 2: ["a"]])
        let list = server.list()
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        await list.select(key: 0)

        await model.selectDatabase(2)
        XCTAssertEqual(model.database, 2)
        XCTAssertNil(list.selectedKey, "the selection named a key in another database")
        XCTAssertEqual(list.keyCountForTests, 1)
        XCTAssertEqual(list.totalKeys, 1)
        XCTAssertTrue(server.commands.contains { $0.database == 2 && $0.arguments == ["SCAN", "0", "COUNT", "1000"] })

        // db16 isn't offered without the server's count; a cluster server offers db0 only.
        await model.selectDatabase(16)
        XCTAssertEqual(model.database, 2)
        let cluster = BrowserModel(list: BrowserKeyspace([0: ["k"]]).list(), database: 0, serverMode: .cluster)
        await cluster.start()
        XCTAssertEqual(cluster.databases.entries.map(\.name), ["db0"])
        await cluster.selectDatabase(1)
        XCTAssertEqual(cluster.database, 0)
    }

    @MainActor func testOpeningADeletedKeyOffersRemoval() async throws {
        let server = BrowserKeyspace([0: ["user:1", "user:2", "user:3"]])
        let list = server.list(); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let model = BrowserModel(list: list, database: 0)
        await model.start()

        server.delete("user:2")
        await list.select(key: 1)
        try await waitUntil { model.missingKey != nil }
        XCTAssertEqual(model.missingKey, Data("user:2".utf8))
        let metadata = await list.index.metadata(at: 1)
        XCTAssertTrue(metadata.isStale)

        // Choosing another key hides the notice; coming back shows it again.
        await list.select(key: 0)
        try await waitUntil { model.missingKey == nil }
        await list.select(key: 1)
        try await waitUntil { model.missingKey != nil }

        // Remove from List drops only that key from the list; nothing is deleted on the server.
        let sent = server.commands.count
        await model.removeMissingKey()
        XCTAssertNil(model.missingKey)
        XCTAssertEqual(list.keyCountForTests, 2)
        let remaining = await list.index.keys(in: 0..<10)
        XCTAssertEqual(remaining, [Data("user:1".utf8), Data("user:3".utf8)])
        XCTAssertEqual(server.commands.count, sent)
    }

    /// Selection checks run in a task the model starts; wait for them on the main actor.
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

extension KeyListDataSource {
    /// Keys the list shows rows for (the flat table's row count without a local filter).
    var keyCountForTests: Int { numberOfRows(in: tableView) }
}
