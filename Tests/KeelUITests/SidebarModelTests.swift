import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class SidebarModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    @MainActor private static func makeModel(_ store: ProfileStore, tabs: ConnectionTabs = ConnectionTabs()) async -> SidebarModel {
        let model = SidebarModel(store: store, tabs: tabs, copy: { _ in })
        await model.reload()
        return model
    }

    private static func names(_ group: SidebarModel.Group) -> [String] { group.rows.map(\.name) }

    @MainActor func testGroupsAndOrderFromStore() async throws {
        let store = await Self.makeStore(in: directory)
        let prod = try await store.createFolder(named: "Production")
        let staging = try await store.createFolder(named: "Staging")
        _ = try await store.create(ConnectionSettings(name: "payments-prod", label: .red, host: "pay.internal"), folderID: prod.id)
        _ = try await store.create(ConnectionSettings(name: "local-dev", label: .green))
        _ = try await store.create(ConnectionSettings(name: "orders-prod", label: .red), folderID: prod.id)
        _ = try await store.create(ConnectionSettings(name: "api-staging", label: .orange, port: 6380), folderID: staging.id)
        let model = await Self.makeModel(store)

        let groups = model.groups
        XCTAssertEqual(groups.map(\.name), [nil, "Production", "Staging"], "Top-level profiles first, without a heading, then folders in order")
        XCTAssertEqual(groups.map(Self.names), [["local-dev"], ["payments-prod", "orders-prod"], ["api-staging"]])
        XCTAssertEqual(groups[1].rows[0].labelName, "Production")
        XCTAssertEqual(groups[1].rows[0].tooltip, "pay.internal:6379", "Host and port live in the tooltip, not the row")
        XCTAssertEqual(groups[2].rows[0].tooltip, "127.0.0.1:6380")

        // An empty folder still shows its heading, so profiles can be dropped into it.
        _ = try await store.createFolder(named: "Empty")
        await model.reload()
        XCTAssertEqual(model.groups.last?.name, "Empty")
        XCTAssertEqual(model.groups.last?.rows, [])

        // Collapsing hides the folder's rows from the keyboard walk and survives relaunch (AC1).
        await model.setCollapsed(prod.id, true)
        XCTAssertEqual(model.visibleRows.map(\.name), ["local-dev", "api-staging"])
        let relaunched = await Self.makeModel(await Self.makeStore(in: directory))
        XCTAssertEqual(relaunched.groups.first { $0.folderID == prod.id }?.collapsed, true)
    }

    @MainActor func testDragReorderPersists() async throws {
        let store = await Self.makeStore(in: directory)
        let prod = try await store.createFolder(named: "Production")
        let local = try await store.createFolder(named: "Local")
        let a = try await store.create(ConnectionSettings(name: "a"), folderID: prod.id)
        let b = try await store.create(ConnectionSettings(name: "b"), folderID: prod.id)
        let c = try await store.create(ConnectionSettings(name: "c"), folderID: local.id)
        let model = await Self.makeModel(store)

        // Reorder within a folder: b before a.
        let accepted = await model.drop([SidebarModel.DragItem.profile(b.id).payload], into: prod.id, beforeProfile: a.id)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.groups.first { $0.folderID == prod.id }.map(Self.names), ["b", "a"])

        // Move between folders: a dropped before c in Local; then c onto the Production heading (the end).
        await model.drop([SidebarModel.DragItem.profile(a.id).payload], into: local.id, beforeProfile: c.id)
        await model.drop([SidebarModel.DragItem.profile(c.id).payload], into: prod.id)
        XCTAssertEqual(model.groups.first { $0.folderID == prod.id }.map(Self.names), ["b", "c"])
        XCTAssertEqual(model.groups.first { $0.folderID == local.id }.map(Self.names), ["a"])

        // Folders reorder among themselves: Local before Production.
        await model.drop([SidebarModel.DragItem.folder(local.id).payload], into: prod.id)
        XCTAssertEqual(model.groups.compactMap(\.name), ["Local", "Production"])

        // Text from another app is ignored and writes nothing.
        let revision = await store.document.revision
        let foreign = await model.drop(["redis://evil:6379", a.id.uuidString], into: nil)
        XCTAssertFalse(foreign)
        let unchanged = await store.document.revision
        XCTAssertEqual(unchanged, revision)

        // Dropping a profile where it already is writes nothing either.
        await model.drop([SidebarModel.DragItem.profile(c.id).payload], into: prod.id)
        let stillUnchanged = await store.document.revision
        XCTAssertEqual(stillUnchanged, revision)

        // Everything survives relaunch (AC1).
        let relaunched = await Self.makeModel(await Self.makeStore(in: directory))
        XCTAssertEqual(relaunched.groups.compactMap(\.name), ["Local", "Production"])
        XCTAssertEqual(relaunched.groups.map(Self.names), [["a"], ["b", "c"]])
    }

    @MainActor func testAccessibilityLabelIncludesStatus() async throws {
        let store = await Self.makeStore(in: directory)
        let prod = try await store.create(ConnectionSettings(name: "payments-prod", label: .red))
        _ = try await store.create(ConnectionSettings(name: "scratch"))
        let tabs = ConnectionTabs()
        let model = await Self.makeModel(store, tabs: tabs)

        XCTAssertEqual(model.groups[0].rows.map(\.accessibilityLabel), ["payments-prod, Production, not connected", "scratch, no label, not connected"])
        let tab = tabs.open(profileID: prod.id, database: 0)
        tabs.setStatus(.connected, for: tab.id)
        XCTAssertEqual(model.groups[0].rows[0].accessibilityLabel, "payments-prod, Production, connected", "FR-CN13's VoiceOver reading")
        XCTAssertEqual(model.groups[0].rows[0].status, .connected)
        tabs.setStatus(.failed, for: tab.id)
        XCTAssertEqual(model.groups[0].rows[0].accessibilityLabel, "payments-prod, Production, failed")

        // A renamed label reads its new name.
        try await store.renameLabel(.red, to: "Live")
        await model.reload()
        XCTAssertEqual(model.groups[0].rows[0].accessibilityLabel, "payments-prod, Live, failed")
    }

    @MainActor func testOpenFocusesExistingTab() async throws {
        let store = await Self.makeStore(in: directory)
        let pay = try await store.create(ConnectionSettings(name: "payments-prod", database: 2))
        let other = try await store.create(ConnectionSettings(name: "local-dev"))
        let tabs = ConnectionTabs()
        let model = await Self.makeModel(store, tabs: tabs)

        model.open(pay.id)
        let first = try XCTUnwrap(tabs.selected)
        XCTAssertEqual(first.database, 2, "The tab opens on the profile's database")
        model.open(other.id)
        XCTAssertEqual(tabs.tabs.count, 2)

        // Opening again focuses the existing tab for the same profile and db (AC3).
        model.open(pay.id)
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertEqual(tabs.selectedID, first.id)
        XCTAssertEqual(model.selectedProfileID, pay.id)

        // ⌥ forces a new tab.
        model.open(pay.id, newTab: true)
        XCTAssertEqual(tabs.tabs.count, 3)
        XCTAssertNotEqual(tabs.selectedID, first.id)

        // Return opens the keyboard selection.
        model.selectedProfileID = other.id
        model.openSelection()
        XCTAssertEqual(tabs.selected?.profileID, other.id)
        XCTAssertEqual(tabs.tabs.count, 3)

        // Deleting a profile closes its tabs.
        await model.delete(pay.id)
        XCTAssertEqual(tabs.tabs.map(\.profileID), [other.id])
    }
}

