import Foundation
import XCTest

@testable import KeelCore

/// A monotonic clock the test moves: `sleep` advances it at once and records how long it was asked to wait.
final class FakeMetadataClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Duration.zero
    private var recorded: [Duration] = []
    /// Runs inside the first sleep, after the clock moved: lets a test send a newer request while one waits.
    var duringFirstSleep: (@Sendable () async -> Void)?

    var now: Duration { lock.withLock { time } }
    var sleeps: [Duration] { lock.withLock { recorded } }

    func advance(_ duration: Duration) { lock.withLock { time += duration } }

    func sleep(_ duration: Duration) async {
        let first = lock.withLock {
            recorded.append(duration); time += duration; return recorded.count == 1
        }
        if first, let duringFirstSleep { await duringFirstSleep() }
    }
}

/// A keyspace answering `TYPE`, `PTTL` and `MEMORY USAGE`, stamping each command with the fake clock's time.
final class MetadataKeyspace: @unchecked Sendable {
    let clock = FakeMetadataClock()
    let server: RecordingServer
    private let lock = NSLock()
    private var stamped: [(Duration, [String])] = []

    /// `ttls` in ms (-1 no expiry, -2 gone); keys not in `types` are gone. `memoryError` answers every MEMORY USAGE.
    init(types: [String: String], ttls: [String: Int] = [:], memoryError: String? = nil) {
        let box = Box()
        server = RecordingServer { arguments in
            box.owner?.stamp(arguments)
            let key = arguments.count > 1 ? arguments[arguments.count > 2 && arguments[0] == "MEMORY" ? 2 : 1] : ""
            switch arguments.first?.uppercased() {
            case "TYPE": return "+\(types[key] ?? "none")\r\n"
            case "PTTL": return ":\(types[key] == nil ? -2 : ttls[key] ?? -1)\r\n"
            case "MEMORY":
                if let memoryError { return "-\(memoryError)\r\n" }
                return types[key] == nil ? "$-1\r\n" : ":\(64 + key.utf8.count)\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
        box.owner = self
    }

    private final class Box: @unchecked Sendable { weak var owner: MetadataKeyspace? }

    private func stamp(_ arguments: [String]) { let now = clock.now; lock.withLock { stamped.append((now, arguments)) } }

    var commands: [[String]] { lock.withLock { stamped.map(\.1) } }
    var times: [Duration] { lock.withLock { stamped.map(\.0) } }
    func commands(_ name: String) -> [[String]] { commands.filter { $0.first == name } }

    /// An index holding `names` and a loader over it on the fake clock.
    func loader(_ names: [String]) async -> RowMetadataLoader {
        let index = KeyIndex(
            service: DataCommandService(session: server.session()), context: DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true)))
        await index.ingest(names.map { Data($0.utf8) })
        let clock = clock
        return RowMetadataLoader(index: index, now: { clock.now }, sleep: { await clock.sleep($0) })
    }
}

final class RowMetadataLoaderTests: XCTestCase {
    static let names = (0..<300).map { "user:\($0)" }
    static let types = Dictionary(uniqueKeysWithValues: names.map { ($0, "hash") })

    func testBatchesVisibleRowsOnly() async {
        let fake = MetadataKeyspace(types: Self.types, ttls: ["user:12": 90_000])
        let loader = await fake.loader(Self.names)

        // Rows 10–19 are on screen: one TYPE and one PTTL for each, nothing for the 290 keys off screen.
        let changed = await loader.load(Array(10..<20))
        XCTAssertEqual(Set(changed), Set(10..<20))
        XCTAssertEqual(Set(fake.commands("TYPE").map { $0[1] }), Set((10..<20).map { "user:\($0)" }))
        XCTAssertEqual(Set(fake.commands("PTTL").map { $0[1] }), Set((10..<20).map { "user:\($0)" }))
        XCTAssertEqual(fake.commands.count, 20)
        XCTAssertTrue(fake.commands("MEMORY").isEmpty, "AC1: no MEMORY USAGE without Show sizes")

        let index = loader.index
        let row = await index.metadata(at: 12)
        XCTAssertEqual(row.type, .hash)
        XCTAssertEqual(row.expiry, .expires(atMilliseconds: 90_000))
        let quiet = await index.metadata(at: 11)
        XCTAssertEqual(quiet.expiry, .persistent)
        let offScreen = await index.metadata(at: 30)
        XCTAssertEqual(offScreen, KeyMetadata())

        // Rows already known need nothing; only what is still unknown is sent (here the TTL under a known type).
        await index.updateMetadata(at: 40) { $0.type = .string }
        await loader.load(Array(10..<20) + [40])
        XCTAssertEqual(fake.commands.count, 21)
        XCTAssertEqual(fake.commands.last, ["PTTL", "user:40"])

        // However tall the window, one batch covers at most `maximumRows` keys.
        await loader.load(Array(0..<300))
        XCTAssertLessThanOrEqual(fake.commands("TYPE").count, 10 + RowMetadataLoader.maximumRows)
    }

