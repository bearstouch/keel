import Darwin
import Foundation
import XCTest

@testable import KeelCore

/// NFR-RS01: ≤ 120 bytes per loaded key beyond the key bytes. Measured on 100k synthetic ~30-byte keys.
final class KeyIndexMemoryTests: XCTestCase {
    func testBytesPerKeyBudget() async {
        let count = 100_000
        // "session:user:00000042:token:ab" style names, 30 bytes each.
        let names = (0..<count).map { Data(String(format: "session:user:%08d:token:%02x", $0, $0 % 256).utf8) }
        XCTAssertEqual(names[0].count, 30)

        let before = Self.heapInUse()
        let index = KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        for page in stride(from: 0, to: count, by: 1_000) { await index.ingest(Array(names[page..<page + 1_000])) }
        let heapGrowth = Self.heapInUse() - before

        let loaded = await index.count
        let keyBytes = await index.keyBytes
        let storage = await index.storageBytes
        XCTAssertEqual(loaded, count)
        let overheadPerKey = Double(storage - keyBytes) / Double(count)
        let heapOverheadPerKey = Double(heapGrowth - keyBytes) / Double(count)
        print("KeyIndex memory: \(overheadPerKey) B/key buffers, \(heapOverheadPerKey) B/key heap beyond key bytes")
        XCTAssertLessThanOrEqual(overheadPerKey, 120, "buffers: \(overheadPerKey) B/key")
        XCTAssertLessThanOrEqual(heapOverheadPerKey, 120, "heap: \(heapOverheadPerKey) B/key")
        // AC5 projection for the index alone: 1M keys of ~30 bytes stay well under 200 MB.
        XCTAssertLessThan(Double(storage) / Double(count) * 1_000_000, 200 * 1_048_576)
    }

    /// Bytes currently allocated in every malloc zone of this process.
    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
}
