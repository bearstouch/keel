import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class SidebarModelReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-sidebar-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @MainActor func testReturnNeverOpensASelectionMovedIntoACollapsedFolder() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let folder = try await store.createFolder(named: "Archive")
        _ = try await store.setFolderCollapsed(folder.id, true)
        let profile = try await store.create(ConnectionSettings(name: "old-cache"))
        let tabs = ConnectionTabs()
        let model = SidebarModel(store: store, tabs: tabs, copy: { _ in })
        await model.reload()
        model.selectedProfileID = profile.id
        await model.move(profile.id, toFolder: folder.id)
        model.openSelection()
        XCTAssertTrue(tabs.tabs.isEmpty, "The row is hidden, so Return opens nothing")
    }

    /// FR-CN01 + MAC-06: the delete confirmation lists the tabs that will close, and a tab with unsaved edits is asked
    /// about first; until the user discards them nothing is removed.
    @MainActor func testDeletingAProfileListsItsTabsAndAsksAboutUnsavedEdits() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let gone = try await store.create(ConnectionSettings(name: "gone"))
        let kept = try await store.create(ConnectionSettings(name: "kept"))
        let connector = FakeConnector()
        let app = AppModel(profiles: store, connector: connector, persistence: nil)
        await app.restore()
        let first = app.windows.first ?? app.newWindow()
        let second = app.newWindow()
        let model = SidebarModel(store: store, tabs: first, copy: { _ in })
        await model.reload()
        let plain = first.open(profileID: gone.id, database: 0)
        first.open(profileID: kept.id, database: 0)
        let edited = second.open(profileID: gone.id, database: 3)
        for _ in 0..<200 where app.session(edited.id)?.status != .connected || app.session(plain.id)?.status != .connected { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(model.deleteConfirmation(gone.id).openTabs, ["db0 in window 1", "db3 in window 2"])
        XCTAssertEqual(
            model.deleteConfirmation(gone.id).message, "Its 2 open tabs close: db0 in window 1, db3 in window 2. Its saved password is removed from the Keychain.")
        XCTAssertEqual(model.deleteConfirmation(UUID()).message, "Its saved password is removed from the Keychain.")

        app.session(edited.id)?.hasUnsavedEdits = true
        XCTAssertEqual(model.deleteConfirmation(gone.id), .init(openTabs: ["db0 in window 1", "db3 in window 2 (unsaved changes)"], unsavedTabs: 1))
        // Cancel at the unsaved-changes question: nothing removed, every tab and session stays.
        let asked = await model.delete(gone.id)
        XCTAssertEqual(asked, .needsDiscardConfirmation(unsavedTabs: 1))
        let stillThere = await store.profile(gone.id)
        XCTAssertNotNil(stillThere)
        XCTAssertEqual(first.tabs.map(\.profileID), [gone.id, kept.id])
        XCTAssertEqual(second.tabs.map(\.id), [edited.id])
        XCTAssertEqual(app.session(edited.id)?.hasUnsavedEdits, true)
        XCTAssertEqual(connector.closed, 0)

        // Discarding deletes the profile and closes its tabs in every window.
        let deleted = await model.delete(gone.id, discardingEdits: true)
        XCTAssertEqual(deleted, .deleted)
        let removed = await store.profile(gone.id)
        XCTAssertNil(removed)
        XCTAssertEqual(first.tabs.map(\.profileID), [kept.id])
        XCTAssertTrue(second.tabs.isEmpty)
        XCTAssertNil(app.session(edited.id))
    }

    @MainActor func testSameGroupDropPositions() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let a = try await store.create(ConnectionSettings(name: "a"))
        let b = try await store.create(ConnectionSettings(name: "b"))
        let c = try await store.create(ConnectionSettings(name: "c"))
        let model = SidebarModel(store: store, tabs: ConnectionTabs(), copy: { _ in })
        await model.reload()
        let names = { model.groups.first?.rows.map(\.name) }
        // Dragging down: a before c lands between b and c.
        await model.move(a.id, toFolder: nil, before: c.id)
        XCTAssertEqual(names(), ["b", "a", "c"])
        // Dropping right before the next row is where it already is: nothing is written.
        let revision = await store.document.revision
        await model.move(a.id, toFolder: nil, before: c.id)
        let unchanged = await store.document.revision
        XCTAssertEqual(unchanged, revision)
        // To the end of the group, and back to the top.
        await model.move(b.id, toFolder: nil)
        XCTAssertEqual(names(), ["a", "c", "b"])
        await model.move(b.id, toFolder: nil, before: a.id)
        XCTAssertEqual(names(), ["b", "a", "c"])
    }

    @MainActor func testMoveFolderToEndAndBack() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let one = try await store.createFolder(named: "One")
        _ = try await store.createFolder(named: "Two")
        let three = try await store.createFolder(named: "Three")
        let model = SidebarModel(store: store, tabs: ConnectionTabs(), copy: { _ in })
        await model.reload()
        await model.moveFolder(one.id, before: nil)
        XCTAssertEqual(model.groups.compactMap(\.name), ["Two", "Three", "One"])
        await model.moveFolder(one.id, before: three.id)
        XCTAssertEqual(model.groups.compactMap(\.name), ["Two", "One", "Three"])
        let saved = await store.folders.map(\.name)
        XCTAssertEqual(saved, ["Two", "One", "Three"])
    }
}
