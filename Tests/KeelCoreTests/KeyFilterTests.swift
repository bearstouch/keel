import Darwin
import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A typed keyspace that honors `SCAN … MATCH` (via `fnmatch`, close enough to Redis globs for these patterns) and
/// `SCAN … TYPE`, and answers `TYPE`. Each page is one slice of `keys`; the last page returns cursor 0.
final class TypedKeyspace: @unchecked Sendable {
    let server: RecordingServer

    /// `types` maps each key to its `TYPE` name; a key listed in `vanished` is returned by SCAN but `TYPE` says `none`.
    init(pages: [[(String, String)]], vanished: Set<String> = [], typeError: String? = nil) {
        let types = Dictionary(pages.flatMap { $0 }, uniquingKeysWith: { first, _ in first })
        server = RecordingServer { arguments in
            switch arguments.first?.uppercased() {
            case "TYPE":
                if let typeError { return "-\(typeError)\r\n" }
                return vanished.contains(arguments[1]) ? "+none\r\n" : "+\(types[arguments[1]] ?? "none")\r\n"
            case "SCAN":
                guard let cursor = Int(arguments[1]), pages.indices.contains(cursor) else { return "-ERR unexpected\r\n" }
                let match = arguments.firstIndex(of: "MATCH").map { arguments[$0 + 1] }
                let type = arguments.firstIndex(of: "TYPE").map { arguments[$0 + 1] }
                let keys = pages[cursor].filter { key, keyType in
                    (match.map { fnmatch($0, key, 0) == 0 } ?? true) && (type.map { $0 == keyType } ?? true)
                }
                return ScanServer.reply(cursor: cursor + 1 == pages.count ? 0 : cursor + 1, keys: keys.map(\.0))
            default: return "-ERR unexpected\r\n"
            }
        }
    }

    var commands: [[String]] { server.allCommands }
    var scans: [[String]] { commands.filter { $0.first == "SCAN" } }

    func index(_ filter: KeyFilter = KeyFilter()) -> KeyIndex {
        let context = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true))
        return KeyIndex(service: DataCommandService(session: server.session()), context: context, configuration: KeyIndexConfiguration(filter: filter))
    }
}

func loadedNames(_ index: KeyIndex) async -> [String] {
    await index.keys(in: 0..<index.count).map { String(decoding: $0, as: UTF8.self) }
}

final class KeyFilterTests: XCTestCase {
    static let keyspace: [[(String, String)]] = [
        [("user:1", "hash"), ("user:2", "string"), ("order:1", "hash")],
        [("user:3", "hash"), ("user:json:4", "ReJSON-RL"), ("session:9", "string")],
        [("user:5", "zset"), ("user:6", "hash"), ("bloom:1", "MBbloom--")]
    ]

    func testPatternAndTypeBuildScanArguments() async {
        XCTAssertEqual(
            KeyFilter(pattern: "user:*", type: .hash).scan(cursor: Data("0".utf8), count: 1_000).arguments.map { String(decoding: $0, as: UTF8.self) },
            ["SCAN", "0", "MATCH", "user:*", "COUNT", "1000", "TYPE", "hash"])
        // An empty field and a bare `*` both mean "every key": no MATCH at all.
        XCTAssertNil(KeyFilter(pattern: "").scanMatch)
        XCTAssertNil(KeyFilter(pattern: "*").scanMatch)
        XCTAssertFalse(KeyFilter(pattern: "*").isActive)
        for type in KeyTypeFilter.allCases where type != .other {
            XCTAssertEqual(KeyFilter(type: type).scanType, Data(type.rawValue.utf8))
            XCTAssertNil(KeyFilter(type: type).clientSideNotice)
        }
        // Glob bytes pass through unchanged, escapes and non-ASCII included.
        XCTAssertEqual(KeyFilter(pattern: "a\\*[^x]?é").scanMatch, Data("a\\*[^x]?é".utf8))

        // AC1: `user:*` + hash lists only hashes under `user:`, every page sent with MATCH and TYPE.
        let fake = TypedKeyspace(pages: Self.keyspace)
        let index = fake.index(KeyFilter(pattern: "user:*", type: .hash))
        let status = await index.autoPage()
        XCTAssertEqual(status.phase, .complete)
        let names = await loadedNames(index)
        XCTAssertEqual(names, ["user:1", "user:3", "user:6"])
        XCTAssertEqual(fake.scans.map { Array($0.dropFirst(2)) }, Array(repeating: ["MATCH", "user:*", "COUNT", "1000", "TYPE", "hash"], count: 3))
        XCTAssertEqual(fake.commands.count, 3, "the server filtered: no TYPE per key")
        // The filter tells each key's type, so its badge shows without a TYPE of its own.
        let types = await (0..<3).asyncMap { await index.metadata(at: $0).type }
        XCTAssertEqual(types, [.hash, .hash, .hash])
    }

