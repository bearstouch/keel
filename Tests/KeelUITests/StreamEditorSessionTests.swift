import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The stream viewer in the editor shell (KEEL-034): entries newest first, the order toggle, selecting an entry's field
/// into the read-only viewer, and Add entry through `XADD`.
final class StreamEditorSessionTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }
    @MainActor private func ids(_ model: StreamEditorModel) -> [String] { model.rows.map { String(decoding: $0.id, as: UTF8.self) } }

    private static let events: [String: [(String, [(String, String)])]] = ["events": [("1-0", [("type", "a")]), ("2-0", [("type", "b")]), ("2-1", [("type", "c"), ("user", "ann")])]]

    /// AC2: adding with `*` shows the server-assigned ID at the top, selected, with its first field in the viewer.
    @MainActor func testAutoIDEntryShowsAtTop() async {
        let server = TransactionalKeyspace(streams: Self.events)
        let editor = server.session("events", type: .stream)
        let model = StreamEditorModel(session: editor)
        await editor.load()
        XCTAssertEqual(ids(model), ["2-1", "2-0", "1-0"], "newest first")
        XCTAssertEqual(editor.header.length, 3, "entry count from XLEN")
        await model.toggleOrder()
        XCTAssertEqual(ids(model), ["1-0", "2-0", "2-1"], "a fully loaded stream re-sorts")

        let added = await model.add(id: StreamEditor.autoID, fields: [.init(field: d("type"), value: d("login"))])
        XCTAssertTrue(added)
        XCTAssertEqual(ids(model).first, "1700000000000-0", "the server-assigned ID at the top")
        XCTAssertTrue(model.newestFirst)
        XCTAssertEqual(model.selectedEntry, d("1700000000000-0"))
        XCTAssertEqual(editor.viewer.state?.bytes, d("login"))
        XCTAssertFalse(editor.viewer.isEditable, "entries are read-only")
        XCTAssertEqual(editor.header.length, 4)
        XCTAssertTrue(server.commands.contains(["XADD", "events", "*", "type", "login"]))
    }

    /// An explicit ID the server refuses (not above the last entry) adds nothing and shows the server's error.
    @MainActor func testExplicitIDRefusedByServer() async {
        let server = TransactionalKeyspace(streams: Self.events)
        let editor = server.session("events", type: .stream)
        let model = StreamEditorModel(session: editor)
        await editor.load()
        let added = await model.add(id: d("2-0"), fields: [.init(field: d("type"), value: d("x"))])
        XCTAssertFalse(added)
        XCTAssertEqual(editor.actionFailure, "ERR The ID specified in XADD is equal or smaller than the target stream top item")
        XCTAssertEqual(server.streamIDs("events"), ["1-0", "2-0", "2-1"])

        let outcome1 = await model.add(id: d("3-5"), fields: [.init(field: d("type"), value: d("x"))])
        XCTAssertTrue(outcome1)
        XCTAssertEqual(ids(model).first, "3-5")
    }

    /// Input the sheet can't send (no field, an empty name) sends nothing; a read-only profile can't add at all.
    @MainActor func testInvalidInputAndReadOnlySendNothing() async {
        let server = TransactionalKeyspace(streams: Self.events)
        let editor = server.session("events", type: .stream)
        let model = StreamEditorModel(session: editor)
        await editor.load()
        let outcome2 = await model.add(id: StreamEditor.autoID, fields: [])
        XCTAssertFalse(outcome2)
        XCTAssertEqual(model.failure, "Add at least one field.")
        let outcome3 = await model.add(id: StreamEditor.autoID, fields: [.init(field: Data(), value: d("v"))])
        XCTAssertFalse(outcome3)
        let outcome4 = await model.add(id: Data(), fields: [.init(field: d("f"), value: d("v"))])
        XCTAssertFalse(outcome4)

        let readOnly = server.session("events", type: .stream, readOnly: true)
        let viewer = StreamEditorModel(session: readOnly)
        await readOnly.load()
        XCTAssertEqual(viewer.rows.count, 3)
        XCTAssertFalse(viewer.canAdd)
        let outcome5 = await viewer.add(id: StreamEditor.autoID, fields: [.init(field: d("f"), value: d("v"))])
        XCTAssertFalse(outcome5)
        XCTAssertFalse(server.commandNames.contains("XADD"))
    }

    /// Selecting an entry lists its fields; another field opens its value, titled by the field's name.
    @MainActor func testSelectingFieldsOpensValues() async {
        let server = TransactionalKeyspace(streams: Self.events)
        let editor = server.session("events", type: .stream)
        let model = StreamEditorModel(session: editor)
        await editor.load()
        model.select(d("2-1"))
        XCTAssertEqual(model.selectedFields.map(\.field), [d("type"), d("user")])
        XCTAssertEqual(model.selectedField, 0)
        model.selectField(1)
        XCTAssertEqual(editor.viewer.state?.bytes, d("ann"))
        XCTAssertEqual(editor.viewer.title, "user")
        XCTAssertFalse(editor.showsSaveBar)
        model.select(nil)
        XCTAssertNil(model.selectedField)
    }
}
