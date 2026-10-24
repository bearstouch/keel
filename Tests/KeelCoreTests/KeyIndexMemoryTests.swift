import Darwin
import Foundation
import XCTest

@testable import KeelCore

/// NFR-RS01: ≤ 120 bytes per loaded key beyond the key bytes for the index; with the namespace tree, 1M keys of ~30
/// bytes stay under 200 MB in total. Measured on 100k synthetic ~30-byte keys.
final class KeyIndexMemoryTests: XCTestCase {
    func testBytesPerKeyBudget() async {
        let count = 100_000
        // "session:user:00000042:token:ab" style names, 30 bytes each. Every key opens two folders of its own
        // (`session:user:00000042` and `…:token`), the tree's worst realistic shape.
        let names = (0..<count).map { Data(String(format: "session:user:%08d:token:%02x", $0, $0 % 256).utf8) }
        XCTAssertEqual(names[0].count, 30)

        let before = Self.heapInUse()
        let index = KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        for page in stride(from: 0, to: count, by: 1_000) { await index.ingest(Array(names[page..<page + 1_000])) }
        let heapGrowth = Self.heapInUse() - before

        let loaded = await index.count
        let keyBytes = await index.keyBytes
        let storage = await index.storageBytes
        let treeStorage = await index.treeStorageBytes
        XCTAssertEqual(loaded, count)
        let overheadPerKey = Double(storage - keyBytes) / Double(count)
        let treePerKey = Double(treeStorage) / Double(count)
        let heapPerKey = Double(heapGrowth) / Double(count)
        print("KeyIndex memory: \(overheadPerKey) B/key index buffers beyond key bytes, \(treePerKey) B/key tree, \(heapPerKey) B/key heap in total")
        BenchmarkRecorder.record("xctest.index_overhead_per_key", bytes: overheadPerKey)
        // The heap holds the key bytes, the index and the tree: projected to 1M keys it stays under 200 MB.
        let projectedOneMillion = Double(storage + treeStorage) / Double(count) * 1_000_000
        BenchmarkRecorder.record("xctest.index_and_tree_1m_projected", bytes: projectedOneMillion)
        XCTAssertLessThanOrEqual(overheadPerKey, 120, "index buffers: \(overheadPerKey) B/key")
        XCTAssertLessThan(projectedOneMillion, 200 * 1_048_576)
        XCTAssertLessThan(heapPerKey * 1_000_000, 200 * 1_048_576, "heap: \(heapPerKey) B/key")
    }

    /// Bytes currently allocated in every malloc zone of this process.
    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
}
