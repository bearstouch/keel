import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

final class KeyFilterModelTests: XCTestCase {
    static let keys = ["user:1", "session:a", "USER:2", "config:version", "order:user:9", "health"]

    @MainActor func testLocalFilterListsMatchesFlatInEitherMode() async throws {
        let list = await keyList(Self.keys)
        list.tableView.frame.size.height = 600
        XCTAssertTrue(list.scrollView.documentView === list.outlineView)

        await list.setLocalFilter("user")
        XCTAssertEqual(list.mode, .tree, "the mode is kept for when the filter is cleared")
        XCTAssertTrue(list.scrollView.documentView === list.tableView, "matches show flat, with full names")
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:1", "USER:2", "order:user:9"])
        XCTAssertEqual(list.child(atRow: 1), .key(2))

        // Selecting a match selects that key; narrowing past it keeps the key selected but shows no row.
        list.tableView.selectRowIndexes([2], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKey, 4)
        await list.setLocalFilter("user:")
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:1", "USER:2", "order:user:9"])
        XCTAssertEqual(list.tableView.selectedRow, 2)
        await list.setLocalFilter("user:1")
        XCTAssertEqual(list.selectedKey, 4)
        XCTAssertEqual(list.tableView.selectedRow, -1)

        // A page loaded while filtering is searched too.
        await list.index.ingest([Data("user:10".utf8), Data("other".utf8)])
        await list.reload()
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:1", "user:10"])

        // Clearing the filter brings the tree back.
        await list.setLocalFilter("")
        XCTAssertTrue(list.scrollView.documentView === list.outlineView)
        XCTAssertEqual(list.visibleRowCount, 7, "config, order, session, user, USER, health, other")
    }

    @MainActor func testKeysLoadedBeforeTheReloadAreSearchedByIt() async throws {
        let list = await keyList(Self.keys, mode: .flat)
        // A page lands in the index before the list reloads; the search must stop at the rows the list has.
        await list.index.ingest([Data("user:late".utf8)])
        await list.setLocalFilter("user")
        XCTAssertEqual(list.visibleRowCount, 3)
        await list.reload()
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:1", "USER:2", "order:user:9", "user:late"])
    }

    @MainActor func testLocalFilterStartsOverAfterARestart() async throws {
        let list = await keyList(Self.keys, mode: .flat)
        await list.setLocalFilter("user")
        XCTAssertEqual(list.visibleRowCount, 3)
        await list.index.restart()
        await list.reload()
        XCTAssertEqual(list.visibleRowCount, 0, "matches from before the restart point at other keys")
        await list.index.ingest(["user:x", "nope"].map { Data($0.utf8) })
        await list.reload()
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:x"])
    }

    @MainActor func testChangingAFilterRestartsTheScan() async throws {
        let list = await keyList(Self.keys)
        var starts = 0
        let model = KeyFilterModel(list: list) { index in
            starts += 1
            await index.ingest([Data("user:1".utf8)])
        }

        model.patternText = "user:*"
        await model.applyPattern()
        var filter = await list.index.configuration.filter
        XCTAssertEqual(filter, KeyFilter(pattern: "user:*"))
        XCTAssertEqual(model.applied, filter)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(list.visibleRowCount, 1, "the old keys are gone; only the new scan's key shows")

        // The same filter again doesn't rescan; the type menu does, keeping the typed pattern.
        await model.applyPattern()
        XCTAssertEqual(starts, 1)
        await model.setType(.hash)
        filter = await list.index.configuration.filter
        XCTAssertEqual(filter, KeyFilter(pattern: "user:*", type: .hash))
        XCTAssertEqual(starts, 2)
        XCTAssertNil(model.notice)

        // AC4: a type the server can't select says it's filtered here.
        await model.setType(.other)
        XCTAssertNotNil(model.notice)
        await model.setType(nil)
        XCTAssertNil(model.notice)
        XCTAssertEqual(starts, 4)
    }

    @MainActor func testLeavingLocalModeClearsTheLocalFilter() async {
        let list = await keyList(Self.keys)
        let model = KeyFilterModel(list: list) { _ in }
        await model.setField(.local)
        await model.setLocalText("session")
        XCTAssertEqual(list.visibleRowCount, 1)
        await model.setField(.pattern)
        XCTAssertEqual(model.localText, "")
        XCTAssertEqual(list.localQuery, "")
        XCTAssertTrue(list.scrollView.documentView === list.outlineView)
    }

    @MainActor func testCommandFFocusesOnlyItsWindowsField() async {
        let list = await keyList(Self.keys)
        let model = KeyFilterModel(list: list) { _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = list.scrollView
        NotificationCenter.default.post(name: KeyListCommands.focusFilterNotification, object: NSWindow())
        XCTAssertEqual(model.focusRequest, 0, "another window's ⌘F")
        NotificationCenter.default.post(name: KeyListCommands.focusFilterNotification, object: nil)
        XCTAssertEqual(model.focusRequest, 0, "no key window")
        NotificationCenter.default.post(name: KeyListCommands.focusFilterNotification, object: window)
        XCTAssertEqual(model.focusRequest, 1)
    }
}
