import Foundation
import XCTest

@testable import KeelCore

/// NFR-PF03: SCAN ingestion of 1,000,000 keys (COUNT 1,000, auto-page) completes in under 15 s. The fake transport
/// answers every page at once, so this times Keel's side alone: encoding, the RESP parser, the safety check, dedup into
/// the arena and the namespace tree's incremental extend. `scripts/bench-browser.py` times the same path against a
/// real server.
final class ScanIngestionPerformanceTests: XCTestCase {
    static let total = 1_000_000, pageSize = 1_000

    /// The `step`th key in SCAN's scrambled order (a step coprime with 1M visits every number once): half in one wide
    /// folder and half spread over 1,000 × 10 nested folders, ~30 bytes each.
    static func key(_ step: Int) -> String {
        let i = step * 7_919 % total
        return i.isMultiple(of: 2) ? String(format: "session:%08d:token", i) : String(format: "user:%04d:%02d:cart:%08d", i % 1_000, i % 10, i)
    }

    /// Cursor `n` returns keys `n·1000 ..< (n+1)·1000`.
    static func server() -> RecordingServer {
        RecordingServer { arguments in
            guard arguments.first == "SCAN", let cursor = Int(arguments[1]), cursor * pageSize < total else { return "-ERR unexpected\r\n" }
            let keys = (cursor * pageSize..<(cursor + 1) * pageSize).map(key)
            return ScanServer.reply(cursor: (cursor + 1) * pageSize == total ? 0 : cursor + 1, keys: keys)
        }
    }

    func testOneMillionKeys() async throws {
        let clock = ContinuousClock()
        var runs: [Duration] = []
        // Two full scans: the first warms allocator and caches, the slower of the two is the one held to the budget.
        for _ in 0..<2 {
            let server = Self.server()
            let context = DataContext(profile: SafetyProfile(name: "local", readOnly: true))
            let index = KeyIndex(service: DataCommandService(session: server.session()), context: context, configuration: KeyIndexConfiguration(pageSize: Self.pageSize))
            let start = clock.now
            let status = await index.autoPage()
            runs.append(clock.now - start)

            XCTAssertEqual(status.phase, .complete)
            XCTAssertEqual(status.loadedCount, Self.total)
            XCTAssertEqual(server.allCommands.count, Self.total / Self.pageSize, "one SCAN per page, nothing else")
            let root = await index.namespaceKeyCount(of: .root)
            XCTAssertEqual(root, Self.total, "the tree took every key as it arrived")
        }
        let slowest = try XCTUnwrap(runs.max())
        print("SCAN ingestion 1M keys: \(runs.map(\.description).joined(separator: ", "))")
        BenchmarkRecorder.record("xctest.scan_ingestion_1m", slowest)
        XCTAssertLessThan(slowest, .seconds(15 * PerformanceBudget.slack))
    }
}
