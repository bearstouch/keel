import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review-driven edge cases of the hash editor in the shell (KEEL-030).
final class HashEditorSessionReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    private actor Loads {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    /// A "Load more" page that lands after a Reload belongs to the old scan: it must neither join the reloaded rows nor
    /// move the cursor.
    @MainActor func testLoadMoreLandingAfterReloadIsDropped() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let loads = Loads()
        let key = d("h")
        let binding = EditorBinding(
            load: { key, _, _ in
                let count = await loads.next()
                let row = EditorRow(id: Data("load\(count)".utf8), value: Data("v".utf8))
                return LoadedValue(rows: [row], watch: WatchGuard(key: key, reads: [], expected: []), next: Data("cursor\(count)".utf8))
            },
            writes: { _, _, _ in [] },
            loadMore: { _, _, _, _ in
                for await _ in gate { break }
                return EditorPage(rows: [EditorRow(id: Data("stale".utf8), value: Data("old".utf8))], next: Data("stale-cursor".utf8))
            })
        let service = TransactionalKeyspace(hashes: [:]).session("h", type: .hash).service
        let editor = EditorSession(
            key: key, type: .hash, binding: binding, service: service, context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
        await editor.load()
        let more = Task { await editor.loadMore() }
        while !editor.isLoadingMore { await Task.yield() }
        await editor.reload()
        XCTAssertEqual(editor.loaded?.rows.map(\.id), [d("load2")])
        open.yield(); open.finish()
        await more.value
        XCTAssertEqual(editor.loaded?.rows.map(\.id), [d("load2")], "the old scan's page is dropped")
        XCTAssertEqual(editor.draft.map(\.id), [d("load2")])
        XCTAssertEqual(editor.loaded?.next, d("cursor2"), "the cursor stays the reloaded scan's")
        XCTAssertFalse(editor.isLoadingMore)
        XCTAssertTrue(editor.canLoadMore)
    }
}
