import Foundation
import XCTest

@testable import KeelCore

/// The Info overview (KEEL-042, FR-SI01, FR-SI02, FR-SI04): tiles, databases and health from one `INFO` reply.
final class InfoOverviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_729_673_000)

    func testTileValues() throws {
        let valkey = InfoOverview(report: InfoReport(text: try InfoParserTests.fixture("full/valkey-8.x")), now: now)
        XCTAssertEqual(
            valkey.tiles,
            [
                InfoTile(label: "Memory", value: "1.2", unit: "of 4 GB", fraction: 1_288_490_188.0 / 4_294_967_296.0),
                InfoTile(label: "Clients", value: "48"), InfoTile(label: "Operations", value: "3,412", unit: "per sec"),
                InfoTile(label: "Uptime", value: "12", unit: "days")
            ])
        XCTAssertEqual(valkey.tiles[0].accessibilityLabel, "Memory, 1.2 of 4 GB, 30 percent")
        XCTAssertEqual(
            valkey.databases, [InfoDatabase(index: 0, keys: 1_204_551, expires: 1000, averageTTL: 7_200_000), InfoDatabase(index: 3, keys: 1822)])
        XCTAssertEqual(valkey.databases.map(\.summary), ["1,204,551 keys · 1,000 expiring, avg TTL 2 h", "1,822 keys"])
        XCTAssertEqual(
            valkey.health,
            [
                InfoHealthItem(label: "Replication", value: "2 replicas in sync"), InfoHealthItem(label: "Last save", value: "6 minutes ago"),
                InfoHealthItem(label: "Hit ratio", value: "97.8%")
            ])

        // No maxmemory: used memory alone, no bar. Uptime under a minute is seconds; one lookup that hit is 100%.
        let redis = InfoOverview(report: InfoReport(text: try InfoParserTests.fixture("full/redis-7.2")), now: now)
        XCTAssertEqual(redis.tiles[0], InfoTile(label: "Memory", value: "1.2", unit: "MB"))
        XCTAssertEqual(redis.tiles[3], InfoTile(label: "Uptime", value: "0", unit: "seconds"))
        XCTAssertEqual(redis.health.map(\.value), ["No replicas", "just now", "100.0%"])
        XCTAssertEqual(redis.databases.map(\.summary), ["1 key", "1 key · 1 expiring"])

        // Dragonfly: memory in MB against an 8 GB limit, a replica count without per-replica lines, no rdb save time.
        let dragonfly = InfoOverview(report: InfoReport(text: try InfoParserTests.fixture("full/dragonfly")), now: now)
        XCTAssertEqual(dragonfly.tiles[0].value, "0"); XCTAssertEqual(dragonfly.tiles[0].unit, "of 8 GB")
        XCTAssertEqual(dragonfly.tiles[3], InfoTile(label: "Uptime", value: "42", unit: "seconds"))
        XCTAssertEqual(dragonfly.health.map(\.value), ["1 replica", "unavailable", "No reads yet"])

        // A missing field is "—" with "unavailable", never a made-up zero.
        let empty = InfoOverview(report: InfoReport(text: ""), now: now)
        XCTAssertEqual(empty.tiles.map(\.value), ["—", "—", "—", "—"])
        XCTAssertEqual(empty.tiles.map(\.accessibilityLabel), ["Memory, unavailable", "Clients, unavailable", "Operations, unavailable", "Uptime, unavailable"])
        XCTAssertEqual(empty.health.map(\.value), ["unavailable", "unavailable", "unavailable"])
        XCTAssertTrue(empty.databases.isEmpty)
    }

    func testFormattingEdges() {
        XCTAssertEqual(InfoOverview.bytes(1023, unitOf: 1023).value, "1023"); XCTAssertEqual(InfoOverview.bytes(1023, unitOf: 1023).unit, "B")
        XCTAssertEqual(InfoOverview.bytes(1536, unitOf: 1536).value, "1.5"); XCTAssertEqual(InfoOverview.bytes(1536, unitOf: 1536).unit, "KB")
        XCTAssertEqual(InfoOverview.bytes(4 << 30, unitOf: 4 << 30).value, "4")
        XCTAssertEqual(InfoOverview.relative(seconds: 59), "just now")
        XCTAssertEqual(InfoOverview.relative(seconds: 3_600), "1 hour ago")
        XCTAssertEqual(InfoOverview.relative(seconds: -30), "just now")
        // Over the limit (memory can exceed maxmemory briefly): the bar stops full.
        let over = InfoOverview.memory(InfoReport(text: "used_memory:2048\r\nmaxmemory:1024\r\n"))
        XCTAssertEqual(over.fraction, 1); XCTAssertEqual(over.value, "2"); XCTAssertEqual(over.unit, "of 1 KB")
        // A replica, and a primary with a replica out of sync.
        XCTAssertEqual(
            InfoOverview.replication(InfoReport(text: "role:slave\r\nmaster_host:10.0.0.5\r\nmaster_port:6379\r\nmaster_link_status:down\r\n")),
            "Replica of 10.0.0.5:6379, link down")
        XCTAssertEqual(
            InfoOverview.replication(InfoReport(text: "# Replication\r\nrole:master\r\nconnected_slaves:2\r\nslave0:ip=a,port=1,state=online\r\nslave1:ip=b,port=1,state=wait_bgsave\r\n")),
            "2 replicas, 1 in sync")
        XCTAssertEqual(InfoOverview.lastSave(InfoReport(text: "rdb_last_save_time:1729672640\r\nrdb_last_bgsave_status:err\r\n"), now: now), "Failed · 6 minutes ago")
    }

    /// Hostile INFO: memory at Int64.max (a double rounds it to 2^63, past Int64) and against a tiny limit, and
    /// infinite hit counts, render text instead of trapping.
    func testHostileNumbersNeverTrap() {
        let huge = InfoOverview.memory(InfoReport(text: "used_memory:9223372036854775807\r\n"))
        XCTAssertEqual(huge.value, "8192"); XCTAssertEqual(huge.unit, "PB")
        let tinyLimit = InfoOverview.memory(InfoReport(text: "used_memory:9223372036854775807\r\nmaxmemory:1\r\n"))
        XCTAssertEqual(tinyLimit.value, "9223372036854775807"); XCTAssertEqual(tinyLimit.unit, "of 1 B"); XCTAssertEqual(tinyLimit.fraction, 1)
        let kilobytes = InfoOverview.memory(InfoReport(text: "used_memory:9223372036854775807\r\nmaxmemory:1024\r\n"))
        XCTAssertEqual(kilobytes.value, "9007199254740992"); XCTAssertEqual(kilobytes.unit, "of 1 KB")
        XCTAssertEqual(InfoOverview.bytes(.max, unitOf: .max).value, "8192")
        XCTAssertEqual(InfoOverview.hitRatio(InfoReport(text: "keyspace_hits:inf\r\nkeyspace_misses:1\r\n")), InfoOverview.unavailable)
        XCTAssertEqual(InfoOverview.hitRatio(InfoReport(text: "keyspace_hits:1e308\r\nkeyspace_misses:1e308\r\n")), InfoOverview.unavailable)
        _ = InfoOverview(report: InfoReport(text: "used_memory:9223372036854775807\r\nmaxmemory:9223372036854775807\r\nuptime_in_seconds:9223372036854775807\r\nrdb_last_save_time:9223372036854775807\r\n"), now: now)
    }
}
