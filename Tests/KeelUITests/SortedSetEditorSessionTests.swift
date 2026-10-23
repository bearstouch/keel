import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The sorted set editor in the editor shell (KEEL-033): the table sorted by score, score changes and removals saved
/// together, add and increment at once, the order toggle, and the member read-only in the viewer.
final class SortedSetEditorSessionTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }
    @MainActor private func scores(_ model: SortedSetEditorModel) -> [String] { model.rows.map { String(decoding: $0.value, as: UTF8.self) } }

    /// AC2: a changed score keeps the row in place until saved; the save sends `ZADD XX` and the row then moves.
    @MainActor func testChangedScoreMovesAfterSave() async {
        let server = TransactionalKeyspace(zsets: ["board": [("ann", 30), ("bob", 10), ("cat", 20)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.rows.map(\.id), [d("bob"), d("cat"), d("ann")], "lowest score first")
        XCTAssertEqual(editor.header.length, 3, "member count from ZCARD")

        XCTAssertTrue(model.changeScore(d("bob"), to: "25.5"))
        XCTAssertEqual(model.rows.map(\.id), [d("bob"), d("cat"), d("ann")], "the row waits for the save")
        XCTAssertEqual(scores(model), ["25.5", "20", "30"])
        XCTAssertEqual(editor.changedRows, [d("bob")])

        await editor.save()
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertEqual(server.scores("board"), ["ann": 30, "bob": 25.5, "cat": 20])
        XCTAssertEqual(model.rows.map(\.id), [d("cat"), d("bob"), d("ann")], "moved to its new position")
        let transaction = Array(server.commands.drop { $0.first != "MULTI" }.prefix(3))
        XCTAssertEqual(transaction, [["MULTI"], ["ZADD", "board", "XX", "25.5", "bob"], ["EXEC"]])
        XCTAssertTrue(server.commands.contains(["ZSCORE", "board", "bob"]), "guarded by the loaded score")
    }

    /// A score that doesn't parse changes nothing; typing the loaded score again leaves nothing unsaved.
    @MainActor func testInvalidScoreAndRevertToLoaded() async {
        let server = TransactionalKeyspace(zsets: ["board": [("ann", 0.1)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        XCTAssertFalse(model.changeScore(d("ann"), to: "nan"))
        XCTAssertEqual(model.failure, SortedSetEditorModel.invalidScore)
        XCTAssertFalse(editor.hasUnsavedChanges)
        model.changeScore(d("ann"), to: "inf")
        XCTAssertEqual(scores(model), ["inf"])
        model.changeScore(d("ann"), to: "0.1")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    /// Removing is a draft change saved as `ZREM`; add waits while it is unsaved.
    @MainActor func testRemoveSavesZRem() async {
        let server = TransactionalKeyspace(zsets: ["board": [("a", 1), ("b", 2), ("c", 3)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        model.remove(d("b"))
        XCTAssertFalse(model.canRunAction)
        await model.add(d("z"), score: "1")
        XCTAssertNil(server.scores("board")?["z"], "nothing sent while edits are unsaved")
        await editor.save()
        XCTAssertEqual(server.scores("board"), ["a": 1, "c": 3])
        XCTAssertEqual(model.rows.map(\.id), [d("a"), d("c")])
        XCTAssertTrue(server.commands.contains(["ZREM", "board", "b"]))
    }

    /// Add and increment run at once; an existing member takes the new score and the notice says so.
    @MainActor func testAddAndIncrementRunAtOnce() async {
        let server = TransactionalKeyspace(zsets: ["board": [("a", 1), ("b", 2)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()

        await model.add(d("c"), score: "1.5")
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.rows.map(\.id), [d("a"), d("c"), d("b")])
        XCTAssertEqual(editor.selectedRow, d("c"))
        XCTAssertEqual(editor.header.length, 3)

        await model.add(d("a"), score: "5")
        XCTAssertEqual(model.notice, SortedSetEditor.updatedExistingText)
        XCTAssertEqual(model.rows.map(\.id), [d("c"), d("b"), d("a")])

        await model.increment(d("c"), by: "0.1")
        XCTAssertEqual(server.scores("board")?["c"], 1.6)
        XCTAssertEqual(model.rows.first, SortedSetEditor.row(d("c"), score: 1.6))
        XCTAssertFalse(editor.hasUnsavedChanges, "immediate actions never go through the draft")
        XCTAssertTrue(server.commands.contains(["ZINCRBY", "board", "0.1", "c"]))
    }

    /// A fully loaded set re-sorts highest first without another read.
    @MainActor func testToggleOrder() async {
        let server = TransactionalKeyspace(zsets: ["board": [("a", 1), ("b", 2), ("c", 3)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        let reads = server.commands.count
        await model.toggleOrder()
        XCTAssertTrue(model.descending)
        XCTAssertEqual(model.rows.map(\.id), [d("c"), d("b"), d("a")])
        XCTAssertEqual(server.commands.count, reads, "no read for a fully loaded set")
    }

    /// The viewer opens the member's bytes, read-only; the score lives in the table.
    @MainActor func testViewerShowsMemberReadOnly() async {
        let server = TransactionalKeyspace(zsets: ["board": [("{\"id\":1}", 7)]])
        let editor = server.session("board", type: .zset)
        let model = SortedSetEditorModel(session: editor)
        await editor.load()
        model.select(d("{\"id\":1}"))
        XCTAssertEqual(editor.viewer.state?.bytes, d("{\"id\":1}"))
        XCTAssertFalse(editor.viewer.isEditable)
        XCTAssertFalse(editor.hasUnsavedChanges, "opening the member changes nothing")
    }
}
