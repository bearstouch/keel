import Foundation
import KeelCore
import XCTest

final class ServerDetectionTests: XCTestCase {
    private let detector = ServerDetector()

    /// `INFO server` + `INFO replication` text per server in `Tests/Fixtures/INFO`.
    static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/INFO/\(name).txt"),
            encoding: .utf8)
    }

    // MARK: - Story tests

    func testIdentifiesFixtures() throws {
        let expected: [(String, ServerKind, String, ServerMode)] = [
            ("redis-6.0", .redis, "6.0.20", .standalone), ("redis-7.4", .redis, "7.4.1", .replica), ("redis-8.0", .redis, "8.0.2", .standalone),
            ("valkey-7.2", .valkey, "7.2.7", .standalone), ("valkey-8.x", .valkey, "8.1.1", .standalone), ("valkey-9.x", .valkey, "9.0.0", .cluster),
            ("dragonfly", .dragonfly, "df-v1.24.0", .standalone)
        ]
        for (name, kind, version, mode) in expected {
            let identity = try detector.detect(info: Self.fixture(name))
            XCTAssertEqual(identity.kind, kind, name)
            XCTAssertEqual(identity.version?.text, version, name)
            XCTAssertEqual(identity.mode, mode, name)
            XCTAssertEqual(identity.showsClusterBanner, mode == .cluster, name)
        }
        let dragonfly = try detector.detect(info: Self.fixture("dragonfly"))
        XCTAssertEqual(dragonfly.version?.components, [1, 24, 0])
        XCTAssertEqual(dragonfly.redisCompatibleVersion?.text, "7.4.0", "redis_version still selects the bundled catalog")
        XCTAssertEqual(try detector.detect(info: Self.fixture("valkey-8.x")).displayName, "Valkey 8.1.1")
        XCTAssertEqual(try detector.detect(info: Self.fixture("redis-7.4")).role, "slave")
    }

    func testUnknownServerIsRedisCompatible() throws {
        let identity = try detector.detect(info: Self.fixture("unrecognized"))
        XCTAssertEqual(identity.kind, .unrecognized)
        XCTAssertNil(identity.version)
        XCTAssertEqual(identity.mode, .standalone)
        XCTAssertEqual(identity.displayName, "Redis-compatible (unrecognized)")
        // An empty or missing INFO (a managed service that disables it) still connects as unrecognized.
        XCTAssertEqual(try detector.detect(info: "").kind, .unrecognized)
    }

    func testRefusesBelowRedis6() throws {
        XCTAssertThrowsError(try detector.detect(info: Self.fixture("redis-5.0.7"))) { error in
            let failure = error as? ConnectionFailure
            XCTAssertEqual(failure?.category, .unsupportedServer)
            XCTAssertEqual(failure?.category.rawValue, "UNSUPPORTED_SERVER")
            XCTAssertTrue(failure?.message.hasPrefix("Keel requires Redis 6.0 or later; this server is Redis 5.0.7") ?? false, failure?.message ?? "")
        }
        XCTAssertThrowsError(try detector.detect(info: "redis_version:4.0.14\r\n"))
        XCTAssertEqual(try detector.detect(info: "redis_version:6.0.0\r\n").kind, .redis, "6.0.0 is the minimum, not below it")
    }

    // MARK: - Detection order and parsing

    func testRulesApplyInOrder() throws {
        // Dragonfly reports redis_version too; Valkey 7.2 builds without valkey_version take redis_version.
        XCTAssertEqual(try detector.detect(info: "redis_version:6.2.11\r\ndragonfly_version:df-v1.9.0\r\n").kind, .dragonfly)
        let early = try detector.detect(info: "redis_version:7.2.4\r\nserver_name:Valkey\r\n")
        XCTAssertEqual(early.kind, .valkey)
        XCTAssertEqual(early.version?.text, "7.2.4")
        XCTAssertEqual(try detector.detect(info: "redis_version:7.2.4\r\nvalkey_version:8.0.0\r\n").kind, .valkey)
        // KeyDB isn't detected separately in v1.
        XCTAssertEqual(try detector.detect(info: "redis_version:6.3.4\r\nredis_mode:standalone\r\n").kind, .redis)
    }

    func testModeFromRedisModeAndRole() throws {
        let cluster = try detector.detect(info: "redis_version:7.4.1\r\nredis_mode:cluster\r\n# Replication\r\nrole:slave\r\n")
        XCTAssertEqual(cluster.mode, .cluster, "redis_mode wins over role")
        XCTAssertTrue(cluster.showsClusterBanner)
        XCTAssertEqual(ServerIdentity.clusterBannerText, "Cluster mode: browsing this node only")
        XCTAssertEqual(try detector.detect(info: "redis_version:7.4.1\r\nredis_mode:sentinel\r\n").mode, .sentinel)
        XCTAssertEqual(try detector.detect(info: "redis_version:7.4.1\r\nrole:replica\r\n").mode, .replica)
    }

    func testBundledRulesMatchSpecOrder() {
        let rules = ServerDetectionRules.bundled
        XCTAssertEqual(rules.version, 1)
        XCTAssertEqual(rules.rules.map(\.server), [.dragonfly, .valkey, .redis])
        XCTAssertEqual(rules.rules.last?.minimumVersion, "6.0")
    }

    func testVersionParsing() {
        XCTAssertEqual(ServerVersion("df-v1.21.2")?.components, [1, 21, 2])
        XCTAssertEqual(ServerVersion("7.2.4-rc1")?.components, [7, 2, 4])
        XCTAssertNil(ServerVersion("unknown"))
        XCTAssertEqual(ServerVersion("6.0"), ServerVersion("6.0.0"))
        XCTAssertLessThan(ServerVersion("5.0.7")!, ServerVersion("6.0")!)
        XCTAssertLessThan(ServerVersion("6.9.9")!, ServerVersion("6.10")!)
    }
}
