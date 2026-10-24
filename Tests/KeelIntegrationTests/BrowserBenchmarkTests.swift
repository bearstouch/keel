import Darwin
import Foundation
import KeelCore
import KeelRESP
import XCTest

/// KEEL-047 live benchmarks, run by `scripts/bench-browser.py` (never by a plain `swift test`): the browser's own code
/// against a disposable local server the script seeded. Needs `KEEL_BENCH=1`, `KEEL_BENCH_REDIS_PORT` and
/// `KEEL_BENCH_KEYS` (the keys the script put in db 0); `KEEL_BENCH_LABEL` names the run (`1m`, `10m`) and
/// `KEEL_BENCH_VALUES=1` also times opening the large values seeded in db 1. Results go to `KEEL_BENCH_OUTPUT`; the
/// script holds the NFR targets and the regression check, so these tests only assert that what they timed is complete.
final class BrowserBenchmarkTests: XCTestCase {
    private var port: UInt16 = 0
    private var keys = 0
    private var label = ""
    private let clock = ContinuousClock()

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["KEEL_BENCH"] == "1", "set KEEL_BENCH=1 (scripts/bench-browser.py does)")
        port = try XCTUnwrap(UInt16(environment["KEEL_BENCH_REDIS_PORT"] ?? ""), "KEEL_BENCH_REDIS_PORT")
        keys = try XCTUnwrap(Int(environment["KEEL_BENCH_KEYS"] ?? ""), "KEEL_BENCH_KEYS")
        label = environment["KEEL_BENCH_LABEL"] ?? "\(keys)"
    }

    /// A session whose connections reach the benchmark server with the app's handshake (RESP3, `CLIENT SETNAME`).
    private func session() -> ServerSession {
        let port = port
        return ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let endpoint = RedisEndpoint.tcp(host: "127.0.0.1", port: port), options = HandshakeOptions(database: database)
            let connection = RedisConnection(endpoint: endpoint)
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(connecting: error, endpoint: endpoint, timeout: .seconds(10)) }
            do throws(HandshakeError) { _ = try await connection.handshake(options) } catch { throw ConnectionFailure(handshake: error, endpoint: endpoint, options: options) }
            return connection
        }
    }

    private func time<T>(_ body: () async throws -> T) async rethrows -> (Duration, T) {
        let start = clock.now
        let result = try await body()
        return (clock.now - start, result)
    }

    /// NFR-PF03 (ingestion), PF04 (tree), PF05 (filter), PF02's editor header and RS01 (memory) at the seeded size.
    func testBrowser() async throws {
        let context = DataContext(profile: SafetyProfile(name: "bench", readOnly: true))
        let service = DataCommandService(session: session())
        let limit = min(max(keys, KeyIndexConfiguration.defaultLimit), KeyIndexConfiguration.maximumLimit)
        let index = KeyIndex(service: service, context: context, configuration: KeyIndexConfiguration(limit: limit))

        let heapBefore = Self.heapInUse()
        let (ingestion, status) = await time { await index.autoPage() }
        let heapGrowth = Self.heapInUse() - heapBefore
        // At 10M keys the limit can't exceed the keyspace (`maximumLimit`): reaching it before SCAN's final empty pages
        // stops at `.limitReached` with every key loaded, which the count below checks.
        XCTAssertTrue(status.phase == .complete || (status.phase == .limitReached && status.loadedCount == keys), "\(status)")
        XCTAssertEqual(status.loadedCount, keys)
        BenchmarkRecorder.record("live.\(label).scan_ingestion", ingestion)
        let storage = await index.storageBytes, tree = await index.treeStorageBytes, keyBytes = await index.keyBytes
        BenchmarkRecorder.record("live.\(label).index_and_tree_bytes", bytes: Double(storage + tree))
        BenchmarkRecorder.record("live.\(label).index_overhead_per_key", bytes: Double(storage - keyBytes) / Double(max(keys, 1)))
        BenchmarkRecorder.record("live.\(label).heap_growth_bytes", bytes: Double(heapGrowth))

        // A separator change rebuilds the whole tree: `/` flattens it, `:` opens every folder again.
        let slash = try XCTUnwrap(NamespaceSeparator(Data("/".utf8)))
        var rebuilds: [Duration] = []
        for separator in [slash, .default, slash, .default] { rebuilds.append(await time { await index.setSeparator(separator) }.0) }
        BenchmarkRecorder.record("live.\(label).tree_rebuild", try XCTUnwrap(rebuilds.max()))

        // Expanding: the root, then each of its folders (the widest holds half the keys), children plus a screen of rows.
        var expands: [Duration] = []
        func expand(_ folder: NamespaceFolderID) async -> [NamespaceChild] {
            let (elapsed, children) = await time {
                let children = await index.namespaceChildren(of: folder)
                _ = await index.namespaceEntries(children.prefix(60))
                return children
            }
            expands.append(elapsed)
            return children
        }
        for child in await expand(.root) { if case .folder(let id) = child { _ = await expand(id) } }
        XCTAssertGreaterThan(expands.count, 1, "the seeded keys open folders")
        BenchmarkRecorder.record("live.\(label).tree_expand", try XCTUnwrap(expands.max()))

        // Local filter: first results for a query half the keys match, then a whole pass for one nothing matches.
        let loaded = await index.count
        func search(_ text: String, untilFirst: Bool) async -> LocalKeyMatches {
            var matches = LocalKeyMatches(indices: [], searchedThrough: 0)
            while matches.searchedThrough < loaded, !(untilFirst && !matches.indices.isEmpty) {
                matches = await index.localMatches(LocalKeyQuery(text), from: matches.searchedThrough)
            }
            return matches
        }
        let (first, found) = await time { await search("cart", untilFirst: true) }
        XCTAssertFalse(found.indices.isEmpty)
        let (complete, none) = await time { await search("nothing-matches", untilFirst: false) }
        XCTAssertTrue(none.indices.isEmpty)
        BenchmarkRecorder.record("live.\(label).filter_first_results", first)
        BenchmarkRecorder.record("live.\(label).filter_complete", complete)

        // Selecting a row opens its editor header: `PTTL` and the length, side by side.
        var headers: [Duration] = []
        for row in [0, loaded / 2, loaded - 1] {
            let key = await index.key(at: row)
            let (elapsed, header) = await time { await KeyHeader.load(key: key, type: .string, service: service, context: context) }
            XCTAssertNotNil(header.length, "STRLEN answered")
            headers.append(elapsed)
        }
        BenchmarkRecorder.record("live.\(label).row_header", try XCTUnwrap(headers.max()))
    }

    /// NFR-PF06: the first page of each large value the script seeded in db 1, slowest of three opens after a warm-up.
    func testValueOpen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEEL_BENCH_VALUES"] == "1", "set KEEL_BENCH_VALUES=1")
        let context = DataContext(profile: SafetyProfile(name: "bench", readOnly: true), database: 1)
        let service = DataCommandService(session: session())
        typealias Load = @Sendable (Data, DataCommandService, DataContext) async throws -> LoadedValue
        let cases: [(name: String, load: Load)] = [
            ("hash_1m", { try await HashEditor.load(key: $0, service: $1, context: $2) }),
            ("list_10m", { try await ListEditor.load(key: $0, service: $1, context: $2) }),
            ("set_1m", { try await SetEditor.load(key: $0, service: $1, context: $2) }),
            ("zset_1m", { try await SortedSetEditor.load(key: $0, service: $1, context: $2) }),
            ("stream_1m", { try await StreamEditor.load(key: $0, service: $1, context: $2) }),
            ("string_64mib", { try await StringEditor.load(key: $0, service: $1, context: $2) })
        ]
        for (name, load) in cases {
            let key = Data("bench:\(name.split(separator: "_")[0])".utf8)
            var opens: [Duration] = []
            for attempt in 0..<4 {
                let (elapsed, value) = try await time { try await load(key, service, context) }
                XCTAssertFalse(value.rows.isEmpty, name)
                XCTAssertTrue(value.next != nil || value.partial != nil, "\(name): only the first page was read")
                if attempt > 0 { opens.append(elapsed) }
            }
            BenchmarkRecorder.record("live.value_open_\(name)", try XCTUnwrap(opens.max()))
        }
    }

    /// Bytes currently allocated in every malloc zone of this process.
    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
}

