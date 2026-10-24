import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The ⋯ menu's key actions through the editor shell and the browser (FR-ED10, FR-ED12, FR-ED15).
final class KeyActionsSessionTests: XCTestCase {
    @MainActor private func browser(_ keys: Set<String>) async -> (BrowserModel, KeyListDataSource, BrowserKeyspace) {
        let server = BrowserKeyspace([0: keys])
        let list = server.list(readOnly: false); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        return (model, list, server)
    }

    @MainActor private func open(_ key: String, in model: BrowserModel, _ list: KeyListDataSource) async throws -> EditorSession {
        await list.select(keyBytes: Data(key.utf8))
        try await waitUntil { model.editor?.key == Data(key.utf8) && model.editor?.phase == .ready }
        return try XCTUnwrap(model.editor)
    }

    @MainActor func testDeleteRemovesKeyAndShowsEmptyEditor() async throws {
        let (model, list, server) = await browser(["user:1", "user:2"])
        let editor = try await open("user:1", in: model, list)
        let failure = await editor.delete()
        XCTAssertNil(failure)
        try await waitUntil { model.editor == nil && list.keyCountForTests == 1 }
        XCTAssertNil(list.selectedKey)
        XCTAssertEqual(list.totalKeys, 1)
        XCTAssertTrue(server.commands.contains { $0.arguments == ["UNLINK", "user:1"] })
    }

    @MainActor func testRenameSelectsTheNewNameAndOverwriteAsksFirst() async throws {
        let (model, list, server) = await browser(["user:1", "user:2"])
        let editor = try await open("user:1", in: model, list)

        // Onto an existing key: nothing changes until the user says Replace.
        let asked = await editor.rename(to: Data("user:2".utf8))
        guard case .needsOverwrite = asked else { return XCTFail("expected the overwrite question, got \(asked)") }
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "RENAME" })
        XCTAssertTrue(model.editor === editor)

        let renamed = await editor.rename(to: Data("user:9".utf8))
        XCTAssertEqual(renamed, .renamed)
        try await waitUntil { model.editor?.key == Data("user:9".utf8) }
        let keys = await list.index.keys(in: 0..<list.keyCountForTests)
        XCTAssertEqual(Set(keys), [Data("user:2".utf8), Data("user:9".utf8)])
    }

    @MainActor func testReadOnlyProfileBlocksKeyActions() async throws {
        let server = BrowserKeyspace([0: ["k"]])
        let list = server.list()
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        let editor = try await open("k", in: model, list)
        // The fixture's profile is read-only: no rename, TTL or delete.
        XCTAssertFalse(editor.canRename)
        XCTAssertFalse(editor.canRunKeyAction)
        let result = await editor.rename(to: Data("k2".utf8))
        guard case .failed = result else { return XCTFail("a read-only rename must fail, got \(result)") }
        let failure = await editor.delete()
        XCTAssertNotNil(failure)
        XCTAssertFalse(server.commands.contains { ["RENAMENX", "UNLINK"].contains($0.arguments.first ?? "") })
    }

    @MainActor func testExportNeedsTheWholeValue() async throws {
        // A module type has no editor, so nothing to export; its other actions still run (FR-ED07).
        let (model, list, _) = await browser(["m"])
        let editor = try await open("m", in: model, list)
        XCTAssertNotNil(editor.exportBlock)
        XCTAssertNil(editor.exportData())
        XCTAssertTrue(editor.canRunKeyAction)
    }

    @MainActor func testExportUsesTheLoadedValueOnlyWhenWhole() async throws {
        let small = TransactionalKeyspace(["greeting": "hello"]).session("greeting")
        await small.load()
        XCTAssertNil(small.exportBlock)
        XCTAssertEqual(small.exportData(), Data("hello".utf8))
        XCTAssertEqual(small.copyValueText(), "hello")

        // A 2 MiB string loads its first 1 MiB: exporting that would truncate the file.
        let large = TransactionalKeyspace(["blob": String(repeating: "a", count: 2 * 1_048_576)]).session("blob")
        await large.load()
        XCTAssertNotNil(large.partial)
        XCTAssertNotNil(large.exportBlock)
        XCTAssertNil(large.exportData())

        // A hash paged past its first 500 fields can't export until every page is loaded.
        let fields = (0..<1_200).map { ("f\($0)", "v") }
        let paged = TransactionalKeyspace(hashes: ["h": fields]).session("h", type: .hash)
        await paged.load()
        XCTAssertTrue(paged.hasMore)
        XCTAssertNotNil(paged.exportBlock)
        let whole = TransactionalKeyspace(hashes: ["h": [("name", "Ada")]]).session("h", type: .hash)
        await whole.load()
        XCTAssertNil(whole.exportBlock)
        XCTAssertEqual(whole.exportFileName, "h.json")
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}
