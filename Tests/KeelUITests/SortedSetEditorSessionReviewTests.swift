import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review-driven sorted set editor cases (KEEL-033).
final class SortedSetEditorSessionReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// An increment whose reply is lost is never re-sent: the member's score is read back, so the table shows what the
    /// server has rather than the old score (which invites a second increment).
    @MainActor func testUnknownIncrementOutcomeRereadsTheScore() async {
        let server = TransactionalKeyspace(zsets: ["board": [("a", 1), ("b", 2)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        server.dropNextExecReply = true
        await model.increment(d("a"), by: "5")
        XCTAssertNotNil(editor.actionFailure)
        XCTAssertEqual(server.scores("board")?["a"], 6)
        XCTAssertEqual(model.rows, [SortedSetEditor.row(d("b"), score: 2), SortedSetEditor.row(d("a"), score: 6)], "the server's score, not the old one")
        XCTAssertEqual(server.commands.filter { $0.first == "ZINCRBY" }.count, 1, "never re-sent")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    /// Removing a search match and saving: the member leaves the shown matches, rather than being listed as still there.
    @MainActor func testSavedRemovalLeavesSearchResults() async {
        let server = TransactionalKeyspace(zsets: ["board": [("user:1", 1), ("user:2", 2), ("order:1", 3)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        model.pattern = "user:*"
        await model.search()
        XCTAssertEqual(model.rows.map(\.id), [d("user:1"), d("user:2")])
        model.remove(d("user:1"))
        XCTAssertEqual(model.rows.map(\.id), [d("user:2")])
        await editor.save()
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertEqual(server.scores("board"), ["user:2": 2, "order:1": 3])
        XCTAssertEqual(model.rows.map(\.id), [d("user:2")], "the removed member stays gone from the matches")
        XCTAssertEqual(model.searchResults?.map(\.id), [d("user:2")])
    }
}
