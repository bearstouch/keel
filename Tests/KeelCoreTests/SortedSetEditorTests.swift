import Darwin
import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// One sorted set with `MULTI/EXEC` and `WATCH`, answering in RESP2 the way Redis 6 does: scores as `%.17g` bulk strings
/// (`0.10000000000000001`, `inf`). `byScore` false is a Redis 6.0 that refuses `ZRANGE … BYSCORE` (and the probe).
/// `ZSCAN`'s cursor is an offset into the member order; `EXEC` replies nil when the set changed after `WATCH`.
final class SortedSetServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    /// Kept in Redis's order: by score, then by member.
    private var members: [(member: String, score: Double)]
    private var version = 0
    private var watched: Int?
    private var queued: [[String]]?
    private var sent: [[String]] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    let byScore: Bool

    init(_ members: [(String, Double)], byScore: Bool = true) {
        self.members = members.map { (member: $0.0, score: $0.1) }; self.byScore = byScore
        sort()
    }

    var commands: [[String]] { lock.withLock { sent } }
    /// The commands sent for the key itself (not the capability probe's key).
    var keyCommands: [[String]] { commands.filter { $0.count < 2 || !$0[1].hasPrefix("keel:probe:") } }
    var scores: [String: Double] { lock.withLock { Dictionary(members.map { ($0.member, $0.score) }, uniquingKeysWith: { a, _ in a }) } }

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

    /// Another client's write.
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

    private func sort() {
        members.sort { $0.score != $1.score ? $0.score < $1.score : Array($0.member.utf8).lexicographicallyPrecedes(Array($1.member.utf8)) }
    }

    static func spell(_ score: Double) -> String { score.isInfinite ? (score < 0 ? "-inf" : "inf") : String(format: "%.17g", score) }

    /// Called with `lock` held.
    private func run(_ arguments: [String]) -> String {
        if arguments.count > 1, arguments[1].hasPrefix("keel:probe:") {
            return byScore ? "*0\r\n" : "-ERR syntax error\r\n"
        }
        func bound(_ text: String) -> (Double, Bool) { text.hasPrefix("(") ? (Double(text.dropFirst())!, true) : (Double(text)!, false) }
        func range(min: String, max: String, reverse: Bool, offset: Int, count: Int) -> String {
            let (low, lowOpen) = bound(min), (high, highOpen) = bound(max)
            let inRange = members.filter { ($0.score > low || (!lowOpen && $0.score == low)) && ($0.score < high || (!highOpen && $0.score == high)) }
            let ordered = reverse ? inRange.reversed() : inRange
            let page = ordered.dropFirst(offset).prefix(count)
            return "*\(page.count * 2)\r\n" + page.map { Self.bulk($0.member) + Self.bulk(Self.spell($0.score)) }.joined()
        }
        func limit(_ args: [String]) -> (Int, Int) {
            guard let index = args.firstIndex(of: "LIMIT") else { return (0, Int.max) }
            return (Int(args[index + 1])!, Int(args[index + 2])!)
        }
        switch arguments.first {
        case "ZCARD": return ":\(members.count)\r\n"
        case "PTTL": return members.isEmpty ? ":-2\r\n" : ":-1\r\n"
        case "ZRANGE":
            guard byScore, arguments.contains("BYSCORE") else { return "-ERR syntax error\r\n" }
            let reverse = arguments.contains("REV"), (offset, count) = limit(arguments)
            return range(min: reverse ? arguments[3] : arguments[2], max: reverse ? arguments[2] : arguments[3], reverse: reverse, offset: offset, count: count)
        case "ZRANGEBYSCORE":
            let (offset, count) = limit(arguments)
            return range(min: arguments[2], max: arguments[3], reverse: false, offset: offset, count: count)
        case "ZREVRANGEBYSCORE":
            let (offset, count) = limit(arguments)
            return range(min: arguments[3], max: arguments[2], reverse: true, offset: offset, count: count)
        case "ZSCORE": return members.first { $0.member == arguments[2] }.map { Self.bulk(Self.spell($0.score)) } ?? "$-1\r\n"
        case "ZSCAN":
            let start = Int(arguments[2])!, count = Int(arguments[arguments.firstIndex(of: "COUNT")! + 1])!
            let pattern = arguments.firstIndex(of: "MATCH").map { arguments[$0 + 1] }
            let slice = members[min(start, members.count)..<min(start + count, members.count)]
            let page = slice.filter { pattern == nil || fnmatch(pattern!, $0.member, 0) == 0 }
            let next = start + count >= members.count ? 0 : start + count
            return "*2\r\n" + Self.bulk(String(next)) + "*\(page.count * 2)\r\n" + page.map { Self.bulk($0.member) + Self.bulk(Self.spell($0.score)) }.joined()
        case "ZADD":
            let xx = arguments[2] == "XX"
            var rest = Array(arguments.dropFirst(xx ? 3 : 2)), added = 0
            while rest.count >= 2 {
                let score = Double(rest[0])!, member = rest[1]
                rest.removeFirst(2)
                if let index = members.firstIndex(where: { $0.member == member }) {
                    members[index].score = score
                } else if !xx {
                    members.append((member, score)); added += 1
                }
            }
            sort(); version += 1
            return ":\(added)\r\n"
        case "ZINCRBY":
            let amount = Double(arguments[2])!, member = arguments[3]
            if let index = members.firstIndex(where: { $0.member == member }) { members[index].score += amount } else { members.append((member, amount)) }
            sort(); version += 1
            return Self.bulk(Self.spell(members.first { $0.member == member }!.score))
        case "ZREM":
            let removed = Set(arguments.dropFirst(2)), before = members.count
            members.removeAll { removed.contains($0.member) }
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

final class SortedSetEditorTests: XCTestCase {
    private let key = Data("z".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }
    private func row(_ member: String, _ score: Double) -> EditorRow { SortedSetEditor.row(d(member), score: score) }
    private static func numbered(_ count: Int, score: (Int) -> Double = { Double($0) }) -> [(String, Double)] { (0..<count).map { ("m\($0)", score($0)) } }

    /// AC3: `ZRANGE … BYSCORE … LIMIT` where the probe found it (6.2+), `ZRANGEBYSCORE` on Redis 6.0; descending pages use
    /// `REV` / `ZREVRANGEBYSCORE`. The probe runs once per session.
    func testPagingCommandByCapability() async throws {
        let redis60 = SortedSetServer([("a", 1), ("b", 2)], byScore: false)
        let service60 = redis60.service()
        let old = try await SortedSetEditor.load(key: key, service: service60, context: context)
        XCTAssertEqual(old.rows, [row("a", 1), row("b", 2)])
        XCTAssertEqual(redis60.keyCommands, [["ZRANGEBYSCORE", "z", "-inf", "+inf", "WITHSCORES", "LIMIT", "0", "500"]])
        _ = try await SortedSetEditor.load(key: key, descending: true, service: service60, context: context)
        XCTAssertEqual(redis60.keyCommands.last, ["ZREVRANGEBYSCORE", "z", "+inf", "-inf", "WITHSCORES", "LIMIT", "0", "500"])
        XCTAssertEqual(redis60.commands.filter { $0.first == "ZRANGE" }.count, 1, "probed once, then cached")
        XCTAssertFalse(redis60.keyCommands.contains { $0.first == "ZRANGE" }, "Redis 6.0 never gets BYSCORE for its key")

        let redis62 = SortedSetServer([("a", 1), ("b", 2)])
        let service62 = redis62.service()
        let value = try await SortedSetEditor.load(key: key, service: service62, context: context)
        XCTAssertEqual(value.rows, [row("a", 1), row("b", 2)])
        XCTAssertEqual(redis62.keyCommands, [["ZRANGE", "z", "-inf", "+inf", "BYSCORE", "WITHSCORES", "LIMIT", "0", "500"]])
        let reversed = try await SortedSetEditor.load(key: key, descending: true, service: service62, context: context)
        XCTAssertEqual(reversed.rows, [row("b", 2), row("a", 1)])
        XCTAssertEqual(redis62.keyCommands.last, ["ZRANGE", "z", "+inf", "-inf", "BYSCORE", "REV", "WITHSCORES", "LIMIT", "0", "500"])

        // The next page starts at the last score, inclusive, skipping the members with that score already loaded.
        let cursor = SortedSetEditor.Cursor(descending: false, score: 0.1, skip: 3)
        XCTAssertEqual(
            SortedSetEditor.pageOperation(key: key, from: cursor, descending: false, byScore: false).arguments.map { String(decoding: $0, as: UTF8.self) },
            ["ZRANGEBYSCORE", "z", "0.1", "+inf", "WITHSCORES", "LIMIT", "3", "500"])
    }

    /// Scores show the shortest text that reads back as the same double, whole numbers without a fraction, and `inf`.
    /// A Redis 6 reply (`%.17g`) reads as the double it spells.
    func testScoreFormattingFullPrecision() async throws {
        XCTAssertEqual(SortedSetEditor.scoreText(0.1), "0.1")
        XCTAssertEqual(SortedSetEditor.scoreText(0.1 + 0.2), "0.30000000000000004")
        XCTAssertEqual(SortedSetEditor.scoreText(1.0 / 3), "0.3333333333333333")
        XCTAssertEqual(SortedSetEditor.scoreText(42), "42")
        XCTAssertEqual(SortedSetEditor.scoreText(-2.5), "-2.5")
        XCTAssertEqual(SortedSetEditor.scoreText(1e20), "1e+20")
        XCTAssertEqual(SortedSetEditor.scoreText(9_007_199_254_740_993), "9007199254740992")
        XCTAssertEqual(SortedSetEditor.scoreText(.infinity), "inf")
        XCTAssertEqual(SortedSetEditor.scoreText(-.infinity), "-inf")
        for score in [0.1, 0.1 + 0.2, 1.0 / 3, 1e20, 5e-324, -.infinity, .infinity, 123_456_789.123_456_78] {
            XCTAssertEqual(SortedSetEditor.parseScore(SortedSetEditor.scoreText(score)), score, "round trip of \(score)")
        }
        XCTAssertEqual(SortedSetEditor.parseScore(" +inf "), .infinity)
        XCTAssertEqual(SortedSetEditor.parseScore("1e3"), 1_000)
        for invalid in ["", "nan", "NaN", "abc", "1.5x"] { XCTAssertNil(SortedSetEditor.parseScore(invalid), invalid) }

        let server = SortedSetServer([("tenth", 0.1), ("low", -.infinity), ("high", .infinity), ("third", 1.0 / 3)])
        let value = try await SortedSetEditor.load(key: key, service: server.service(), context: context)
        XCTAssertEqual(value.rows.map { String(decoding: $0.value, as: UTF8.self) }, ["-inf", "0.1", "0.3333333333333333", "inf"])
        // RESP3 sends `[member, double]` pairs.
        let pairs = RESPValue.array([.array([.bulkString(d("a")), .double(0.1)]), .array([.bulkString(d("b")), .double(-.infinity)])])
        XCTAssertEqual(SortedSetEditor.scoredRows(pairs), [row("a", 0.1), row("b", -.infinity)])
    }

    /// Changing a score is one `ZADD XX` (never adding a member removed meanwhile), guarded by `ZSCORE`; a Redis 6 reply
    /// (`0.10000000000000001`) matches the loaded 0.1, and a score changed elsewhere is a `CONFLICT`.
    func testChangeScoreUsesXX() async throws {
        let server = SortedSetServer([("a", 0.1), ("b", 2), ("c", 3)])
        let service = server.service()
        let loaded = try await SortedSetEditor.load(key: key, service: service, context: context)
        let draft = [row("a", 5), row("b", 2)]
        let writes = SortedSetEditor.writes(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(
            writes, [.sortedSetAdd(key: key, members: [.init(score: 5, member: d("a"))], existingOnly: true), .sortedSetRemove(key: key, members: [d("c")])])
        XCTAssertEqual(writes[0].arguments.map { String(decoding: $0, as: UTF8.self) }, ["ZADD", "z", "XX", "5", "a"])
        let watch = SortedSetEditor.saveGuard(key: key, loaded: loaded.rows, draft: draft)
        XCTAssertEqual(watch.reads, [.sortedSetScore(key: key, member: d("a"))], "only the changed score is guarded")

        _ = try await service.executeTransaction(writes, unchanged: watch, context: context)
        XCTAssertEqual(server.scores, ["a": 5, "b": 2])
        let after = try await SortedSetEditor.reread(key: key, loaded: loaded, draft: draft, service: service, context: context)
        XCTAssertEqual(after.rows, [row("a", 5), row("b", 2)])

        // Another client changed b's score after it loaded: the save writes nothing.
        let stale = try await SortedSetEditor.load(key: key, service: service, context: context)
        server.write(["ZADD", "z", "7", "b"])
        let edit = stale.rows.map { $0.id == d("b") ? row("b", 9) : $0 }
        do {
            _ = try await service.executeTransaction(
                SortedSetEditor.writes(key: key, loaded: stale.rows, draft: edit), unchanged: SortedSetEditor.saveGuard(key: key, loaded: stale.rows, draft: edit),
                context: context)
            XCTFail("expected a conflict")
        } catch { XCTAssertEqual(error, .conflict) }
        XCTAssertEqual(server.scores["b"], 7)
        XCTAssertEqual(SortedSetEditor.writes(key: key, loaded: loaded.rows, draft: loaded.rows), [], "nothing changed, nothing sent")
    }

    /// AC1: a 100k-member zset opens on its 500 lowest scores and pages forward without gaps or repeats.
    func testLargeSetShowsLowestFirstAndPagesForward() async throws {
        let server = SortedSetServer(Self.numbered(100_000) { Double(100_000 - $0) })
        let service = server.service()
        let first = try await SortedSetEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(first.rows.count, 500)
        XCTAssertEqual(first.rows.first, row("m99999", 1))
        XCTAssertEqual(first.rows.last, row("m99500", 500))
        var all = first.rows, cursor = first.next
        for _ in 0..<3 {
            let page = try await SortedSetEditor.loadMore(key: key, cursor: try XCTUnwrap(cursor), service: service, context: context)
            all += page.rows; cursor = page.next
        }
        XCTAssertEqual(all.count, 2_000)
        XCTAssertEqual(all.compactMap(SortedSetEditor.score(of:)), (1...2_000).map(Double.init), "ascending, contiguous")
        XCTAssertFalse(server.commands.contains { ["ZRANGEBYSCORE", "ZSCAN"].contains($0[0]) })
    }

    /// Many members sharing a score page through `LIMIT` skips: every member once, then the end.
    func testTiedScoresPageWithoutGapsOrRepeats() async throws {
        let server = SortedSetServer(Self.numbered(1_200) { $0 < 1_100 ? 0 : 1 })
        let service = server.service()
        let first = try await SortedSetEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(first.next.flatMap(SortedSetEditor.Cursor.init), SortedSetEditor.Cursor(descending: false, score: 0, skip: 500))
        let second = try await SortedSetEditor.loadMore(key: key, cursor: try XCTUnwrap(first.next), service: service, context: context)
        XCTAssertEqual(second.next.flatMap(SortedSetEditor.Cursor.init), SortedSetEditor.Cursor(descending: false, score: 0, skip: 1_000))
        let third = try await SortedSetEditor.loadMore(key: key, cursor: try XCTUnwrap(second.next), service: service, context: context)
        XCTAssertNil(third.next, "a short page ends the set")
        let members = (first.rows + second.rows + third.rows).map(\.id)
        XCTAssertEqual(members.count, 1_200)
        XCTAssertEqual(Set(members).count, 1_200)
    }

    /// A member moved away from the cursor's score no longer counts among the members the next page skips, so the
    /// member that takes its place in the order isn't missed.
    func testRereadKeepsCursorRight() async throws {
        let server = SortedSetServer(Self.numbered(1_000) { $0 < 499 ? 0 : 1 })
        let service = server.service()
        let loaded = try await SortedSetEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(loaded.next.flatMap(SortedSetEditor.Cursor.init)?.skip, 1, "one member with score 1 loaded")
        let draft = loaded.rows.map { $0.id == d("m499") ? row("m499", -1) : $0 }
        _ = try await service.executeTransaction(
            SortedSetEditor.writes(key: key, loaded: loaded.rows, draft: draft), unchanged: SortedSetEditor.saveGuard(key: key, loaded: loaded.rows, draft: draft),
            context: context)
        let after = try await SortedSetEditor.reread(key: key, loaded: loaded, draft: draft, service: service, context: context)
        XCTAssertEqual(after.next.flatMap(SortedSetEditor.Cursor.init)?.skip, 0)
        let next = try await SortedSetEditor.loadMore(key: key, cursor: try XCTUnwrap(after.next), service: service, context: context)
        XCTAssertEqual(next.rows.first?.id, d("m500"), "m500 is not skipped")
    }

    /// Pattern search pages through `ZSCAN … MATCH`, scores included.
    func testSearchUsesZScanMatch() async throws {
        let server = SortedSetServer([("user:1", 3), ("order:1", 1), ("user:2", 0.5)])
        let page = try await SortedSetEditor.search(key: key, pattern: d("user:*"), cursor: nil, service: server.service(), context: context)
        XCTAssertEqual(Set(page.rows.map(\.id)), [d("user:1"), d("user:2")])
        XCTAssertTrue(page.rows.contains(row("user:2", 0.5)))
        XCTAssertNil(page.next)
        XCTAssertEqual(server.keyCommands, [["ZSCAN", "z", "0", "MATCH", "user:*", "COUNT", "500"]])
    }

    /// Add and increment run at once: `ZADD` says whether the member was new, `ZINCRBY` answers the new score.
    func testAddAndIncrement() async throws {
        let server = SortedSetServer([("a", 1)])
        let service = server.service()
        let added = try await service.executeTransaction(SortedSetEditor.add(d("b"), score: 2, key: key), unchanged: nil, context: context)
        XCTAssertEqual(SortedSetEditor.added(added.reply), true)
        let existing = try await service.executeTransaction(SortedSetEditor.add(d("a"), score: 4, key: key), unchanged: nil, context: context)
        XCTAssertEqual(SortedSetEditor.added(existing.reply), false)
        let incremented = try await service.executeTransaction(SortedSetEditor.increment(d("a"), by: 0.1, key: key), unchanged: nil, context: context)
        XCTAssertEqual(SortedSetEditor.incremented(incremented.reply), 4.1)
        XCTAssertEqual(server.scores, ["a": 4.1, "b": 2])
        XCTAssertEqual(server.commands.filter { $0.first == "ZINCRBY" }, [["ZINCRBY", "z", "0.1", "a"]])
    }

    /// An empty first page means the key went away; read-only profiles refuse `ZADD` before anything is sent.
    func testMissingKeyAndReadOnly() async {
        do {
            _ = try await SortedSetEditor.load(key: key, service: SortedSetServer([]).service(), context: context)
            XCTFail("expected the key to be gone")
        } catch { XCTAssertEqual(error, EditorReads.gone) }

        let server = SortedSetServer([("a", 1)])
        let readOnly = DataContext(profile: SafetyProfile(name: "prod", readOnly: true))
        do {
            _ = try await server.service().executeTransaction(SortedSetEditor.add(d("b"), score: 1, key: key), unchanged: nil, context: readOnly)
            XCTFail("expected a refusal")
        } catch { if case .refused = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(server.commands, [], "nothing sent")
    }
}
