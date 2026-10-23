import AppKit
import XCTest
import os

@testable import KeelCore
@testable import KeelUI

/// Review-driven checks for the key list (KEEL-022): stale folder contents, index races and fetches during a scroll.
final class KeyListDataSourceReviewTests: XCTestCase {
    /// A list in a 10-row window, so only a page of rows is visible and fetched.
    @MainActor private func windowedList(_ count: Int, mode: KeyListDataSource.Mode) async -> (KeyListDataSource, NSWindow) {
        let index = offlineIndex()
        await index.ingest((0..<count).map { Data(String(format: "k%05d", $0).utf8) })
        let list = KeyListDataSource(index: index, mode: mode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.scrollView
        list.scrollView.frame = window.contentView!.bounds
        await list.reload()
        await list.fetchVisibleContent()
        return (list, window)
    }

    /// Holds the index actor busy for a while, so the list's next call waits for it.
    @MainActor private func blockIndex(_ index: KeyIndex, for duration: Duration) async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let micros = useconds_t(duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000)
        Task.detached {
            await index.updateMetadata(at: 0) { _ in
                started.withLock { $0 = true }; usleep(micros)
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A folder collapsed before a page loaded shows that page's keys when expanded again, not its earlier children.
    @MainActor func testReexpandedFolderShowsKeysLoadedWhileCollapsed() async throws {
        let list = await keyList(["session:a", "user:1"])
        try await list.expand(named: "session")
        XCTAssertEqual(list.names, ["session", "a", "user"])
        list.outlineView.collapseItem(list.outlineView.item(atRow: try XCTUnwrap(list.row(named: "session"))))

        await list.index.ingest([Data("session:b".utf8)])
        await list.reload()
        await list.fetchVisibleContent()
        try await list.expand(named: "session")
        XCTAssertEqual(list.names, ["session", "a", "b", "user"])
    }

    /// Clicking a row after the index restarted (the browser reloads only once a page lands) must not read past the
    /// keys now loaded; the reload then drops the selection.
    @MainActor func testSelectingARowAfterARestartDoesNotReadPastTheIndex() async throws {
        let list = await keyList(["a", "b", "c", "d", "e", "f"], mode: .flat)
        await list.index.restart()
        list.tableView.selectRowIndexes([5], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKey, 5)
        try await Task.sleep(for: .milliseconds(50))
        let bytes = await list.bytes(of: .key(5))
        XCTAssertNil(bytes)

        await list.index.ingest(["x", "y"].map { Data($0.utf8) })
        await list.reload()
        XCTAssertNil(list.selectedKey)
        XCTAssertEqual(list.visibleRowCount, 2)
    }

    /// Rows that scroll into view while a fetch is out get their content once it lands, instead of staying empty.
    @MainActor func testRowsScrolledIntoViewDuringAFetchAreFilled() async throws {
        let (list, window) = await windowedList(2_000, mode: .flat)
        defer { window.close() }
        try await blockIndex(list.index, for: .milliseconds(400))

        // The first jump schedules a fetch, which then waits for the busy index.
        list.tableView.scrollRowToVisible(1_000); list.scrollView.layoutSubtreeIfNeeded()
        _ = list.tableView.view(atColumn: 0, row: 1_000, makeIfNecessary: true)
        for _ in 0..<5 { await Task.yield() }
        // A second jump while it waits: these rows weren't in its range.
        list.tableView.scrollRowToVisible(1_500); list.scrollView.layoutSubtreeIfNeeded()
        _ = list.tableView.view(atColumn: 0, row: 1_500, makeIfNecessary: true)

        try await waitUntil { list.row(at: 1_500) != nil }
        XCTAssertEqual(list.row(at: 1_500)?.name, "k01500")
    }
}
