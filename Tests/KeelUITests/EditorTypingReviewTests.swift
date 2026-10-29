import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Typing in the viewer lands on every keystroke: the table keeps its order without sorting again, and the change marks
/// stay exactly what a full comparison of the loaded value and the draft gives.
final class EditorTypingReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    @MainActor func testTypingInAHashFieldKeepsTheOrderWithoutSorting() async {
        let server = TransactionalKeyspace(hashes: ["h": [("name", "Ada"), ("city", "London"), ("Zone", "1"), ("age", "36")]])
        let editor = server.session("h", type: .hash)
        let model = HashEditorModel(session: editor)
        await editor.load()
        let order = model.rows.map(\.id)
        XCTAssertEqual(order, [d("age"), d("city"), d("name"), d("Zone")])
        let sorts = model.sorts

        editor.select(d("name"))
        for text in ["Ada ", "Ada L", "Ada Lo", "Ada Lov"] {
            editor.viewer.edit(text)
            XCTAssertEqual(model.rows.map(\.id), order)
            XCTAssertEqual(model.rows.first { $0.id == d("name") }?.value, d(text), "the table shows the typed value")
            XCTAssertEqual(editor.changedRows, EditorChanges.changedRows(loaded: editor.loaded?.rows ?? [], draft: editor.draft))
        }
        XCTAssertEqual(model.sorts, sorts, "typing never sorts the rows again")
        XCTAssertEqual(editor.changedRows, [d("name")])

        // Typing the loaded value back clears the mark, as a full comparison would.
        editor.viewer.edit("Ada")
        XCTAssertFalse(editor.hasUnsavedChanges)

        // Edits that change the fields or the view do sort again.
        model.filter = "a"
        XCTAssertEqual(model.rows.map(\.id), [d("age"), d("name")])
        model.filter = ""
        await model.add(field: d("b"), value: d("x"))
        XCTAssertEqual(model.rows.map(\.id), [d("age"), d("b"), d("city"), d("name"), d("Zone")])
        model.toggleOrder()
        XCTAssertEqual(model.rows.map(\.id), [d("Zone"), d("name"), d("city"), d("b"), d("age")])
        XCTAssertEqual(model.sorts, sorts + 4)
        XCTAssertEqual(editor.changedRows, EditorChanges.changedRows(loaded: editor.loaded?.rows ?? [], draft: editor.draft))
    }

    @MainActor func testSetListSortsOnlyWhenMembersOrTheFilterChange() async {
        let server = TransactionalKeyspace(sets: ["tags": ["redis", "fast", "cache"]])
        let editor = server.session("tags", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.rows.map(\.id), [d("cache"), d("fast"), d("redis")])
        let sorts = model.sorts
        editor.select(d("fast"))
        XCTAssertEqual(model.sorts, sorts, "selecting a member re-sorts nothing")
        model.remove(d("fast"))
        XCTAssertEqual(model.rows.map(\.id), [d("cache"), d("redis")])
        model.filter = "RED"
        XCTAssertEqual(model.rows.map(\.id), [d("redis")])
        XCTAssertEqual(model.sorts, sorts + 2)
    }

    @MainActor func testTypingInAStringMarksItLikeAFullComparison() async {
        let editor = TransactionalKeyspace(["greeting": "hello"]).session("greeting")
        await editor.load()
        editor.viewer.edit("hello!")
        XCTAssertEqual(editor.changedRows, [Data()])
        XCTAssertEqual(editor.draft.first?.value, d("hello!"))
        editor.viewer.edit("hello")
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.draft.first?.value, d("hello"))
    }
}
