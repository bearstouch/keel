import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review-driven set editor cases (KEEL-032).
final class SetEditorSessionReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// The member viewer is read-only, so a member that isn't valid JSON shown in JSON view never blocks saving removals.
    @MainActor func testInvalidJSONMemberInJSONViewDoesNotBlockSave() async {
        let server = TransactionalKeyspace(sets: ["tags": ["{bad", "b", "c"]])
        let editor = server.session("tags", type: .set)
        let model = SetEditorModel(session: editor)
        await editor.load()
        editor.select(d("{bad"))
        editor.viewer.show(.json)
        XCTAssertEqual(editor.viewer.state?.mode, .json)
        XCTAssertNotNil(editor.viewer.state?.saveBlock, "the view itself still notes the invalid JSON")
        model.remove(d("b"))
        XCTAssertNil(editor.saveBlock)
        await editor.save()
        XCTAssertEqual(server.members("tags"), ["{bad", "c"])
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.selectedRow, d("{bad"), "the viewed member stays open")
    }
}
