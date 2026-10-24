import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review extras for KEEL-038: read-only tabs don't offer the delete, and a stale multi-selection names no keys.
final class TypedConfirmationReviewTests: XCTestCase {
    @MainActor private func browser(_ keys: Set<String>, readOnly: Bool = false) async -> (BrowserModel, KeyListDataSource, BrowserKeyspace) {
        let server = BrowserKeyspace([0: keys])
        let list = server.list(readOnly: readOnly); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        return (model, list, server)
    }

    @MainActor private func deleteEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
    }

    @MainActor func testReadOnlyOffersNoDeleteInTheMenuOrOnDeleteKey() async throws {
        let (_, list, _) = await browser(["a", "b", "c"], readOnly: true)
        list.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKeys, [0, 1])
        let titles = list.menuItems(forRow: 0).map(\.title)
        XCTAssertEqual(titles, ["Copy 2 Key Names"])
        XCTAssertFalse(list.handlesDelete(try deleteEvent()))
    }

    @MainActor func testWritableMenuOffersTheDelete() async {
        let (_, list, _) = await browser(["a", "b", "c"])
        list.tableView.selectRowIndexes([0, 2], byExtendingSelection: false)
        XCTAssertTrue(list.menuItems(forRow: 2).map(\.title).contains("Delete 2 Keys…"))
    }

    @MainActor func testSelectionFromBeforeARestartAsksNothing() async {
        let (model, list, server) = await browser(["a", "b", "c", "d"])
        list.tableView.selectRowIndexes([1, 2], byExtendingSelection: false)
        // A restart moves every index; until the list reloads, the rows on screen still name the old keys.
        await list.index.restart()
        await model.requestDeleteSelection()
        XCTAssertNil(model.deleteConfirmation)
        // The reload drops the selection, so nothing is offered afterwards either.
        await list.reload()
        XCTAssertTrue(list.selectedKeys.isEmpty)
        await model.requestDeleteSelection()
        XCTAssertNil(model.deleteConfirmation)
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "UNLINK" })
    }
}