    func testDebounce() async throws {
        let fake = MetadataKeyspace(types: Self.types)
        let loader = await fake.loader(Self.names)

        // The first batch goes at once; a second request right after waits out the 100 ms.
        await loader.load([0, 1])
        XCTAssertEqual(fake.clock.sleeps, [])
        await loader.load([2, 3])
        XCTAssertEqual(fake.clock.sleeps, [.milliseconds(100)])
        XCTAssertEqual(Set(fake.times), [.zero, .milliseconds(100)])

        // After a quiet spell the next batch needs no wait.
        fake.clock.advance(.milliseconds(250))
        await loader.load([4])
        XCTAssertEqual(fake.clock.sleeps.count, 1)
        XCTAssertEqual(fake.times.last, .milliseconds(350))
    }

    func testNewerRequestReplacesOneWaiting() async {
        let fake = MetadataKeyspace(types: Self.types)
        let loader = await fake.loader(Self.names)
        await loader.load([0])
        // While the request for row 1 waits, the list scrolls on to row 2: only row 2 is fetched, 100 ms later.
        fake.clock.duringFirstSleep = { await loader.load([2]) }
        let superseded = await loader.load([1])
        XCTAssertEqual(superseded, [])
        XCTAssertEqual(fake.commands("TYPE").map { $0[1] }, ["user:0", "user:2"])
        let pending = await loader.index.metadata(at: 1)
        XCTAssertEqual(pending.type, .unknown)
        // At most one batch per 100 ms (NFR-PF07).
        let starts = Array(Set(fake.times)).sorted()
        for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, RowMetadataLoader.interval) }
    }

    func testSizesOnlyOnRequest() async {
        let fake = MetadataKeyspace(types: Self.types)
        let loader = await fake.loader(Self.names)
        await loader.load(Array(0..<250))
        XCTAssertTrue(fake.commands("MEMORY").isEmpty, "browsing without Show sizes sends no MEMORY USAGE")

        // Show sizes: the 250 visible rows are measured in batches of at most 100, each 100 ms after the last.
        await loader.setShowsSizes(true)
        await loader.load(Array(0..<250))
        let memory = fake.commands("MEMORY")
        XCTAssertEqual(memory.count, 250)
        XCTAssertTrue(memory.allSatisfy { $0[1] == "USAGE" && Array($0[3...]) == ["SAMPLES", "0"] })
        let perBatch = Dictionary(grouping: zip(fake.times, fake.commands).filter { $0.1.first == "MEMORY" }, by: \.0).mapValues(\.count)
        XCTAssertEqual(perBatch.values.sorted(), [50, 100, 100])
        let size = await loader.index.metadata(at: 7).size
        XCTAssertEqual(size, .bytes(64 + 6))

        // Measured keys aren't measured again; turning sizes off sends nothing either.
        await loader.load(Array(0..<250))
        await loader.setShowsSizes(false)
        await loader.load(Array(250..<260))
        XCTAssertEqual(fake.commands("MEMORY").count, 250)
    }

    func testIdleSendsNothing() async {
        let fake = MetadataKeyspace(types: Self.types, ttls: ["user:0": 90_000])
        let loader = await fake.loader(Self.names)
        await loader.load(Array(0..<20))
        let sent = fake.commands.count

        // AC2: a minute of the same rows on screen sends nothing; the countdown runs from the stored deadline.
        for _ in 0..<60 {
            fake.clock.advance(.seconds(1))
            await loader.load(Array(0..<20))
        }
        XCTAssertEqual(fake.commands.count, sent)
        // AC3: "1m 30s" when fetched, "expired" once the deadline passes — without asking the server again.
        guard case .expires(let deadline) = await loader.index.metadata(at: 0).expiry else { return XCTFail("no deadline") }
        XCTAssertEqual(TTLFormatter.short(milliseconds: deadline - 0), "1m 30s")
        XCTAssertEqual(TTLFormatter.short(milliseconds: deadline - loader.nowMilliseconds()), "30s")
        fake.clock.advance(.seconds(30))
        XCTAssertEqual(TTLFormatter.short(milliseconds: deadline - loader.nowMilliseconds()), "expired")
    }

    func testGoneKeysAndRefusedSizes() async {
        // `user:1` vanished since SCAN; this server refuses MEMORY (an ACL without it, or no such command).
        var types = Self.types
        types["user:1"] = nil
        let fake = MetadataKeyspace(types: types, memoryError: "NOPERM this user has no permissions to run the 'memory|usage' command")
        let loader = await fake.loader(Self.names)
        await loader.setShowsSizes(true)
        await loader.load([0, 1])
        let gone = await loader.index.metadata(at: 1)
        XCTAssertEqual(gone.expiry, .gone)
        XCTAssertTrue(gone.isStale)
        XCTAssertEqual(gone.type, .unknown)
        let refused = await loader.index.metadata(at: 0)
        XCTAssertEqual(refused.size, .unavailable)
        // Neither is asked again: a gone key needs nothing, a refused size stays unavailable.
        let sent = fake.commands.count
        await loader.load([0, 1])
        XCTAssertEqual(fake.commands.count, sent)
    }

    func testRestartDropsAnswersForOldKeys() async {
        let fake = MetadataKeyspace(types: Self.types)
        let loader = await fake.loader(Self.names)
        let index = loader.index
        let (generation, _, work) = await index.metadataWork(for: [0], sizes: false, sizeLimit: 100)
        XCTAssertEqual(work, [RowMetadataWork(index: 0, key: Data("user:0".utf8), type: true, ttl: true, size: false)])
        await index.restart()
        await index.ingest([Data("other".utf8)])
        // Row 0 is another key now: answers fetched for `user:0` must not land on it.
        let changed = await index.applyMetadata([RowMetadataResult(index: 0, type: .hash, expiry: .persistent)], generation: generation)
        XCTAssertEqual(changed, [])
        let fresh = await index.metadata(at: 0)
        XCTAssertEqual(fresh, KeyMetadata())
    }
}

