import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The string editor in the editor shell (KEEL-029): a partial load is shown read-only until "Load all".
final class StringEditorSessionTests: XCTestCase {
    private static let mebibyte = 1_024 * 1_024

    @MainActor func testPartialLoadIsReadOnlyUntilLoadAll() async {
        let server = TransactionalKeyspace(["blob": String(repeating: "a", count: 2 * Self.mebibyte)])
        let editor = server.session("blob")
        await editor.load()
        await editor.viewer.preparation?.value
        XCTAssertEqual(editor.partial?.text, "Partial (1 MiB of 2 MiB)")
        XCTAssertTrue(editor.canLoadAll)
        XCTAssertFalse(editor.viewer.isEditable, "AC1: editing disabled for a partial load")
        XCTAssertEqual(editor.viewer.state?.bytes.count, Self.mebibyte)

        // Edits and saves of a first page are refused: saving it would truncate the value.
        editor.update([EditorRow(id: Data(), value: Data("short".utf8))])
        XCTAssertFalse(editor.showsSaveBar)
        await editor.save()
        XCTAssertFalse(server.commandNames.contains { ["WATCH", "MULTI", "SET"].contains($0) })
        XCTAssertFalse(server.commandNames.contains("GET"), "the first page came from GETRANGE")

        await editor.loadAll()
        await editor.viewer.preparation?.value
        XCTAssertNil(editor.partial)
        XCTAssertTrue(editor.viewer.isEditable, "fully loaded: editable")
        XCTAssertEqual(editor.viewer.state?.bytes.count, 2 * Self.mebibyte)
        editor.update([EditorRow(id: Data(), value: Data("short".utf8))])
        XCTAssertTrue(editor.showsSaveBar)
        await editor.save()
        XCTAssertEqual(server.value("blob"), "short")
        XCTAssertTrue(server.commands.contains(["SET", "blob", "short", "KEEPTTL"]))
    }

    /// AC3: Save with nothing changed sends nothing.
    @MainActor func testUnchangedSaveSendsNothing() async {
        let server = TransactionalKeyspace(["greeting": "hello"])
        let editor = server.session("greeting")
        await editor.load()
        let before = server.commands
        await editor.save()
        editor.update([EditorRow(id: Data(), value: Data("hello".utf8))])
        await editor.save()
        XCTAssertEqual(server.commands, before)
    }

    @MainActor func testReadOnlyPartialOffersLoadAllButStaysReadOnly() async {
        let server = TransactionalKeyspace(["blob": String(repeating: "b", count: Self.mebibyte + 1)])
        let editor = server.session("blob", readOnly: true)
        await editor.load()
        XCTAssertEqual(editor.partial?.totalBytes, Int64(Self.mebibyte + 1))
        await editor.loadAll()
        XCTAssertNil(editor.partial, "viewing the whole value is allowed")
        XCTAssertFalse(editor.viewer.isEditable)
    }
}