final class SidebarModelBehaviorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @MainActor func testFollowsChangesMadeElsewhere() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let model = SidebarModel(store: store, tabs: ConnectionTabs(), copy: { _ in })
        model.start()
        // The sheet saves through the store, not the sidebar; the row must still appear.
        _ = try await store.create(ConnectionSettings(name: "from-sheet"))
        for _ in 0..<200 where model.document.profiles.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.groups.first?.rows.map(\.name), ["from-sheet"])
    }

    @MainActor func testCopyURLNeverIncludesPassword() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache", host: "cache.internal", username: "app", database: 3), password: Data("s3cret".utf8))
        var copied: [String] = []
        let model = SidebarModel(store: store, tabs: ConnectionTabs(), copy: { copied.append($0) })
        await model.reload()
        model.copyURL(profile.id)
        XCTAssertEqual(copied, ["redis://app@cache.internal:6379/3"])
    }

    @MainActor func testRefusedChangeKeepsStateAndExplains() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let folder = try await store.createFolder(named: "Production")
        let model = SidebarModel(store: store, tabs: ConnectionTabs(), copy: { _ in })
        await model.reload()
        await model.renameFolder(folder.id, to: "   ")
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.groups.compactMap(\.name), ["Production"], "The previous name stays")
        let saved = await store.folders.map(\.name)
        XCTAssertEqual(saved, ["Production"])
    }

    @MainActor func testCollapsingHidesTheSelection() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let folder = try await store.createFolder(named: "Staging")
        let profile = try await store.create(ConnectionSettings(name: "api-staging"), folderID: folder.id)
        let tabs = ConnectionTabs()
        let model = SidebarModel(store: store, tabs: tabs, copy: { _ in })
        await model.reload()
        model.selectedProfileID = profile.id
        await model.toggleCollapsed(folder.id)
        model.openSelection()
        XCTAssertNil(model.selectedProfileID)
        XCTAssertTrue(tabs.tabs.isEmpty, "Return can't open a row hidden in a collapsed folder")
    }
}
