import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

final class KeyListRowMetadataReviewTests: XCTestCase {
    /// Rows scrolled in from the fetch margin are cached already, so no cell asks for content; scrolling must still
    /// bring their type and TTL, here from what the index learned while they were off screen.
    @MainActor func testRowsScrolledInFromMarginShowMetadata() async throws {
        let index = offlineIndex()
        await index.ingest((0..<200).map { Data("k\($0)".utf8) })
        let loader = RowMetadataLoader(index: index, sleep: { _ in })
        let list = KeyListDataSource(index: index, mode: .flat, metadataLoader: loader)
        list.scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: KeyListDataSource.rowHeight * 4)
        await list.reload()
        await list.fetchVisibleContent()
        // Row 20 sits in the fetch margin: cached, without metadata.
        XCTAssertEqual(try XCTUnwrap(list.row(at: 20)).type, .unknown)

        let generation = await index.generation
        _ = await index.applyMetadata([RowMetadataResult(index: 20, type: .hash, expiry: .persistent)], generation: generation)
        list.scrollView.contentView.scroll(to: NSPoint(x: 0, y: KeyListDataSource.rowHeight * 18))
        XCTAssertTrue(list.activeView.rows(in: list.activeView.visibleRect).contains(20))

        for _ in 0..<200 where list.row(at: 20)?.type != .hash { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(list.row(at: 20)?.type, .hash)
        XCTAssertEqual(list.activeView.view(atColumn: 0, row: 20, makeIfNecessary: true)?.accessibilityLabel(), "k20, hash")
    }

    func testRowNeedsMetadataUntilKnown() {
        var row = KeyListRow(child: .key(0), name: "k", keyCount: 1)
        XCTAssertTrue(row.needsMetadata(showsSizes: false))
        row.type = .hash; row.expiry = .persistent
        XCTAssertFalse(row.needsMetadata(showsSizes: false))
        XCTAssertTrue(row.needsMetadata(showsSizes: true))
        row.expiry = .gone
        XCTAssertFalse(row.needsMetadata(showsSizes: true), "a gone key needs nothing more")
    }
}
