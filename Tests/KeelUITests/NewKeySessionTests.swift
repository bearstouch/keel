import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The new-key sheet through the browser (FR-ED14): the created key is selected and opens; a taken name or a read-only
/// profile creates nothing.
final class NewKeySessionTests: XCTestCase {
    @MainActor private func browser(_ keys: Set<String>, readOnly: Bool = false) async -> (BrowserModel, KeyListDataSource, BrowserKeyspace) {
        let server = BrowserKeyspace([0: keys])
        let list = server.list(readOnly: readOnly); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        return (model, list, server)
    }

    @MainActor func testCreatedKeyIsSelected() async throws {
        let (model, list, server) = await browser(["user:1"])
        XCTAssertTrue(model.canCreateKey)
        let failure = await model.createKey(Data("user:9".utf8), .string(Data("Ada".utf8)), ttlMilliseconds: nil)
        XCTAssertNil(failure)
        // AC2: the new key is in the list, selected, and open in the editor; the footer's total counts it.
        try await waitUntil { model.editor?.key == Data("user:9".utf8) }
        let selected = await list.selectedKeyName()
        XCTAssertEqual(selected, Data("user:9".utf8))
        XCTAssertEqual(list.totalKeys, 2)
        XCTAssertTrue(server.commands.contains { $0.arguments == ["SET", "user:9", "Ada", "NX"] })
    }

    @MainActor func testExistingKeySaysSoAndCreatesNothing() async throws {
        let (model, list, server) = await browser(["user:9"])
        let failure = await model.createKey(Data("user:9".utf8), .string(Data("Ada".utf8)), ttlMilliseconds: nil)
        // AC1
        XCTAssertEqual(failure, "Key already exists")
        XCTAssertEqual(list.keyCountForTests, 1)
        XCTAssertEqual(list.totalKeys, 1)
        XCTAssertNil(list.selectedKey)
        XCTAssertEqual(server.commands.filter { $0.arguments.first == "SET" }.count, 1)
    }

    @MainActor func testReadOnlyProfileBlocksTheSheet() async throws {
        let (model, _, server) = await browser(["k"], readOnly: true)
        // AC3: ⇧⌘N and the menu item are disabled, and a create that slips through sends nothing.
        XCTAssertFalse(model.canCreateKey)
        let failure = await model.createKey(Data("k2".utf8), .string(Data("v".utf8)), ttlMilliseconds: nil)
        XCTAssertNotNil(failure)
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "SET" })
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}
