import Foundation
import XCTest

@testable import KeelCore

/// The `INFO` parser behind Info mode (KEEL-042, FR-SI01, FR-SI05): every section and line kept, unknown ones included.
final class InfoParserTests: XCTestCase {
    static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/INFO/\(name).txt"),
            encoding: .utf8)
    }

    static let fixtures = ["full/redis-7.2", "full/valkey-8.x", "full/dragonfly", "redis-6.0", "redis-7.4", "redis-8.0", "valkey-7.2", "valkey-9.x", "dragonfly", "unrecognized"]

    func testParsesAllSections() throws {
        for name in Self.fixtures {
            // The fixtures keep INFO's CRLF line ends; LF alone parses the same. The walk below reads the LF form.
            let report = InfoReport(text: try Self.fixture(name))
            let text = try Self.fixture(name).replacingOccurrences(of: "\r\n", with: "\n")
            XCTAssertEqual(report, InfoReport(text: text), name)

            // Walk the file: each header opens its section, each line lands in it, in order, with its value intact.
            var expected: [(String, [InfoField])] = []
            for line in text.split(separator: "\n") where !line.isEmpty {
                if line.hasPrefix("# ") { expected.append((String(line.dropFirst(2)), [])); continue }
                let colon = try XCTUnwrap(line.firstIndex(of: ":"), "\(name): \(line)")
                expected[expected.count - 1].1.append(InfoField(name: String(line[..<colon]), value: String(line[line.index(after: colon)...])))
            }
            XCTAssertEqual(report.sections.map(\.name), expected.map(\.0), name)
            XCTAssertEqual(report.sections.map(\.fields), expected.map(\.1), name)
            XCTAssertEqual(report.lines, text.split(separator: "\n").map(String.init), name)
        }

        let redis = InfoReport(text: try Self.fixture("full/redis-7.2"))
        XCTAssertEqual(redis.sections.map(\.name), ["Server", "Clients", "Memory", "Persistence", "Stats", "Replication", "CPU", "Modules", "Errorstats", "Cluster", "Keyspace"])
        XCTAssertEqual(redis["redis_version"], "7.2.1")
        XCTAssertEqual(redis.section("keyspace")?.fields.map(\.name), ["db0", "db3"])
        // Every overview section is there; nothing is unavailable, and the server's extra sections follow.
        XCTAssertEqual(redis.sectionStatuses.map(\.title), InfoReport.expectedSections + ["Modules", "Errorstats", "Cluster"])
        XCTAssertFalse(redis.sectionStatuses.contains { if case .unavailable = $0 { true } else { false } })
    }

    func testKeepsUnknownFields() throws {
        let dragonfly = InfoReport(text: try Self.fixture("full/dragonfly"))
        // Dragonfly's own section and fields are kept and listed after the expected sections.
        XCTAssertEqual(dragonfly.section("Transaction")?.fields, [InfoField(name: "tx_shard_polls", value: "0"), InfoField(name: "tx_type_cnt", value: "global=0,normal=12,ooo=3")])
        XCTAssertEqual(dragonfly["dragonfly_version"], "df-v1.21.2")
        XCTAssertEqual(dragonfly["object_used_memory"], "65536")
        XCTAssertEqual(dragonfly.sectionStatuses.map(\.title), InfoReport.expectedSections + ["Transaction"])

        // A value with colons, a line without one, lines before any header and a repeated header all survive.
        let odd = InfoReport(text: "orphan:1\r\n# Server\r\nexecutable:/a:b\r\nweird line\r\n# Stats\r\nx:1\r\n# Server\r\nlate:2\r\n")
        XCTAssertEqual(odd.sections.map(\.title), ["Other", "Server", "Stats"])
        XCTAssertEqual(odd.section("Server")?.fields, [InfoField(name: "executable", value: "/a:b"), InfoField(name: "weird line", value: ""), InfoField(name: "late", value: "2")])
        XCTAssertEqual(odd["orphan"], "1")

        // A sections-limited reply (Redis 6.0's INFO server + replication): the rest are unavailable, not dropped (FR-SI05).
        let old = InfoReport(text: try Self.fixture("redis-6.0"))
        let unavailable = old.sectionStatuses.compactMap { if case .unavailable(let name) = $0 { name } else { nil } }
        XCTAssertEqual(unavailable, ["Memory", "Clients", "Keyspace", "Persistence", "Stats", "CPU"])
        // A refused INFO gives no sections: every expected one is unavailable.
        XCTAssertEqual(InfoReport(text: "").sectionStatuses, InfoReport.expectedSections.map { .unavailable(name: $0) })

        // Raw search keeps whole lines, ignoring case.
        XCTAssertEqual(dragonfly.rawLines(matching: "MAXMEMORY"), ["maxmemory:8589934592", "maxmemory_human:8.00GiB"])
        XCTAssertEqual(dragonfly.rawLines(matching: " ").count, dragonfly.lines.count)
    }
}
