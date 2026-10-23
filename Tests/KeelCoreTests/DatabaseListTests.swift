import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A small live keyspace per database, changed by "another client" between calls: `SCAN` (one page, `MATCH` and
/// `TYPE` applied), `TYPE`, `DBSIZE` and `INFO keyspace`, each answered for the database its connection is on.
final class FakeKeyspace: @unchecked Sendable {
    private let lock = NSLock()
    /// Key → type name, per database.
    private var databases: [Int: [String: String]]
    private(set) var server: RecordingServer!

    init(_ databases: [Int: [String: String]]) {
        self.databases = databases
        server = RecordingServer(answerIn: { [unowned self] database, arguments in self.answer(database, arguments) })
    }

    func set(_ key: String, type: String = "string", in database: Int = 0) { lock.withLock { databases[database, default: [:]][key] = type } }
    func delete(_ key: String, in database: Int = 0) { lock.withLock { _ = databases[database]?.removeValue(forKey: key) } }

    var commands: [[String]] { server.allCommands }
    func commands(_ name: String) -> [[String]] { commands.filter { $0.first == name } }

    func index(database: Int = 0, filter: KeyFilter = KeyFilter()) -> KeyIndex {
        KeyIndex(
            service: DataCommandService(session: server.session()),
            context: DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true), database: database),
            configuration: KeyIndexConfiguration(filter: filter))
    }

    private func answer(_ database: Int, _ arguments: [String]) -> String {
        let keys = lock.withLock { databases[database] ?? [:] }
        switch arguments.first?.uppercased() {
        case "SCAN":
            let match = arguments.firstIndex(of: "MATCH").map { arguments[$0 + 1] }
            let type = arguments.firstIndex(of: "TYPE").map { arguments[$0 + 1] }
            let listed = keys.filter { key, keyType in
                (match.map { GlobPattern.matches(Data($0.utf8), Data(key.utf8)) } ?? true) && (type.map { $0 == keyType } ?? true)
            }
            return ScanServer.reply(cursor: 0, keys: listed.keys.sorted())
        case "TYPE": return "+\(keys[arguments[1]] ?? "none")\r\n"
        case "DBSIZE": return ":\(keys.count)\r\n"
        case "INFO":
            let all = lock.withLock { databases }
            let lines = all.keys.sorted().compactMap { db in all[db].flatMap { $0.isEmpty ? nil : "db\(db):keys=\($0.count),expires=0,avg_ttl=0,subexpiry=0" } }
            let text = (["# Keyspace"] + lines).joined(separator: "\r\n") + "\r\n"
            return "$\(text.utf8.count)\r\n\(text)\r\n"
        default: return "-ERR unexpected\r\n"
        }
    }
}

final class DatabaseListTests: XCTestCase {
    func testCountsFromInfoKeyspace() async throws {
        // Redis 7.4+ adds `subexpiry`; Dragonfly reports avg_ttl -1. Other lines and malformed ones are skipped.
        let text = "# Keyspace\r\ndb0:keys=1204,expires=12,avg_ttl=3600000,subexpiry=0\r\ndb3:keys=1,expires=0,avg_ttl=-1\r\ndbx:keys=9\r\ndb4:expires=1\r\n"
        let keyspace = DatabaseList.parseKeyspace(text)
        XCTAssertEqual(keyspace, [0: KeyspaceCounts(keys: 1204, expires: 12), 3: KeyspaceCounts(keys: 1)])

        // Without the server's count: db0–db15; databases with keys show their count, the others their name alone.
        let list = DatabaseList(keyspace: keyspace, databaseCount: nil, mode: .standalone)
        XCTAssertEqual(list.entries.map(\.index), Array(0..<16))
        XCTAssertEqual(list.entry(0)?.title, "db0 · 1,204 keys")
        XCTAssertEqual(list.entry(3)?.title, "db3 · 1 key")
        XCTAssertEqual(list.entry(1)?.title, "db1")
        XCTAssertEqual(list.entry(1)?.accessibilityLabel, "db1, empty")
        XCTAssertNil(list.entry(16))

        // `CONFIG GET databases` sets the count; a database INFO lists past it is still offered, bounded.
        XCTAssertEqual(DatabaseList(keyspace: [:], databaseCount: 4, mode: .standalone).entries.count, 4)
        XCTAssertEqual(DatabaseList(keyspace: [20: KeyspaceCounts(keys: 2)], databaseCount: nil, mode: .standalone).entries.count, 21)
        XCTAssertEqual(DatabaseList(keyspace: [:], databaseCount: 1_000_000, mode: .standalone).entries.count, DatabaseList.maximumCount)

        // Loaded through the data path on a read-only profile: one INFO keyspace on the browser connection.
        let fake = FakeKeyspace([0: ["a": "string", "b": "hash"], 2: ["c": "list"]])
        let index = fake.index()
        let loaded = try await DatabaseList.load(service: index.service, context: await index.context, databaseCount: nil, mode: .standalone).get()
        XCTAssertEqual(loaded.entries.filter { $0.keys != nil }.map(\.title), ["db0 · 2 keys", "db2 · 1 key"])
        XCTAssertEqual(fake.commands, [["INFO", "keyspace"]])
        XCTAssertEqual(fake.server.opened.map(\.role), [.browser(database: 0)])
    }

    func testClusterOffersDb0Only() {
        let list = DatabaseList(keyspace: [0: KeyspaceCounts(keys: 5), 1: KeyspaceCounts(keys: 3)], databaseCount: 16, mode: .cluster)
        XCTAssertEqual(list.entries, [DatabaseEntry(index: 0, keys: 5, expires: 0)])
        XCTAssertNil(list.entry(1))
    }

    func testDatabaseCountFromConfigGet() async {
        @Sendable func value(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }
        XCTAssertEqual(DatabaseList.databaseCount(configReply: .array([value("databases"), value("32")])), 32)
        XCTAssertEqual(DatabaseList.databaseCount(configReply: .map([RESPPair(value("databases"), value("8"))])), 8)
        XCTAssertNil(DatabaseList.databaseCount(configReply: .error(Data("NOPERM this user has no permissions to run the 'config|get' command".utf8))))
        XCTAssertNil(DatabaseList.databaseCount(configReply: .array([])))
        XCTAssertNil(DatabaseList.databaseCount(configReply: .array([value("databases"), value("0")])))

        let probed = await DatabaseList.probeCount { (arguments: [Data]) async throws(RedisError) -> RESPValue in
            XCTAssertEqual(arguments.map { String(decoding: $0, as: UTF8.self) }, ["CONFIG", "GET", "databases"])
            return .array([value("databases"), value("4")])
        }
        XCTAssertEqual(probed, 4)
        let refused = await DatabaseList.probeCount { (_: [Data]) async throws(RedisError) -> RESPValue in throw .notConnected }
        XCTAssertNil(refused, "a failed probe falls back to db0–db15")
    }
}
