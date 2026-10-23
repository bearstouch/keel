import Foundation
import XCTest

@testable import KeelCore

/// AC3: a local filter over 1M loaded keys shows its first results in under 150 ms. The search runs in chunks of
/// `KeyIndex.localSearchChunk` keys and the list shows each chunk's matches as they come, so the budget is the time
/// to the first chunk that has any. It holds in optimized builds (`swift test -c release -Xswiftc -enable-testing`);
/// debug builds, as CI runs them, only guard against gross regressions with a looser bound.
final class LocalFilterPerformanceTests: XCTestCase {
    #if DEBUG
        static let slack = 5.0
    #else
        static let slack = 1.0
    #endif

    func testFirstResultsBudget() async throws {
        let index = TypedKeyspace(pages: []).index()
        // 1M keys of ~25 bytes in SCAN's scrambled order; one in 1,000 is an `invoice`, so a query for it must read
        // through ~1,000 keys before its first match and the whole chunk to fill the first screen.
        var batch: [Data] = []
        batch.reserveCapacity(100_000)
        for step in 0..<1_000_000 {
            let i = step * 7_919 % 1_000_000
            batch.append(Data((i.isMultiple(of: 1_000) ? String(format: "invoice:%08d:pdf", i) : String(format: "session:%08d:token", i)).utf8))
            if batch.count == 100_000 { await index.ingest(batch); batch.removeAll(keepingCapacity: true) }
        }
        let loaded = await index.count
        XCTAssertEqual(loaded, 1_000_000)

        let clock = ContinuousClock()
        /// Chunks until the first one with matches, as the list asks for them; returns the time and the matches.
        func firstResults(_ text: String) async -> (Duration, LocalKeyMatches) {
            let query = LocalKeyQuery(text)
            let start = clock.now
            var matches = LocalKeyMatches(indices: [], searchedThrough: 0)
            while matches.indices.isEmpty, matches.searchedThrough < loaded {
                matches = await index.localMatches(query, from: matches.searchedThrough)
            }
            return (clock.now - start, matches)
        }

        var slowest = Duration.zero
        for text in ["INVOICE", "token", "00:t", "nothing-matches"] {
            let (elapsed, matches) = await firstResults(text)
            slowest = max(slowest, elapsed)
            print("Local filter 1M keys: \"\(text)\" first results in \(elapsed) (\(matches.indices.count) in the first chunk)")
            if text != "nothing-matches" { XCTAssertFalse(matches.indices.isEmpty, text) }
        }
        // A query with no match reads every key before saying so; it still counts against the first-chunk budget
        // per chunk, so time one chunk of it on its own.
        let start = clock.now
        let chunk = await index.localMatches(LocalKeyQuery("nothing-matches"))
        let oneChunk = clock.now - start
        XCTAssertEqual(chunk.searchedThrough, KeyIndex.localSearchChunk)
        print("Local filter 1M keys: one chunk of \(KeyIndex.localSearchChunk) keys in \(oneChunk); slowest first results \(slowest)")
        XCTAssertLessThan(oneChunk, .milliseconds(150 * Self.slack))
        // Every query above with a match finds one in its first chunk.
        let (invoice, _) = await firstResults("invoice")
        XCTAssertLessThan(invoice, .milliseconds(150 * Self.slack))
    }
}
