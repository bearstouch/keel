import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class StringEditorSessionReviewTests: XCTestCase {
    private static let mebibyte = 1_024 * 1_024

    /// Saving a value over 1 MiB reads it back whole: the editor stays editable instead of falling back to a first page.
    @MainActor func testSavingALargeValueKeepsItFullyLoaded() async {
        let server = TransactionalKeyspace(["blob": "small"])
        let editor = server.session("blob")
        await editor.load()
        let large = String(repeating: "z", count: 2 * Self.mebibyte)
        editor.update([EditorRow(id: Data(), value: Data(large.utf8))])
        await editor.viewer.preparation?.value
        await editor.save()
        await editor.viewer.preparation?.value
        XCTAssertEqual(editor.phase, .ready)
        XCTAssertEqual(server.value("blob")?.utf8.count, 2 * Self.mebibyte)
        XCTAssertNil(editor.partial, "read back whole, not as a first page")
        XCTAssertTrue(editor.viewer.isEditable)
        XCTAssertEqual(editor.loaded?.rows.first?.value.count, 2 * Self.mebibyte)
        XCTAssertFalse(server.commandNames.contains("GETRANGE"))
    }
}
