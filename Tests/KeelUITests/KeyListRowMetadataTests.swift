import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// A clock the test moves by hand; the loader and the list's countdown both read it.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Duration.zero
    var now: Duration { lock.withLock { time } }
    func advance(_ duration: Duration) { lock.withLock { time += duration } }
}

final class KeyListRowMetadataTests: XCTestCase {
    /// A flat list of `keys` with a metadata loader on `clock`, sized so a few rows are on screen.
    @MainActor private func list(_ keys: [String], clock: ManualClock) async -> KeyListDataSource {
        let index = offlineIndex()
        await index.ingest(keys.map { Data($0.utf8) })
        let loader = RowMetadataLoader(index: index, now: { clock.now }, sleep: { _ in })
        let list = KeyListDataSource(index: index, mode: .flat, metadataLoader: loader)
        list.scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: KeyListDataSource.rowHeight * 4)
        await list.reload()
        await list.fetchVisibleContent()
        return list
    }

    @MainActor private func label(_ list: KeyListDataSource, row: Int) -> String? {
        list.activeView.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel()
    }

    @MainActor private func store(_ list: KeyListDataSource, _ results: [RowMetadataResult]) async {
        let generation = await list.index.generation
        let changed = await list.index.applyMetadata(results, generation: generation)
        await list.refreshRows(ofKeys: Set(changed))
    }

    @MainActor func testTTLCountsDownLocally() async throws {
        let clock = ManualClock()
        let list = await list(["session:a", "user:1"], clock: clock)
        // `EXPIRE 90` on session:a; user:1 has no expiry and stays quiet.
        await store(list, [RowMetadataResult(index: 0, type: .string, expiry: .expires(atMilliseconds: 90_000)), RowMetadataResult(index: 1, type: .hash, expiry: .persistent)])
        XCTAssertEqual(label(list, row: 0), "session:a, string, expires in 1 minute 30 seconds")
        XCTAssertEqual(label(list, row: 1), "user:1, hash")
        let shown = try XCTUnwrap(list.row(at: 0)).presented(at: 0, showsSizes: false)
        XCTAssertEqual(shown.meta, "1m 30s")
        XCTAssertNil(try XCTUnwrap(list.row(at: 1)).presented(at: 0, showsSizes: false).meta)

        // The countdown re-reads the clock only: one tick after 30 s shows "1m", after 90 s "expired" (AC3).
        clock.advance(.seconds(30))
        list.tickCountdowns()
        XCTAssertEqual(label(list, row: 0), "session:a, string, expires in 1 minute")
        clock.advance(.seconds(60))
        list.tickCountdowns()
        XCTAssertEqual(label(list, row: 0), "session:a, string, expired")
        XCTAssertEqual(try XCTUnwrap(list.row(at: 0)).presented(at: 90_000, showsSizes: false).meta, "expired")
    }

    @MainActor func testGoneKeyReadsExpired() async throws {
        let list = await list(["session:a"], clock: ManualClock())
        await store(list, [RowMetadataResult(index: 0, expiry: .gone)])
        XCTAssertEqual(label(list, row: 0), "session:a, expired")
        let stale = await list.index.metadata(at: 0).isStale
        XCTAssertTrue(stale)
    }

    @MainActor func testSizesShowOnlyWhenAsked() async throws {
        let list = await list(["user:1"], clock: ManualClock())
        await store(list, [RowMetadataResult(index: 0, type: .hash, expiry: .persistent, size: .bytes(4_198))])
        XCTAssertFalse(list.showsSizes)
        XCTAssertEqual(label(list, row: 0), "user:1, hash")

        await list.setShowsSizes(true)
        XCTAssertEqual(label(list, row: 0), "user:1, hash, 4.1 KB")
        XCTAssertEqual(try XCTUnwrap(list.row(at: 0)).presented(at: 0, showsSizes: true).meta, "4.1 KB")
        let loaderShows = await list.metadataLoader?.showsSizes
        XCTAssertEqual(loaderShows, true)

        await list.setShowsSizes(false)
        XCTAssertEqual(label(list, row: 0), "user:1, hash")
    }

    @MainActor func testVisibleKeysExcludeFoldersAndMargin() async throws {
        let list = await list((0..<200).map { "k\($0)" }, clock: ManualClock())
        // The loader is asked for rows on screen only, never the fetch margin around them.
        XCTAssertEqual(list.keys(inRows: 0..<4), [0, 1, 2, 3])
        XCTAssertEqual(list.keys(inRows: 198..<260), [198, 199])
        await list.setMode(.tree)
        let tree = await keyList(["a:1", "a:2", "b"])
        XCTAssertEqual(tree.keys(inRows: 0..<2), [2], "the folder row `a` needs no metadata")
    }

    func testBadgesHaveText() {
        // AC4: every loaded type has a text badge and a spoken name; color is never the only signal (DS-04).
        for type in KeyType.allCases where type != .unknown {
            XCTAssertNotNil(KeyListRow.badge(type), "\(type)")
            XCTAssertNotNil(KeyListRow.spoken(type), "\(type)")
        }
        XCTAssertNil(KeyListRow.badge(.unknown), "no badge until the type is loaded")
    }
}
