import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review-driven cases for the list editor (KEEL-031): rows are named by index, so a draft must never be applied to a
/// list whose items moved.
final class ListEditorSessionReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// A conflict on index edits offers no Overwrite: unguarded, the delete of index 1 would remove whatever moved there.
    @MainActor func testConflictOffersNoOverwriteForIndexEdits() async {
        let server = TransactionalKeyspace(lists: ["q": ["a", "b", "c", "d"]])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        model.delete(d("1"))
        server.listWrite(["LPUSH", "q", "z"])
        await editor.save()
        XCTAssertEqual(editor.phase, .conflict)
        XCTAssertFalse(editor.canOverwrite)

        await editor.overwrite()
        XCTAssertEqual(server.list("q"), ["z", "a", "b", "c", "d"], "nothing forced onto the moved items")
        XCTAssertFalse(server.commandNames.contains("LREM"))
        XCTAssertTrue(editor.hasUnsavedChanges, "the draft stays for Reload")

        let hash = TransactionalKeyspace(hashes: ["h": [("f", "v")]]).session("h", type: .hash)
        XCTAssertTrue(hash.canOverwrite, "fields keep their names, so a hash still offers Overwrite")
    }

    /// A save whose reply is lost re-reads the list in place of the draft: kept, its indexes would name other items and
    /// a second Save would delete or overwrite them.
    @MainActor func testUnknownOutcomeReplacesDraft() async {
        let server = TransactionalKeyspace(lists: ["q": ["a", "b", "c", "d"]])
        let editor = server.session("q", type: .list)
        let model = ListEditorModel(session: editor)
        await editor.load()
        model.delete(d("1"))
        server.dropNextExecReply = true
        await editor.save()
        XCTAssertEqual(server.list("q"), ["a", "c", "d"], "the delete ran; only its reply was lost")
        guard case .failed = editor.phase else { return XCTFail("the unknown outcome is reported") }
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.draft.map(\.value), [d("a"), d("c"), d("d")])

        await editor.save()
        XCTAssertEqual(server.list("q"), ["a", "c", "d"], "nothing is applied twice")
    }
}
