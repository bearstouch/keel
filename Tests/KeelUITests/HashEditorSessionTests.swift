import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The hash editor in the editor shell (KEEL-030): the table over the draft, the selected field in the viewer, Load
/// more, and add / rename / delete saved in one guarded transaction.
final class HashEditorSessionTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    @MainActor func testEditSelectedFieldInViewerAndSave() async {
        let server = TransactionalKeyspace(hashes: ["user:1042": [("name", "Ada"), ("city", "London")]])
        let editor = server.session("user:1042", type: .hash)
        let model = HashEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.rows.map(\.id), [d("city"), d("name")], "sorted by field")
        model.toggleOrder()
        XCTAssertEqual(model.rows.map(\.id), [d("name"), d("city")])
        model.filter = "CIT"
        XCTAssertEqual(model.rows.map(\.id), [d("city")], "local, case-insensitive")
        model.filter = ""

        editor.select(d("name"))
        XCTAssertEqual(editor.viewer.title, "name")
        XCTAssertEqual(editor.viewer.state?.bytes, d("Ada"))
        editor.viewer.edit("Ada Lovelace")
        XCTAssertEqual(editor.changedRows, [d("name")])
        editor.select(d("city"))
        XCTAssertEqual(editor.viewer.state?.bytes, d("London"), "selecting another field opens it")

        await editor.save()
        XCTAssertEqual(server.hash("user:1042"), ["name": "Ada Lovelace", "city": "London"])
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.selectedRow, d("city"), "selection survives the save")
        XCTAssertTrue(server.commands.contains(["HGET", "user:1042", "name"]), "the touched field is guarded")
    }

    /// AC1 + AC3: rename onto an existing field asks; confirmed, it saves as HSET + HDEL in one MULTI.
    @MainActor func testRenameOntoExistingAsksThenSavesAtomically() async {
        let server = TransactionalKeyspace(hashes: ["h": [("a", "1"), ("b", "2")]])
        let editor = server.session("h", type: .hash)
        let model = HashEditorModel(session: editor)
        await editor.load()
        await model.rename(d("a"), to: d("b"))
        XCTAssertEqual(model.pendingOverwrite?.field, d("b"))
        XCTAssertFalse(editor.hasUnsavedChanges, "nothing changes before the user confirms")
        model.confirmOverwrite()
        XCTAssertEqual(editor.draft, [EditorRow(id: d("b"), value: d("1"))])
        XCTAssertEqual(editor.selectedRow, d("b"))
        await editor.save()
        XCTAssertEqual(server.hash("h"), ["b": "1"])
        let transaction = Array(server.commands.drop { $0.first != "MULTI" }.prefix(4))
        XCTAssertEqual(transaction, [["MULTI"], ["HSET", "h", "b", "1"], ["HDEL", "h", "a"], ["EXEC"]])
    }

    /// A field changed elsewhere since loading stops the save with a conflict; nothing is written.
    @MainActor func testChangedFieldConflicts() async {
        let server = TransactionalKeyspace(hashes: ["h": [("a", "1"), ("b", "2")]])
        let editor = server.session("h", type: .hash)
        let model = HashEditorModel(session: editor)
        await editor.load()
        await model.rename(d("a"), to: d("c"))
        server.hset("h", "a", "changed")
        await editor.save()
        XCTAssertEqual(editor.phase, .conflict)
        XCTAssertEqual(server.hash("h"), ["a": "changed", "b": "2"])
    }

    /// A paged hash: Load more adds the next page; adding a field that exists beyond the loaded pages asks first.
    @MainActor func testPagedHashLoadsMoreAndAsksAboutUnloadedFields() async {
        let fields = (0..<1_200).map { ("f\($0)", "v\($0)") }
        let server = TransactionalKeyspace(hashes: ["big": fields])
        let editor = server.session("big", type: .hash)
        let model = HashEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(editor.loaded?.rows.count, 500)
        XCTAssertEqual(model.pageText, "Showing 1–500 of 1,200")
        XCTAssertFalse(server.commandNames.contains("HGETALL"))

        await model.add(field: d("f1100"), value: d("new"))
        XCTAssertEqual(model.pendingOverwrite?.field, d("f1100"), "the server has it, though it isn't loaded")
        model.cancelOverwrite()
        XCTAssertFalse(editor.hasUnsavedChanges)

        await editor.loadMore()
        XCTAssertEqual(editor.loaded?.rows.count, 1_001, "two pages, plus f1100 the check read")
        await editor.loadMore()
        XCTAssertEqual(editor.loaded?.rows.count, 1_200, "f1100 isn't repeated")
        XCTAssertNil(model.pageText)
        XCTAssertFalse(editor.canLoadMore)
    }

    @MainActor func testReadOnlyRefusesEdits() async {
        let server = TransactionalKeyspace(hashes: ["h": [("a", "1")]])
        let editor = server.session("h", type: .hash, readOnly: true)
        let model = HashEditorModel(session: editor)
        await editor.load()
        await model.add(field: d("b"), value: d("2"))
        model.delete(d("a"))
        editor.select(d("a"))
        editor.viewer.edit("x")
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.viewer.isEditable)
    }
}
