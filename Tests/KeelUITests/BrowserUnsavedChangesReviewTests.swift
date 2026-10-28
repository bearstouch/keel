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
        let model = BrowserModel(list: list, database: 0, editorBinding: { _ in binding })
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

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
