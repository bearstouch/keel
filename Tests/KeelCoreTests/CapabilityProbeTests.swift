import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Plays a server: answers each probe from `replies` keyed by the command name (first word, or first two for
/// subcommands), records every command sent and can fail the transport.
private actor FakeServer {
    var replies: [String: RESPValue]
    var failure: RedisError?
    private(set) var sent: [[String]] = []

    init(_ replies: [String: RESPValue] = [:]) { self.replies = replies }

    func setFailure(_ error: RedisError?) { failure = error }
    func setReply(_ name: String, _ reply: RESPValue) { replies[name] = reply }

    func send(_ arguments: [Data]) throws(RedisError) -> RESPValue {
        let words = arguments.map { String(decoding: $0, as: UTF8.self) }
        sent.append(words)
        if let failure { throw failure }
        let two = words.prefix(2).joined(separator: " ").uppercased()
        return replies[two] ?? replies[words[0].uppercased()] ?? .array([])
    }

    func count(_ name: String) -> Int { sent.filter { $0.joined(separator: " ").uppercased().hasPrefix(name) }.count }
}

private func error(_ text: String) -> RESPValue { .error(Data(text.utf8)) }

final class CapabilityProbeTests: XCTestCase {
    private func probe(_ server: FakeServer) -> CapabilityProbe {
        CapabilityProbe(probeKey: Data("keel:probe:test".utf8)) { (arguments: [Data]) async throws(RedisError) -> RESPValue in try await server.send(arguments) }
    }

    /// Redis 6.0: no COMMAND DOCS, BYSCORE, exclusive XRANGE, PEXPIRETIME or EVAL_RO.
    private func redis60() -> FakeServer {
        FakeServer([
            "MEMORY USAGE": .nullBulkString, "OBJECT ENCODING": .nullBulkString,
            "COMMAND DOCS": error("ERR Unknown subcommand or wrong number of arguments for 'DOCS'. Try COMMAND HELP."),
            "ZRANGE": error("ERR syntax error"), "XRANGE": error("ERR Invalid stream ID specified as stream command argument"),
            "PEXPIRETIME": error("ERR unknown command `PEXPIRETIME`, with args beginning with: `keel:probe:test`, "),
            "EVAL_RO": error("ERR unknown command `EVAL_RO`, with args beginning with: `return 0`, `0`, ")
        ])
    }

    // MARK: - Story tests

    func testProbesAreCachedPerSession() async throws {
        let server = FakeServer(["PEXPIRETIME": .integer(-2)])
        let session = probe(server)
        let first = try await session.status(.pexpireTime)
        let second = try await session.status(.pexpireTime)
        XCTAssertEqual(first, .available)
        XCTAssertEqual(second, .available)
        let sentOnce = await server.count("PEXPIRETIME")
        XCTAssertEqual(sentOnce, 1, "the second ask is answered from the cache")

        // Concurrent askers share the probe in flight.
        async let a = session.status(.memoryUsage)
        async let b = session.status(.memoryUsage)
        _ = try await (a, b)
        let memory = await server.count("MEMORY USAGE")
        XCTAssertEqual(memory, 1)

        // probeAll only sends what isn't known yet; a new session probes again.
        _ = try await session.probeAll()
        let total = await server.sent.count
        XCTAssertEqual(total, ServerCapability.allCases.count)
        _ = try await probe(server).status(.pexpireTime)
        let again = await server.count("PEXPIRETIME")
        XCTAssertEqual(again, 2, "the cache belongs to one session")
    }

    func testUnsupportedCommandMarksFeatureUnavailable() async throws {
        let capabilities = try await probe(redis60()).probeAll()
        XCTAssertTrue(capabilities.supports(.memoryUsage))
        XCTAssertTrue(capabilities.supports(.objectEncoding))
        for missing: ServerCapability in [.commandDocs, .zrangeByScore, .xrangeExclusive, .pexpireTime, .evalReadOnly] {
            XCTAssertFalse(capabilities.supports(missing), missing.rawValue)
            guard case .unavailable(let serverError?) = capabilities.statuses[missing] else { return XCTFail("\(missing) has no server error") }
            XCTAssertTrue(serverError.hasPrefix("ERR"), serverError)
        }

        // Editor fallbacks on 6.0: ZRANGEBYSCORE, PTTL, and an inclusive start one past the last stream ID.
        let key = Data("z".utf8)
        XCTAssertEqual(words(capabilities.zrangeByScore(key: key, min: Data("-inf".utf8), max: Data("+inf".utf8), offset: 0, count: 100)), "ZRANGEBYSCORE z -inf +inf WITHSCORES LIMIT 0 100")
        XCTAssertEqual(words(capabilities.expiryQuery(key: key).arguments), "PTTL z")
        XCTAssertEqual(capabilities.xrangeAfter(key: key, lastID: Data("1700000000000-5".utf8), count: 50).map(words), "XRANGE z 1700000000000-6 + COUNT 50")

        // Dragonfly without OBJECT ENCODING shows "unavailable".
        let dragonfly = try await probe(FakeServer(["OBJECT ENCODING": error("ERR Unknown subcommand 'ENCODING'")])).status(.objectEncoding)
        XCTAssertFalse(dragonfly.isAvailable)
        XCTAssertEqual(CapabilityStatus.unavailableCode, "UNSUPPORTED")
    }

    // MARK: - Probe details and failure safety

    func testModernServerUsesNewForms() async throws {
        let capabilities = try await probe(FakeServer(["PEXPIRETIME": .integer(-2), "EVAL_RO": .integer(0), "MEMORY USAGE": .null])).probeAll()
        XCTAssertEqual(capabilities.statuses.count, ServerCapability.allCases.count)
        XCTAssertTrue(ServerCapability.allCases.allSatisfy(capabilities.supports))
        let key = Data("z".utf8)
        XCTAssertEqual(words(capabilities.zrangeByScore(key: key, min: Data("(1".utf8), max: Data("5".utf8), offset: 10, count: 5, withScores: false)), "ZRANGE z (1 5 BYSCORE LIMIT 10 5")
        XCTAssertEqual(words(capabilities.expiryQuery(key: key).arguments), "PEXPIRETIME z")
        XCTAssertEqual(capabilities.xrangeAfter(key: key, lastID: Data("1-2".utf8), count: 1).map(words), "XRANGE z (1-2 + COUNT 1")
    }

    func testProbesAreReadOnlyAndUseTheProbeKey() async throws {
        let server = FakeServer()
        _ = try await probe(server).probeAll()
        let sent = await server.sent
        XCTAssertEqual(
            sent.map { $0.joined(separator: " ") },
            [
                "MEMORY USAGE keel:probe:test", "OBJECT ENCODING keel:probe:test", "COMMAND DOCS GET", "ZRANGE keel:probe:test 0 0 BYSCORE",
                "XRANGE keel:probe:test (0-0 + COUNT 1", "PEXPIRETIME keel:probe:test", "EVAL_RO return 0 0"
            ])
        // Without an explicit key each session picks a fresh keel:probe:<uuid> name.
        let other = FakeServer()
        _ = try await CapabilityProbe { (arguments: [Data]) async throws(RedisError) -> RESPValue in try await other.send(arguments) }.status(.pexpireTime)
        let key = await other.sent.first?.last ?? ""
        XCTAssertTrue(key.hasPrefix("keel:probe:") && key.count == "keel:probe:".count + 36, key)
    }

    func testConnectionFailureIsNotCached() async throws {
        let server = FakeServer(["PEXPIRETIME": .integer(-2)])
        await server.setFailure(.connectionLost)
        let session = probe(server)
        do {
            _ = try await session.status(.pexpireTime)
            XCTFail("expected a connection error")
        } catch {
            XCTAssertEqual(error, .connectionLost)
        }
        let cachedAfterFailure = await session.cached
        XCTAssertEqual(cachedAfterFailure, CapabilitySet(), "nothing cached after a failed probe")
        await server.setFailure(nil)
        let retried = try await session.status(.pexpireTime)
        XCTAssertEqual(retried, .available)
    }

    func testTransientErrorsAreNotCached() async throws {
        let server = FakeServer(["PEXPIRETIME": error("LOADING Redis is loading the dataset in memory")])
        let session = probe(server)
        let loading = try await session.status(.pexpireTime)
        XCTAssertFalse(loading.isAvailable, "the fallback is used while loading")
        await server.setReply("PEXPIRETIME", .integer(-2))
        let ready = try await session.status(.pexpireTime)
        XCTAssertEqual(ready, .available)
    }

    func testNoSuchKeyMeansCommandExists() {
        XCTAssertEqual(CapabilityProbe.classify(error("ERR no such key")), .available)
        XCTAssertEqual(CapabilityProbe.classify(error("NOPERM this user has no permissions to run the 'memory|usage' command")).isAvailable, false)
    }

    func testExpiryFromRepliesAndStreamEdges() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pttl = CapabilitySet().expiryQuery(key: Data("k".utf8))
        XCTAssertEqual(pttl.expiry(reply: 1_500, now: now), .at(Date(timeIntervalSince1970: 1_001.5)))
        XCTAssertEqual(pttl.expiry(reply: -1, now: now), .persistent)
        XCTAssertEqual(pttl.expiry(reply: -2, now: now), .missing)
        let absolute = CapabilitySet([.pexpireTime: .available]).expiryQuery(key: Data("k".utf8))
        XCTAssertEqual(absolute.expiry(reply: 2_000_000, now: now), .at(Date(timeIntervalSince1970: 2_000)))

        let old = CapabilitySet(), key = Data("s".utf8)
        XCTAssertEqual(old.xrangeAfter(key: key, lastID: Data("5-\(UInt64.max)".utf8), count: 1).map(words), "XRANGE s 6-0 + COUNT 1")
        XCTAssertNil(old.xrangeAfter(key: key, lastID: Data("\(UInt64.max)-\(UInt64.max)".utf8), count: 1))
        XCTAssertNil(old.xrangeAfter(key: key, lastID: Data("not-an-id".utf8), count: 1))
        XCTAssertNil(old.xrangeAfter(key: key, lastID: Data("+1-2".utf8), count: 1))
    }

    private func words(_ arguments: [Data]) -> String { arguments.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ") }
}
