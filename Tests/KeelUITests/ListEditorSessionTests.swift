import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The list editor in the editor shell (KEEL-031): edits and deletes by index through the save bar, push, pop and
/// insert at once, Jump to index, and the production confirmation for pops.
final class ListEditorSessionTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// Edit an item in the viewer and delete another: one save, `LSET` + sentinel delete, order kept.
    @MainActor func testEditAndDeleteByIndexSave() async {
        let server = TransactionalKeyspace(lists: ["q": ["a", "b", "c", "d"]])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.rows.map(\.id), [d("0"), d("1"), d("2"), d("3")])
        XCTAssertEqual(editor.header.metadataLine, "No expiry · 4 items")

        editor.select(d("1"))
        editor.viewer.edit("B")
        model.delete(d("2"))
        XCTAssertEqual(editor.unsavedChangeCount, 2)
        XCTAssertFalse(model.canAct, "push and pop wait for the draft")
        await model.push(d("x"), atHead: true)
        XCTAssertEqual(server.list("q"), ["a", "b", "c", "d"], "nothing pushed while edits are unsaved")

        await editor.save()
        XCTAssertEqual(server.list("q"), ["a", "B", "d"])
        XCTAssertEqual(editor.draft.map(\.value), [d("a"), d("B"), d("d")], "re-read with new indexes")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    /// AC3: on a production profile a pop waits for the user's yes; Cancel pops nothing.
    @MainActor func testPopAsksOnProduction() async {
        let server = TransactionalKeyspace(lists: ["q": ["a", "b", "c"]])
        let editor = server.session("q", type: .list, production: true)
        let model = ListEditorModel(session: editor)
        await editor.load()

        await model.pop(atHead: true)
        XCTAssertEqual(model.pendingPop, true)
        XCTAssertEqual(server.list("q"), ["a", "b", "c"], "nothing popped before the confirmation")
        model.cancelPop()
        XCTAssertNil(model.pendingPop)
        XCTAssertFalse(server.commandNames.contains("LPOP"))

        await model.pop(atHead: false)
        XCTAssertEqual(model.pendingPop, false)
        await model.confirmPop()
        XCTAssertEqual(server.list("q"), ["a", "b"])
        XCTAssertEqual(editor.draft.map(\.value), [d("a"), d("b")])
    }

    /// Elsewhere a pop runs at once, guarded by the end item shown; a head changed elsewhere pops nothing.
    @MainActor func testPopRunsAtOnceAndIsGuarded() async {
        let server = TransactionalKeyspace(lists: ["q": ["a", "b"]])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        await model.pop(atHead: true)
        XCTAssertNil(model.pendingPop, "no confirmation off production")
        XCTAssertEqual(server.list("q"), ["b"])
        XCTAssertTrue(server.commands.contains(["LRANGE", "q", "0", "0"]), "the head shown is guarded")

        server.listWrite(["LPUSH", "q", "z"])
        await model.pop(atHead: true)
        XCTAssertEqual(server.list("q"), ["z", "b"], "the head changed: nothing popped")
        XCTAssertNotNil(editor.actionFailure)
        XCTAssertEqual(editor.draft.map(\.value), [d("z"), d("b")], "reloaded")
    }

    /// Insert lands at the exact index even beside an earlier copy of the same value; push adds at either end.
    @MainActor func testInsertAndPush() async {
        let server = TransactionalKeyspace(lists: ["q": ["x", "y", "x"]])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        await model.insert(d("n"), relativeTo: d("2"), before: true)
        XCTAssertEqual(server.list("q"), ["x", "y", "n", "x"], "before index 2, not before the first x")
        await model.insert(d("m"), relativeTo: d("0"), before: false)
        XCTAssertEqual(server.list("q"), ["x", "m", "y", "n", "x"])
        await model.push(d("h"), atHead: true)
        await model.push(d("t"), atHead: false)
        XCTAssertEqual(server.list("q"), ["h", "x", "m", "y", "n", "x", "t"])
        XCTAssertEqual(editor.draft.count, 7)
        XCTAssertEqual(editor.header.length, 7, "the header is re-read")
    }

    /// Jump to index loads the page starting there; an index past the end says why and keeps the page.
    @MainActor func testJumpToIndex() async {
        let server = TransactionalKeyspace(lists: ["q": (0..<1_200).map { "i\($0)" }])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.pageText, "Showing 1–500 of 1,200")
        await model.jump(to: "900")
        XCTAssertEqual(editor.draft.first, EditorRow(id: d("900"), value: d("i900")))
        XCTAssertEqual(model.pageText, "Showing 901–1,200 of 1,200")
        await model.jump(to: "5000")
        XCTAssertNotNil(editor.actionFailure)
        XCTAssertEqual(editor.draft.first?.id, d("900"), "the page stays")
        await model.jump(to: "abc")
        XCTAssertEqual(model.message, "Enter an index of 0 or more.")
    }
}
