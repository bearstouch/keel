import Foundation
import XCTest

@testable import KeelCore

/// NFR-PF06: opening a value shows its first page in under 300 ms for any type, independent of the value's total size
/// (hash with 1M fields, list with 10M items, 64 MiB string). The fake server only claims those sizes and builds each
/// page it is asked for on the fly, so a load that read more than its first page would show in the commands, and one
/// whose cost grew with the size would show in the time.
final class ValueOpenPerformanceTests: XCTestCase {
    static let hashFields = 1_000_000, listItems = 10_000_000, setMembers = 1_000_000, zsetMembers = 1_000_000
    static let stringBytes = 64 * 1_048_576

    private static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }
    private static func array(_ items: [String]) -> String { "*\(items.count)\r\n" + items.joined() }

    /// `HSCAN`/`SSCAN` cursors are offsets; `COUNT` items a round, cursor 0 after the last.
    private static func scan(_ arguments: [String], total: Int, pair: Bool) -> String {
        let start = Int(arguments[2]) ?? 0, count = Int(arguments[4]) ?? 10, end = min(start + count, total)
        let items = (start..<end).flatMap { pair ? [bulk("field:\($0)"), bulk("value:\($0)")] : [bulk("member:\($0)")] }
        return "*2\r\n" + bulk(String(end == total ? 0 : end)) + array(items)
    }

    static func server() -> RecordingServer {
        let page = String(repeating: "x", count: Int(StringEditor.fullLoadLimit))
        return RecordingServer { arguments in
            switch arguments.first {
            case "HLEN": return ":\(hashFields)\r\n"
            case "HSCAN": return scan(arguments, total: hashFields, pair: true)
            case "SCARD": return ":\(setMembers)\r\n"
            case "SSCAN": return scan(arguments, total: setMembers, pair: false)
            case "LLEN": return ":\(listItems)\r\n"
            case "LRANGE":
                let start = Int(arguments[2]) ?? 0, stop = min(Int(arguments[3]) ?? 0, listItems - 1)
                return array((start...stop).map { bulk("item:\($0)") })
            case "ZRANGE" where !arguments.contains("LIMIT"): return "*0\r\n"  // The `BYSCORE` capability probe.
            case "ZRANGE":
                let limit = arguments.firstIndex(of: "LIMIT")!
                let offset = Int(arguments[limit + 1]) ?? 0, count = Int(arguments[limit + 2]) ?? 0
                return array((offset..<min(offset + count, zsetMembers)).flatMap { [bulk("member:\($0)"), bulk(String($0))] })
            case "XREVRANGE":
                // Newest first: IDs count down from the stream's last entry.
                let count = Int(arguments[5]) ?? 0
                return array((0..<count).map { "*2\r\n" + bulk("\(1_700_000_000_000 - $0)-0") + array([bulk("field"), bulk("value:\($0)")]) })
            case "STRLEN": return ":\(stringBytes)\r\n"
            case "GETRANGE": return bulk(page)
            default: return "-ERR unexpected \(arguments.first ?? "")\r\n"
            }
        }
    }

    func testLargeCollectionsFirstPage() async throws {
        typealias Load = @Sendable (Data, DataCommandService, DataContext) async throws -> LoadedValue
        let cases: [(name: String, key: String, rows: Int, load: Load)] = [
            ("hash_1m", "hash", HashEditor.pageSize, { try await HashEditor.load(key: $0, service: $1, context: $2) }),
            ("list_10m", "list", ListEditor.pageSize, { try await ListEditor.load(key: $0, service: $1, context: $2) }),
            ("set_1m", "set", SetEditor.pageSize, { try await SetEditor.load(key: $0, service: $1, context: $2) }),
            ("zset_1m", "zset", SortedSetEditor.pageSize, { try await SortedSetEditor.load(key: $0, service: $1, context: $2) }),
            ("stream", "stream", StreamEditor.pageSize, { try await StreamEditor.load(key: $0, service: $1, context: $2) }),
            ("string_64mib", "string", 1, { try await StringEditor.load(key: $0, service: $1, context: $2) })
        ]
        let clock = ContinuousClock(), context = DataContext(profile: SafetyProfile(name: "local", readOnly: true))
        for (name, key, rows, load) in cases {
            let server = Self.server(), service = DataCommandService(session: server.session())
            var opens: [Duration] = []
            // One warm-up open (connection, capability probe), then three timed ones; the slowest is held to the budget.
            for attempt in 0..<4 {
                let start = clock.now
                let value = try await load(Data(key.utf8), service, context)
                if attempt > 0 { opens.append(clock.now - start) }
                XCTAssertEqual(value.rows.count, rows, name)
                if key == "string" {
                    XCTAssertEqual(value.partial?.loadedBytes, StringEditor.fullLoadLimit, "only the first 1 MiB")
                    XCTAssertEqual(value.partial?.totalBytes, Int64(Self.stringBytes))
                } else {
                    XCTAssertNotNil(value.next, "\(name): more pages follow")
                }
            }
            // Never a whole-value read, whatever the size.
            let sent = Set(server.allCommands.compactMap(\.first))
            XCTAssertTrue(sent.isDisjoint(with: ["HGETALL", "SMEMBERS", "GET", "XRANGE"]), "\(name): \(sent)")
            let slowest = try XCTUnwrap(opens.max())
            print("Value open \(name): first page in \(slowest) (max of \(opens.count))")
            BenchmarkRecorder.record("xctest.value_open_\(name)", slowest)
            XCTAssertLessThan(slowest, .milliseconds(300 * PerformanceBudget.slack), name)
        }
    }
}
