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