    func testFilterChangeRestartsScan() async {
        let fake = TypedKeyspace(pages: Self.keyspace)
        let index = fake.index()
        await index.loadMore()
        await index.loadMore()
        var count = await index.count
        XCTAssertEqual(count, 6)

        // AC2: a new filter clears the loaded keys and starts again from cursor 0 with the new arguments.
        await index.restart(filter: KeyFilter(pattern: "user:*"))
        count = await index.count
        var status = await index.status
        XCTAssertEqual(count, 0, "stale results are cleared")
        XCTAssertEqual(status.phase, .idle)
        let filter = await index.configuration.filter
        XCTAssertEqual(filter, KeyFilter(pattern: "user:*"))
        await index.loadMore()
        XCTAssertEqual(fake.scans.last, ["SCAN", "0", "MATCH", "user:*", "COUNT", "1000"])
        var names = await loadedNames(index)
        XCTAssertEqual(names, ["user:1", "user:2"])

        // Refresh (a restart without a filter) keeps the current one (FR-KB09).
        await index.restart()
        status = await index.autoPage()
        XCTAssertEqual(status.phase, .complete)
        names = await loadedNames(index)
        XCTAssertEqual(names, ["user:1", "user:2", "user:3", "user:json:4", "user:5", "user:6"])
        XCTAssertTrue(fake.scans.suffix(3).allSatisfy { $0.contains("MATCH") })
        XCTAssertFalse(fake.commands.contains { $0.first == "KEYS" })
    }

    func testFilterChangeDropsThePageInFlight() async {
        let gate = GatedTransport { arguments in
            guard arguments.first == "SCAN" else { return "-ERR unexpected\r\n" }
            return ScanServer.reply(cursor: 0, keys: arguments.contains("MATCH") ? ["user:1"] : ["stale:1", "stale:2"])
        }
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: gate)
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake connect failed", suggestion: "")
            }
            return connection
        }
        let index = KeyIndex(service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        let stale = Task { await index.loadMore() }
        var spins = 0
        while gate.inner.commands.isEmpty, spins < 100_000 { await Task.yield(); spins += 1 }
        await index.restart(filter: KeyFilter(pattern: "user:*"))
        gate.release()
        _ = await stale.value
        var names = await loadedNames(index)
        XCTAssertEqual(names, [], "the unfiltered page landing after the change is dropped")
        gate.release()
        await index.loadMore()
        names = await loadedNames(index)
        XCTAssertEqual(names, ["user:1"])
    }

    func testModuleTypesFilteredClientSide() async {
        let filter = KeyFilter(pattern: "*", type: .other)
        XCTAssertNil(filter.scanType, "SCAN can't select module types")
        XCTAssertEqual(filter.clientSideType, .other)
        // AC4: the filter says it is applied here.
        XCTAssertNotNil(filter.clientSideNotice)

        let fake = TypedKeyspace(pages: Self.keyspace, vanished: ["bloom:1"])
        let index = fake.index(filter)
        await index.loadMore()
        var names = await loadedNames(index)
        XCTAssertEqual(names, [], "page 1 holds no module types")
        await index.loadMore()
        names = await loadedNames(index)
        XCTAssertEqual(names, ["user:json:4"])
        let status = await index.autoPage()
        XCTAssertEqual(status.phase, .complete)
        names = await loadedNames(index)
        XCTAssertEqual(names, ["user:json:4"], "a key gone since SCAN (`none`) is left out")
        let type = await index.metadata(at: 0).type
        XCTAssertEqual(type, .other)

        // SCAN went without TYPE; every scanned key was checked with TYPE on the same browser connection.
        XCTAssertTrue(fake.scans.allSatisfy { !$0.contains("TYPE") })
        XCTAssertEqual(fake.commands.filter { $0.first == "TYPE" }.count, 9)
        XCTAssertEqual(fake.server.opened.map(\.role), [.browser(database: 0)])
    }

    func testFailedTypeCheckKeepsTheCursor() async {
        let fake = TypedKeyspace(pages: Self.keyspace, typeError: "NOPERM this user has no permissions to run the 'type' command")
        let index = fake.index(KeyFilter(type: .other))
        let status = await index.loadMore()
        guard case .failed(let error) = status.phase else { return XCTFail("\(status.phase)") }
        XCTAssertEqual(error.code, "PERMISSION_DENIED")
        let count = await index.count
        XCTAssertEqual(count, 0)
        await index.loadMore()
        XCTAssertEqual(fake.scans.map { $0[1] }, ["0", "0"], "Retry resends the same cursor")
    }

    func testTypeNames() {
        XCTAssertEqual(KeyType(typeName: Data("hash".utf8)), .hash)
        XCTAssertEqual(KeyType(typeName: Data("ReJSON-RL".utf8)), .other)
        XCTAssertEqual(KeyType(typeName: Data("vectorset".utf8)), .other)
        XCTAssertNil(KeyType(typeName: Data("none".utf8)))
    }

    func testLocalQueryIgnoresASCIICaseAndMatchesBytes() async {
        let index = TypedKeyspace(pages: []).index()
        await index.ingest(["user:1", "USER:2", "order:user", "session", "caf\u{e9}"].map { Data($0.utf8) } + [Data([0xFF, 0x00, 0x61])])
        var matches = await index.localMatches(LocalKeyQuery("User"))
        XCTAssertEqual(matches, LocalKeyMatches(indices: [0, 1, 2], searchedThrough: 6))
        matches = await index.localMatches(LocalKeyQuery("é"))
        XCTAssertEqual(matches.indices, [4])
        matches = await index.localMatches(LocalKeyQuery(""))
        XCTAssertEqual(matches.indices, Array(0..<6), "an empty query keeps every key")
        // Chunks resume where the last one stopped.
        matches = await index.localMatches(LocalKeyQuery("user"), from: 1, chunk: 1)
        XCTAssertEqual(matches, LocalKeyMatches(indices: [1], searchedThrough: 2))
        matches = await index.localMatches(LocalKeyQuery("a"), from: 99)
        XCTAssertEqual(matches, LocalKeyMatches(indices: [], searchedThrough: 6))
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}
