import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// An index that never connects: tests add keys with `ingest`, so no SCAN is sent.
func offlineIndex() -> KeyIndex {
    let session = ServerSession(open: { _, _ throws(ConnectionFailure) in
        throw ConnectionFailure(category: .connectionRefused, message: "offline", suggestion: "")
    })
    return KeyIndex(service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
}

@MainActor
func keyList(_ keys: [String], mode: KeyListDataSource.Mode = .tree) async -> KeyListDataSource {
    let index = offlineIndex()
    await index.ingest(keys.map { Data($0.utf8) })
    let list = KeyListDataSource(index: index, mode: mode)
    await list.reload()
    await list.fetchVisibleContent()
    return list
}

extension KeyListDataSource {
    /// The active view's row showing `name`, after its content was fetched.
    func row(named name: String) -> Int? { (0..<visibleRowCount).first { row(at: $0)?.name == name } }

    func expand(named name: String) async throws {
        let row = try XCTUnwrap(row(named: name), "no row \(name)")
        await expand(try XCTUnwrap(outlineView.item(atRow: row) as? KeyListItem))
        await fetchVisibleContent()
    }

    var names: [String] { (0..<visibleRowCount).map { row(at: $0)?.name ?? "?" } }
}

final class KeyListDataSourceTests: XCTestCase {
    static let keys = ["user:1", "user:2", "user:3", "session:a", "config:version", "health"]

    @MainActor func testRowCountMatchesVisibleTree() async throws {
        let list = await keyList(Self.keys)
        // Folders first, then keys, in byte order; collapsed folders contribute one row each.
        XCTAssertEqual(list.names, ["config", "session", "user", "health"])
        XCTAssertEqual(list.outlineView.numberOfRows, 4)

        try await list.expand(named: "user")
        XCTAssertEqual(list.names, ["config", "session", "user", "1", "2", "3", "health"])
        try await list.expand(named: "session")
        XCTAssertEqual(list.visibleRowCount, 8)

        list.outlineView.collapseItem(list.outlineView.item(atRow: try XCTUnwrap(list.row(named: "user"))))
        XCTAssertEqual(list.visibleRowCount, 5)

        // A page loads: counts update and the expanded folder stays expanded with its new child.
        await list.index.ingest([Data("session:b".utf8)])
        await list.reload()
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["config", "session", "a", "b", "user", "health"])
        XCTAssertEqual(list.row(at: try XCTUnwrap(list.row(named: "session")))?.keyCount, 2)

        // The flat view lists every loaded key.
        await list.setMode(.flat)
        XCTAssertEqual(list.visibleRowCount, 7)
        XCTAssertTrue(list.scrollView.documentView === list.tableView)
    }

    @MainActor func testSelectionSurvivesViewToggle() async throws {
        let list = await keyList(Self.keys, mode: .flat)
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, Self.keys)

        // The user picks user:2 in the flat view; the tree expands `user` to reveal it.
        list.tableView.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKey, 1)
        await list.toggleMode()
        XCTAssertEqual(list.mode, .tree)
        let treeRow = list.outlineView.selectedRow
        XCTAssertEqual(list.child(atRow: treeRow), .key(1))
        await list.fetchVisibleContent()
        XCTAssertEqual(list.row(at: treeRow)?.name, "2")

        // Picking another key in the tree carries back to the flat view.
        list.outlineView.selectRowIndexes([try XCTUnwrap(list.row(named: "3"))], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKey, 2)
        await list.toggleMode()
        XCTAssertEqual(list.tableView.selectedRow, 2)

        // A reload keeps the selection; a restart that puts another key at that index clears it.
        await list.reload()
        XCTAssertEqual(list.tableView.selectedRow, 2)
        await list.index.restart()
        await list.index.ingest(["x", "y", "z"].map { Data($0.utf8) })
        await list.reload()
        XCTAssertNil(list.selectedKey)
        XCTAssertEqual(list.tableView.selectedRow, -1)
    }

    @MainActor func testAccessibilityLabels() async throws {
        let list = await keyList(Self.keys)
        await list.index.updateMetadata(at: 0) { $0.type = .hash }
        try await list.expand(named: "user")
        let userRow = try XCTUnwrap(list.row(named: "user"))
        XCTAssertEqual(list.row(at: userRow)?.accessibilityLabel, "user, 3 keys")
        XCTAssertEqual(list.row(at: userRow + 1)?.accessibilityLabel, "1, hash")
        XCTAssertEqual(list.row(at: userRow + 2)?.accessibilityLabel, "2")
        // The cell VoiceOver reads carries the label.
        let cell = try XCTUnwrap(list.outlineView.view(atColumn: 0, row: userRow + 1, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityLabel(), "1, hash")
        XCTAssertTrue(cell.isAccessibilityElement())

        // TTL only for expiring keys; the badge is text, not color only (DS-04).
        let expiring = KeyListRow(child: .key(0), name: "user:1042", keyCount: 1, type: .zset, ttl: "3d")
        XCTAssertEqual(expiring.accessibilityLabel, "user:1042, sorted set, expires in 3d")
        XCTAssertEqual(expiring.badge, "ZSET")
        XCTAssertEqual(expiring.meta, "3d")
        let folder = KeyListRow(child: .folder(.root), name: "session", keyCount: 902_114)
        XCTAssertEqual(folder.accessibilityLabel, "session, 902,114 keys")
        XCTAssertEqual(folder.meta, "902,114")
        XCTAssertNil(folder.badge)
        XCTAssertEqual(KeyListRow(child: .folder(.root), name: "q", keyCount: 1).accessibilityLabel, "q, 1 key")
    }
}
