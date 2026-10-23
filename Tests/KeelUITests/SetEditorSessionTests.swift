import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The set editor in the editor shell (KEEL-032): the member list over the draft, add at once with "already a member",
/// removals saved as one `SREM`, and Load more for large sets.
final class SetEditorSessionTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// AC1: adding a member that is there already sends `SADD`, reports "already a member" and changes nothing.
    @MainActor func testAddExistingShowsAlreadyMember() async {
        let server = TransactionalKeyspace(sets: ["tags": ["redis", "fast", "cache"]])
        let editor = server.session("tags", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(model.rows.map(\.id), [d("cache"), d("fast"), d("redis")], "sorted by member")
        XCTAssertEqual(editor.header.length, 3, "member count from SCARD")

        await model.add(d("fast"))
        XCTAssertEqual(model.notice, SetEditor.alreadyMemberText)
        XCTAssertEqual(server.members("tags"), ["redis", "fast", "cache"])
        XCTAssertEqual(editor.selectedRow, d("fast"))
        XCTAssertFalse(editor.hasUnsavedChanges)

        await model.add(d("new"))
        XCTAssertNil(model.notice)
        XCTAssertEqual(server.members("tags"), ["redis", "fast", "cache", "new"])
        XCTAssertEqual(model.rows.map(\.id), [d("cache"), d("fast"), d("new"), d("redis")])
        XCTAssertEqual(editor.selectedRow, d("new"))
        XCTAssertEqual(editor.header.length, 4)
        XCTAssertFalse(editor.hasUnsavedChanges, "an add runs at once, never through the draft")
        XCTAssertEqual(server.commands.filter { $0.first == "SADD" }, [["SADD", "tags", "fast"], ["SADD", "tags", "new"]])
    }

    /// Removing is a draft change: the save bar counts it, adding waits, and Save sends one `SREM` in `MULTI/EXEC`.
    @MainActor func testRemoveSavesOneSRem() async {
        let server = TransactionalKeyspace(sets: ["tags": ["a", "b", "c"]])
        let editor = server.session("tags", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        editor.select(d("a"))
        model.remove(d("a"))
        model.remove(d("c"))
        XCTAssertEqual(editor.changedRows, [d("a"), d("c")])
        XCTAssertNil(editor.selectedRow, "the removed member leaves the viewer")
        XCTAssertFalse(model.canAdd, "an add would re-read and drop the unsaved removals")
        await model.add(d("z"))
        XCTAssertEqual(server.members("tags"), ["a", "b", "c"], "nothing sent while removals are unsaved")

        await editor.save()
        XCTAssertEqual(server.members("tags"), ["b"])
        XCTAssertEqual(model.rows.map(\.id), [d("b")])
        XCTAssertFalse(editor.hasUnsavedChanges)
        let transaction = Array(server.commands.drop { $0.first != "MULTI" }.prefix(3))
        XCTAssertEqual(transaction, [["MULTI"], ["SREM", "tags", "a", "c"], ["EXEC"]])
        XCTAssertEqual(editor.header.length, 1)
    }

    /// AC2: a large set shows its first `SSCAN` page with "Showing 1–500 of N"; an added member beyond the loaded pages
    /// joins the list once, and Load more doesn't repeat it.
    @MainActor func testLargeSetPagesAndAddsUnloadedMember() async {
        let server = TransactionalKeyspace(sets: ["big": (0..<1_200).map { "m\($0)" }])
        let editor = server.session("big", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(editor.loaded?.rows.count, 500)
        XCTAssertEqual(model.pageText, "Showing 1–500 of 1,200")
        XCTAssertFalse(server.commandNames.contains("SMEMBERS"))

        await model.add(d("m900"))
        XCTAssertEqual(model.notice, SetEditor.alreadyMemberText)
        XCTAssertTrue(model.rows.contains { $0.id == d("m900") })
        XCTAssertFalse(editor.hasUnsavedChanges)

        await editor.loadMore()
        await editor.loadMore()
        XCTAssertNil(model.pageText, "every member loaded")
        XCTAssertEqual(editor.draft.count, 1_200)
        XCTAssertEqual(Set(editor.draft.map(\.id)).count, 1_200, "m900 once")
    }

    /// A member's bytes are its name: the viewer shows it read-only. Read-only profiles add and remove nothing.
    @MainActor func testViewerIsReadOnlyAndReadOnlyProfileChangesNothing() async {
        let server = TransactionalKeyspace(sets: ["tags": ["a", "b"]])
        let editor = server.session("tags", type: .set)
        await editor.load()
        editor.select(d("a"))
        XCTAssertEqual(editor.viewer.state?.bytes, d("a"))
        XCTAssertFalse(editor.viewer.isEditable)

        let readOnly = server.session("tags", type: .set, readOnly: true)
        let model = SetEditorModel(session: readOnly)
        await readOnly.load()
        XCTAssertFalse(model.canAdd)
        await model.add(d("c"))
        model.remove(d("a"))
        XCTAssertFalse(readOnly.hasUnsavedChanges)
        XCTAssertEqual(server.members("tags"), ["a", "b"])
        XCTAssertFalse(server.commandNames.contains("SADD"))
    }

    /// The filter matches loaded members by name, case-insensitively.
    @MainActor func testLocalFilter() async {
        let server = TransactionalKeyspace(sets: ["tags": ["Alpha", "beta", "alphabet"]])
        let editor = server.session("tags", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        model.filter = "ALPHA"
        XCTAssertEqual(model.rows.map(\.id), [d("Alpha"), d("alphabet")])
        model.filter = "zzz"
        XCTAssertTrue(model.rows.isEmpty)
    }
}
