import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The open editor's draft across the browser's own moves (FR-KB09, FR-ED16): Refresh keeps it, and anything else that
/// would close the editor asks first.
final class BrowserUnsavedChangesReviewTests: XCTestCase {
    /// A string-like editor whose value loads without the server; `saves` decides whether Save writes (and so fails on
    /// the fake server, which refuses transactions) or finds nothing to write.
    @MainActor private func browser(_ keys: Set<String>, saves: Bool = false, loads: Counter = Counter()) async -> (BrowserModel, KeyListDataSource, BrowserKeyspace) {
        let server = BrowserKeyspace([0: keys, 1: ["other"]])
        let list = server.list(readOnly: false); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let binding = EditorBinding(
            load: { key, _, _ in
                await loads.bump()
                return LoadedValue(rows: [EditorRow(id: Data(), value: Data("v".utf8))], watch: WatchGuard(key: key, reads: [], expected: []))
            },
            writes: { key, _, draft in saves ? [.stringSet(key: key, value: draft.first?.value ?? Data(), keepTTL: true)] : [] })
        let model = BrowserModel(list: list, filter: KeyFilterModel(list: list), database: 0, editorBinding: { _ in binding })
        await model.start()
        return (model, list, server)
    }

    @MainActor private func open(_ key: String, in model: BrowserModel, _ list: KeyListDataSource) async throws -> EditorSession {
        await list.select(keyBytes: Data(key.utf8))
        try await waitUntil { model.editor?.key == Data(key.utf8) && model.editor?.phase == .ready }
        return try XCTUnwrap(model.editor)
    }

    private static let draft = [EditorRow(id: Data(), value: Data("draft".utf8))]

    // MARK: - Refresh (FR-KB09)

    @MainActor func testRefreshKeepsTheOpenEditorAndItsDraft() async throws {
        let (model, list, server) = await browser(["user:1", "user:2"])
        let editor = try await open("user:2", in: model, list)
        editor.update(Self.draft)
        XCTAssertTrue(editor.hasUnsavedChanges)

        server.add("a:0")
        await model.refresh()
        try await waitUntil { list.selectedKey != nil }
        // The selection's presence check runs in a task; give it time to (wrongly) replace the editor.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.editor === editor, "the same editor stays open")
        XCTAssertEqual(editor.draft, Self.draft, "its draft survives")
        let selected = await list.selectedKeyName()
        XCTAssertEqual(selected, Data("user:2".utf8))
    }

    @MainActor func testRefreshReReadsACleanEditorInPlace() async throws {
        let loads = Counter()
        let (model, list, _) = await browser(["user:1", "user:2"], loads: loads)
        let editor = try await open("user:2", in: model, list)
        let before = await loads.value
        await model.refresh()
        try await waitUntil { list.selectedKey != nil }
        XCTAssertTrue(model.editor === editor)
        let after = await loads.value
        XCTAssertEqual(after, before + 1, "Refresh re-reads the open value")
    }

    @MainActor func testRefreshKeepsADraftWhoseKeyIsGone() async throws {
        let (model, list, server) = await browser(["user:1", "user:2"])
        let editor = try await open("user:2", in: model, list)
        editor.update(Self.draft)
        server.delete("user:2")
        await model.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(list.selectedKey, "a key deleted meanwhile doesn't come back")
        XCTAssertTrue(model.editor === editor, "but the draft isn't dropped silently")

        // A clean editor whose key is gone closes, as before.
        editor.revert()
        await model.refresh()
        try await waitUntil { model.editor == nil }
    }

    // MARK: - Asking first (FR-ED16)

    /// A click as AppKit makes it: the delegate sees the proposed rows first and may keep the current ones.
    @MainActor private func click(_ list: KeyListDataSource, rows: IndexSet) {
        let allowed = list.tableView(list.tableView, selectionIndexesForProposedSelection: rows)
        list.tableView.selectRowIndexes(allowed, byExtendingSelection: false)
    }

    @MainActor private func dirtyEditor(_ keys: Set<String> = ["user:1", "user:2"], saves: Bool = false) async throws -> (BrowserModel, KeyListDataSource, EditorSession) {
        let (model, list, _) = await browser(keys, saves: saves)
        let editor = try await open("user:1", in: model, list)
        editor.update(Self.draft)
        return (model, list, editor)
    }

