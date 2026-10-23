import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The viewer inside the editor shell: what it opens in, how its edits reach the draft, and when Save is refused.
final class ValueViewerModelTests: XCTestCase {
    @MainActor func testStringOpensInViewerWithJSONDetected() async {
        let server = TransactionalKeyspace(["prefs": #"{"theme":"dark"}"#])
        let editor = server.session("prefs")
        await editor.load()
        XCTAssertTrue(editor.showsWholeValue)
        XCTAssertEqual(editor.viewer.title, "Value")
        XCTAssertEqual(editor.viewer.state?.mode, .json)
        XCTAssertEqual(editor.viewer.state?.isValidJSON, true)
        XCTAssertEqual(editor.viewer.state?.text, "{\n  \"theme\": \"dark\"\n}")
        // Viewing pretty-printed JSON changes nothing.
        XCTAssertFalse(editor.showsSaveBar)
    }

    /// AC2 / FR-ED01: invalid JSON can't be saved from JSON view, sends nothing, and saves as is from Text.
    @MainActor func testInvalidJSONBlocksSaveUntilText() async {
        let server = TransactionalKeyspace(["prefs": #"{"theme":"dark"}"#])
        let editor = server.session("prefs")
        await editor.load()
        editor.viewer.edit(#"{"theme":"#)
        XCTAssertTrue(editor.showsSaveBar)
        XCTAssertNotNil(editor.saveBlock)
        XCTAssertEqual(editor.viewer.state?.jsonError?.line, 1)

        await editor.save()
        XCTAssertFalse(server.commandNames.contains("SET"), "a blocked save sends nothing")
        XCTAssertEqual(server.value("prefs"), #"{"theme":"dark"}"#)

        editor.viewer.show(.text)
        XCTAssertNil(editor.saveBlock)
        XCTAssertEqual(editor.viewer.state?.text, #"{"theme":"#)
        await editor.save()
        XCTAssertEqual(server.value("prefs"), #"{"theme":"#)
        XCTAssertFalse(editor.showsSaveBar)
    }

    @MainActor func testTextAndRawEditsBecomeTheDraftByteExactly() async {
        let server = TransactionalKeyspace(["k": "v"])
        let editor = server.session("k")
        await editor.load()
        XCTAssertEqual(editor.viewer.state?.mode, .text)
        // Escapes typed in Raw are bytes, including ones that aren't UTF-8.
        editor.viewer.show(.raw)
        editor.viewer.edit(#""v\xff\x00\r""#)
        XCTAssertEqual(editor.draft.first?.value, Data([0x76, 0xFF, 0x00, 0x0D]))
        XCTAssertNil(editor.saveBlock)
        // Text shows them escaped, and an edit there keeps them.
        editor.viewer.show(.text)
        XCTAssertEqual(editor.viewer.state?.text, #"v\xff\x00\x0d"#)
        editor.viewer.edit(#"v\xff\x00\x0d!"#)
        XCTAssertEqual(editor.draft.first?.value, Data([0x76, 0xFF, 0x00, 0x0D, 0x21]))
        // Raw text that doesn't parse keeps the last good draft and blocks Save.
        editor.viewer.show(.raw)
        editor.viewer.edit(#""broken"#)
        XCTAssertEqual(editor.draft.first?.value, Data([0x76, 0xFF, 0x00, 0x0D, 0x21]))
        XCTAssertEqual(editor.saveBlock, "The closing quote is missing.")
    }

    /// Review: typing while a save runs can't reach the draft, so the viewer goes back to it — the screen never shows
    /// text that isn't what was saved.
    @MainActor func testTypingDuringSaveDoesNotDivergeFromDraft() async {
        let server = TransactionalKeyspace(["k": "one"])
        let editor = server.session("k")
        await editor.load()
        editor.viewer.edit("two")
        let saving = Task { await editor.save() }
        while editor.phase != .saving { await Task.yield() }
        editor.viewer.edit("three")
        XCTAssertEqual(editor.viewer.state?.bytes, Data("two".utf8))
        XCTAssertEqual(editor.draft.first?.value, Data("two".utf8))
        await saving.value
        XCTAssertEqual(server.value("k"), "two")
        XCTAssertEqual(editor.viewer.state?.text, "two")
    }

    /// Review: while a large value's view is prepared, its Save complaint isn't known, so Save waits.
    @MainActor func testSaveRefusedWhileLargeValueIsPrepared() async {
        let large = String(repeating: "a", count: ValueViewerModel.backgroundThreshold + 1)
        let server = TransactionalKeyspace(["k": large])
        let editor = server.session("k")
        await editor.load()
        await editor.viewer.preparation?.value
        editor.viewer.edit(large + "!")
        XCTAssertTrue(editor.showsSaveBar)
        editor.viewer.show(.json)
        XCTAssertNil(editor.viewer.state)
        await editor.save()
        XCTAssertFalse(server.commandNames.contains("SET"))
        await editor.viewer.preparation?.value
        XCTAssertNotNil(editor.saveBlock, "JSON view of a value that isn't JSON")
        await editor.save()
        XCTAssertEqual(server.value("k"), large)
    }

    @MainActor func testRevertAndReloadReachTheViewer() async {
        let server = TransactionalKeyspace(["k": "one"])
        let editor = server.session("k")
        await editor.load()
        editor.viewer.edit("two")
        XCTAssertTrue(editor.showsSaveBar)
        let revision = editor.viewer.revision
        editor.revert()
        XCTAssertEqual(editor.viewer.state?.text, "one")
        XCTAssertGreaterThan(editor.viewer.revision, revision, "the text view takes the reverted value")
        // Updating the draft elsewhere shows in the viewer too, in the view the user chose.
        editor.viewer.show(.hex)
        editor.update([EditorRow(id: Data(), value: Data("three".utf8))])
        XCTAssertEqual(editor.viewer.state?.bytes, Data("three".utf8))
        XCTAssertEqual(editor.viewer.state?.mode, .hex)
    }

    @MainActor func testReadOnlyViewerSwitchesButNeverEdits() async {
        let server = TransactionalKeyspace(["k": "v"])
        let editor = server.session("k", readOnly: true)
        await editor.load()
        XCTAssertFalse(editor.viewer.isEditable)
        editor.viewer.show(.raw)
        XCTAssertEqual(editor.viewer.state?.text, #""v""#)
        editor.viewer.edit(#""changed""#)
        XCTAssertEqual(editor.viewer.state?.bytes, Data("v".utf8))
        XCTAssertFalse(editor.showsSaveBar)
    }

    @MainActor func testViewerChoiceRememberedPerKeyPattern() {
        let choices = ValueViewerChoices()
        let user1 = ValueViewerModel(choices: choices, pattern: ValueViewerMemory.pattern(of: Data("user:1".utf8), separator: .default), isEditable: true)
        user1.open(Data(#"{"a":1}"#.utf8), title: "Value")
        XCTAssertEqual(user1.state?.mode, .json)
        user1.show(.raw)

        let user2 = ValueViewerModel(choices: choices, pattern: ValueViewerMemory.pattern(of: Data("user:2".utf8), separator: .default), isEditable: true)
        user2.open(Data(#"{"a":2}"#.utf8), title: "Value")
        XCTAssertEqual(user2.state?.mode, .raw, "same pattern, same view")

        let order = ValueViewerModel(choices: choices, pattern: ValueViewerMemory.pattern(of: Data("order:1".utf8), separator: .default), isEditable: true)
        order.open(Data(#"{"a":3}"#.utf8), title: "Value")
        XCTAssertEqual(order.state?.mode, .json)
        // Another tab (another set of choices) starts fresh.
        let other = ValueViewerModel(choices: ValueViewerChoices(), pattern: Data("user:*".utf8), isEditable: true)
        other.open(Data(#"{"a":4}"#.utf8), title: "Value")
        XCTAssertEqual(other.state?.mode, .json)
    }

    /// AC3: a 1 MiB value is prepared off the main actor; the newest open wins.
    @MainActor func testLargeValuePreparedInBackground() async {
        let choices = ValueViewerChoices()
        choices.remember(.hex, for: Data("blob:*".utf8))
        let viewer = ValueViewerModel(choices: choices, pattern: Data("blob:*".utf8), isEditable: true)
        let mebibyte = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        viewer.open(mebibyte, title: "Value")
        XCTAssertNil(viewer.state, "nothing renders on the main actor")
        await viewer.preparation?.value
        XCTAssertEqual(viewer.state?.mode, .hex)
        XCTAssertEqual(viewer.state?.bytes.count, 1 << 20)

        // Switching to Text renders in the background too; a newer open supersedes it.
        viewer.show(.text)
        let switching = viewer.preparation
        viewer.open(Data("small".utf8), title: "Value")
        await switching?.value
        XCTAssertEqual(viewer.state?.bytes, Data("small".utf8))
        XCTAssertEqual(viewer.state?.mode, .text, "the user's choice applies to the newer value")
    }
}