final class PackedKeyMetadataTests: XCTestCase {
    func testRoundTripsInEightBytes() {
        // NFR-RS01: the per-key column stays 8 bytes however much a row shows.
        XCTAssertEqual(MemoryLayout<PackedKeyMetadata>.stride, 8)
        let cases: [KeyMetadata] = [
            KeyMetadata(), KeyMetadata(type: .zset, isStale: true, expiry: .gone, size: .unavailable),
            KeyMetadata(type: .hash, expiry: .persistent, size: .bytes(4_198)), KeyMetadata(type: .stream, expiry: .expires(atMilliseconds: 90_000))
        ]
        for metadata in cases {
            let size: Int64? = if case .bytes(let bytes) = metadata.size { bytes } else { nil }
            XCTAssertEqual(PackedKeyMetadata(metadata).unpacked(size: size), metadata)
        }
        // Deadlines keep tenths of a second, rounded up, so a countdown in seconds never runs short.
        XCTAssertEqual(PackedKeyMetadata(KeyMetadata(expiry: .expires(atMilliseconds: 89_901))).unpacked(size: nil).expiry, .expires(atMilliseconds: 90_000))
    }
}

final class TTLFormatterTests: XCTestCase {
    func testShortForms() {
        let second: Int64 = 1_000, minute = 60 * second, hour = 60 * minute, day = 24 * hour
        let cases: [(Int64, String)] = [
            (1, "1s"), (45 * second, "45s"), (90 * second, "1m 30s"), (89_990, "1m 30s"), (12 * minute, "12m"),
            (59 * minute + 59 * second, "59m 59s"), (hour, "1h"), (2 * hour + 5 * minute, "2h 5m"), (2 * hour + 30 * second, "2h"),
            (day, "1d"), (3 * day + 4 * hour, "3d"), (400 * day, "400d"), (0, "expired"), (-5, "expired")
        ]
        for (milliseconds, expected) in cases { XCTAssertEqual(TTLFormatter.short(milliseconds: milliseconds), expected, "\(milliseconds) ms") }

        XCTAssertEqual(TTLFormatter.spoken(milliseconds: 90 * second), "1 minute 30 seconds")
        XCTAssertEqual(TTLFormatter.spoken(milliseconds: 3 * day + 4 * hour + 1 * second), "3 days 4 hours 1 second")
        XCTAssertEqual(TTLFormatter.spoken(milliseconds: 0), "expired")
    }

    func testSizeForms() {
        XCTAssertEqual(KeySizeFormatter.short(bytes: 512), "512 B")
        XCTAssertEqual(KeySizeFormatter.short(bytes: 4_198), "4.1 KB")
        XCTAssertEqual(KeySizeFormatter.short(bytes: 20 * 1_024), "20 KB")
        XCTAssertEqual(KeySizeFormatter.short(bytes: 1_258_291), "1.2 MB")
        XCTAssertEqual(KeySizeFormatter.short(bytes: 3 * 1_073_741_824), "3.0 GB")
    }
}