    @MainActor func testClickingAnotherKeyAsksAndCancelKeepsSelectionAndDraft() async throws {
        let (model, list, editor) = try await dirtyEditor()
        click(list, rows: [1])
        try await waitUntil { model.unsavedChangesPrompt != nil }
        XCTAssertEqual(model.unsavedChangesPrompt?.keyName, "user:1")
        XCTAssertEqual(list.selectedKey, 0, "the click is held while the user answers")
        XCTAssertEqual(list.tableView.selectedRow, 0)

        await model.answerUnsavedChanges(.cancel).value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.unsavedChangesPrompt)
        XCTAssertEqual(list.selectedKey, 0)
        XCTAssertTrue(model.editor === editor)
        XCTAssertEqual(editor.draft, Self.draft)

        // A multi-key selection would close the editor too.
        click(list, rows: [0, 1])
        try await waitUntil { model.unsavedChangesPrompt != nil }
        XCTAssertTrue(list.selectedKeys.isEmpty)
        await model.answerUnsavedChanges(.cancel).value
    }

    @MainActor func testDontSaveMovesTheSelection() async throws {
        let (model, list, editor) = try await dirtyEditor()
        click(list, rows: [1])
        try await waitUntil { model.unsavedChangesPrompt != nil }
        await model.answerUnsavedChanges(.discard).value
        try await waitUntil { model.editor?.key == Data("user:2".utf8) }
        XCTAssertEqual(list.selectedKey, 1)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    @MainActor func testSaveMovesOnlyOnceSaved() async throws {
        // Saved (nothing left to write): the click goes through.
        let (model, list, _) = try await dirtyEditor()
        click(list, rows: [1])
        try await waitUntil { model.unsavedChangesPrompt != nil }
        await model.answerUnsavedChanges(.save).value
        try await waitUntil { model.editor?.key == Data("user:2".utf8) }

        // A save the server refuses keeps the draft and the selection.
        let (refused, refusedList, editor) = try await dirtyEditor(saves: true)
        click(refusedList, rows: [1])
        try await waitUntil { refused.unsavedChangesPrompt != nil }
        await refused.answerUnsavedChanges(.save).value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(refused.editor === editor)
        XCTAssertEqual(editor.draft, Self.draft)
        XCTAssertEqual(refusedList.selectedKey, 0)
    }

    @MainActor func testCleanEditorMovesWithoutAsking() async throws {
        let (model, list, _) = await browser(["user:1", "user:2"])
        _ = try await open("user:1", in: model, list)
        click(list, rows: [1])
        XCTAssertNil(model.unsavedChangesPrompt)
        XCTAssertEqual(list.selectedKey, 1)
        try await waitUntil { model.editor?.key == Data("user:2".utf8) }
    }

    @MainActor func testDatabaseSwitchAsksFirst() async throws {
        let (model, _, editor) = try await dirtyEditor()
        await model.selectDatabase(1)
        XCTAssertNotNil(model.unsavedChangesPrompt)
        XCTAssertEqual(model.database, 0)
        await model.answerUnsavedChanges(.cancel).value
        XCTAssertEqual(model.database, 0)
        XCTAssertTrue(model.editor === editor)

        await model.selectDatabase(1)
        await model.answerUnsavedChanges(.discard).value
        XCTAssertEqual(model.database, 1)
        XCTAssertNil(model.editor)
    }

    @MainActor func testFilterAsksFirst() async throws {
        let (model, list, editor) = try await dirtyEditor()
        let filter = try XCTUnwrap(model.filter)
        await filter.setType(.hash)
        XCTAssertNotNil(model.unsavedChangesPrompt)
        XCTAssertNil(filter.applied.type, "nothing is applied until the user answers")
        XCTAssertEqual(list.keyCountForTests, 2)
        await model.answerUnsavedChanges(.cancel).value
        XCTAssertNil(filter.applied.type)
        XCTAssertTrue(model.editor === editor)

        filter.patternText = "user:2"
        await filter.applyPattern()
        await model.answerUnsavedChanges(.discard).value
        XCTAssertEqual(filter.applied.pattern, Data("user:2".utf8))
        try await waitUntil { model.editor == nil }
    }

    @MainActor func testPaletteKeyAsksUnlessItIsTheOpenOne() async throws {
        let (model, _, editor) = try await dirtyEditor()
        await model.reveal(Data("user:1".utf8), database: 0)
        XCTAssertNil(model.unsavedChangesPrompt, "the open key itself closes nothing")
        XCTAssertTrue(model.editor === editor)

        await model.reveal(Data("user:2".utf8), database: 0)
        XCTAssertNotNil(model.unsavedChangesPrompt)
        await model.answerUnsavedChanges(.cancel).value
        XCTAssertTrue(model.editor === editor)
        await model.reveal(Data("other".utf8), database: 1)
        await model.answerUnsavedChanges(.discard).value
        XCTAssertEqual(model.database, 1)
        try await waitUntil { model.editor?.key == Data("other".utf8) }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
