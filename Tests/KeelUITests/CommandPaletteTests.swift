import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class CommandPaletteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-palette-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @MainActor private func makeApp(connector: FakeConnector) async throws -> (AppModel, SidebarModel, ConnectionTabs, [String: UUID]) {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let production = try await store.createFolder(named: "Production")
        var ids: [String: UUID] = [:]
        for name in ["payments-staging", "payments-prod", "orders-prod", "payments-prod-replica"] {
            ids[name] = try await store.create(ConnectionSettings(name: name), folderID: name.hasSuffix("staging") ? nil : production.id).id
        }
        let app = AppModel(profiles: store, connector: connector, persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        let window = try XCTUnwrap(app.windows.first)
        let sidebar = SidebarModel(store: store, tabs: window, copy: { _ in })
        await sidebar.reload()
        return (app, sidebar, window, ids)
    }

    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    /// AC1: ⌘K, "prod pay", Return opens payments-prod.
    @MainActor func testProdPayReturnOpensPaymentsProd() async throws {
        let connector = FakeConnector()
        let (app, sidebar, window, ids) = try await makeApp(connector: connector)
        let palette = CommandPaletteModel { PaletteSources.entries(window: window, sidebar: sidebar) }
        palette.toggle()
        XCTAssertTrue(palette.isPresented)
        palette.query = "prod pay"
        XCTAssertEqual(palette.results.first?.title, "payments-prod")
        XCTAssertEqual(palette.selectedID, palette.results.first?.id, "The best match is highlighted, so Return runs it")
        XCTAssertFalse(palette.results.contains { $0.title == "orders-prod" })
        palette.run()
        XCTAssertFalse(palette.isPresented, "The palette closes before the row runs")
        try await wait { window.selected?.profileID == ids["payments-prod"] }
        try await wait { connector.connects.contains { $0.profileID == ids["payments-prod"] } }

        // Opened again, the palette lists the open tab too; the connection still comes first, and choosing it focuses
        // the existing tab rather than opening another.
        palette.present()
        palette.query = "payments-prod tab"
        XCTAssertEqual(palette.results.map(\.kind), [], "Kind labels aren't searched")
        palette.query = "payments-prod"
        XCTAssertEqual(palette.results.prefix(2).map(\.kind), [.connection, .tab])
        palette.run()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(window.tabs.count, 1)
        withExtendedLifetime(app) {}
    }

    @MainActor func testKeyboardSelectionAndDismiss() async throws {
        let (app, sidebar, window, _) = try await makeApp(connector: FakeConnector())
        defer { withExtendedLifetime(app) {} }
        var ran: [String] = []
        let commands = ["Refresh", "Reconnect"].map { title in
            PaletteEntry(PaletteItem(id: "command:\(title)", kind: .action, title: title, subtitle: "View")) { ran.append(title) }
        }
        let palette = CommandPaletteModel { PaletteSources.entries(window: window, sidebar: sidebar, commands: commands) }
        palette.present()
        palette.query = "re"
        // Word starts first; the profiles that only contain "r…e" follow.
        XCTAssertEqual(palette.results.prefix(2).map(\.title), ["Refresh", "Reconnect"])
        palette.moveSelection(by: -1)
        XCTAssertEqual(palette.selectedID, "command:Refresh", "Up stops at the first row")
        palette.moveSelection(by: 1)
        XCTAssertEqual(palette.selectedID, "command:Reconnect")
        palette.moveSelection(by: 100)
        XCTAssertEqual(palette.selectedID, palette.results.last?.id, "Down stops at the last row")
        palette.query = "nothing like it"
        XCTAssertEqual(palette.results, [])
        XCTAssertNil(palette.selectedID)
        palette.run()
        XCTAssertTrue(palette.isPresented, "Return with no match does nothing")
        palette.toggle()
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(palette.results, [])
        palette.run("command:Refresh")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ran, [], "A closed palette runs nothing")
        palette.present()
        palette.query = "reconn"
        palette.run()
        try await wait { ran == ["Reconnect"] }
    }

    /// Recent keys are listed in the palette from memory and never reach `windows.json`.
    @MainActor func testRecentKeysListedButNeverSaved() async throws {
        let (app, sidebar, window, ids) = try await makeApp(connector: FakeConnector())
        let tab = window.open(profileID: try XCTUnwrap(ids["orders-prod"]), database: 2)
        let session = try XCTUnwrap(app.session(tab.id))
        session.onKeyOpened?(Data("order:secret-7781".utf8), 2)
        XCTAssertEqual(app.recentKeys.entries.map(\.key), [Data("order:secret-7781".utf8)])
        let palette = CommandPaletteModel { PaletteSources.entries(window: window, sidebar: sidebar) }
        palette.present()
        palette.query = "secret"
        XCTAssertEqual(palette.results.map(\.kind), [.recentKey])
        XCTAssertEqual(palette.results.first?.subtitle, "orders-prod · db2")

        await app.flush()
        let saved = try Data(contentsOf: directory.appendingPathComponent(PersistedFile.windows.fileName))
        XCTAssertNil(String(decoding: saved, as: UTF8.self).range(of: "secret-7781"), "Key names from browsing are never persisted")
        // A deleted profile's recent keys go with its tabs.
        app.closeAll(profileID: try XCTUnwrap(ids["orders-prod"]))
        XCTAssertEqual(app.recentKeys.entries, [])
    }
}