/// NFR-PF01's state: 200 saved profiles in ten folders, written to `KEEL_BENCH_LAUNCH_STATE` for the app to launch
/// with (`--state-directory`). No secrets: none of the profiles has a password, so the Keychain is never touched.
final class LaunchStateBenchmarkTests: XCTestCase {
    func testWriteTwoHundredProfiles() async throws {
        let path = ProcessInfo.processInfo.environment["KEEL_BENCH_LAUNCH_STATE"] ?? ""
        try XCTSkipUnless(path.hasPrefix("/"), "set KEEL_BENCH_LAUNCH_STATE=/abs/dir (scripts/bench-browser.py does)")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let folders = (0..<10).map { ProfileFolder(id: UUID(), name: "Team \($0)", revision: 1) }
        let profiles = (0..<200).map { i in
            ConnectionProfile(
                id: UUID(), settings: ConnectionSettings(name: "bench-\(i)", host: "127.0.0.1", port: UInt16(20_000 + i), database: i % 16),
                folderID: i < 20 ? nil : folders[i % 10].id, revision: 1)
        }
        // Persistence writes only after a load found the folder usable (empty or valid), as the app's store does.
        let persistence = Persistence<ConnectionsDocument>(directory: directory)
        _ = await persistence.load()
        let saved = try await persistence.save(ConnectionsDocument(revision: 1, folders: folders, profiles: profiles), sequence: 1)
        XCTAssertTrue(saved)
    }
}
