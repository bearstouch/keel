import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class WelcomeModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-welcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    @MainActor private func makeApp(_ store: ProfileStore, reopens: Bool = true) async -> AppModel {
        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore(reopens: reopens)
        return app
    }

    @MainActor private func makeWelcome(_ store: ProfileStore, _ app: AppModel, clipboard: String? = nil) async throws -> (WelcomeModel, ConnectionSheetPresenter) {
        let presenter = ConnectionSheetPresenter(store: store, tester: FakeConnectionTester())
        let sidebar = SidebarModel(store: store, tabs: try XCTUnwrap(app.windows.first), sheets: presenter, copy: { _ in })
        await sidebar.reload()
        return (WelcomeModel(sidebar: sidebar, connections: presenter, readClipboard: { clipboard }), presenter)
    }

    @MainActor private func waitForSheet(_ presenter: ConnectionSheetPresenter) async throws -> ConnectionSheetModel {
        for _ in 0..<200 where presenter.model == nil { try await Task.sleep(for: .milliseconds(5)) }
        return try XCTUnwrap(presenter.model)
    }

    /// FR-AP08: profiles opened in a tab are the recents, newest first, each once, at most `recentLimit`; a deleted
    /// profile drops out; they survive relaunch, even with "Reopen windows and tabs" off.
    @MainActor func testRecentConnections() async throws {
        let store = await Self.makeStore(in: directory)
        let cache = try await store.create(ConnectionSettings(name: "cache", label: .red, host: "10.0.0.5", port: 6380))
        let queue = try await store.create(ConnectionSettings(name: "queue", host: "queue.internal"))
        let app = await makeApp(store)
        let (welcome, _) = try await makeWelcome(store, app)
        XCTAssertEqual(welcome.recents, [], "Nothing opened yet")
        XCTAssertTrue(welcome.hasProfiles)

        welcome.open(cache.id)
        welcome.open(queue.id)
        welcome.open(cache.id)
        XCTAssertEqual(welcome.recents.map(\.id), [cache.id, queue.id], "Newest first, each profile once")
        let first = try XCTUnwrap(welcome.recents.first)
        XCTAssertEqual(first.name, "cache")
        XCTAssertEqual(first.address, "10.0.0.5:6380")
        XCTAssertEqual(first.accessibilityLabel, "cache, Production, 10.0.0.5:6380")
        XCTAssertEqual(welcome.recents.last?.accessibilityLabel, "queue, no label, queue.internal:6379")
        XCTAssertEqual(app.windows.first?.tabs.count, 2, "Opening a recent focuses its tab instead of adding one")

        await app.flush()
        let relaunched = await makeApp(store, reopens: false)
        XCTAssertEqual(relaunched.windows.first?.tabs, [], "Reopen off: no tabs")
        XCTAssertEqual(relaunched.recentProfileIDs, [cache.id, queue.id], "…but the recents are kept")

        try await store.delete(cache.id)
        let (afterDelete, _) = try await makeWelcome(store, relaunched)
        XCTAssertEqual(afterDelete.recents.map(\.id), [queue.id], "A deleted profile is no longer shown")
        relaunched.closeAll(profileID: cache.id)
        XCTAssertEqual(relaunched.recentProfileIDs, [queue.id], "…and is forgotten")
    }

    @MainActor func testRecentsAreBounded() async throws {
        let store = await Self.makeStore(in: directory)
        var ids: [UUID] = []
        for index in 0..<(WindowsDocument.maximumRecents + 2) { ids.append(try await store.create(ConnectionSettings(name: "p\(index)")).id) }
        let app = await makeApp(store)
        let (welcome, _) = try await makeWelcome(store, app)
        for id in ids { welcome.open(id) }
        XCTAssertEqual(app.recentProfileIDs, Array(ids.reversed().prefix(WindowsDocument.maximumRecents)), "The saved list keeps the newest")
        XCTAssertEqual(welcome.recents.map(\.id), Array(ids.reversed().prefix(WelcomeModel.recentLimit)), "The screen shows fewer")
    }

    /// Paste URL: New Connection filled from a clipboard URL; the URL field doesn't keep it (it may hold a password).
    @MainActor func testPasteURLFillsNewConnection() async throws {
        let store = await Self.makeStore(in: directory)
        let app = await makeApp(store)
        let (welcome, presenter) = try await makeWelcome(store, app, clipboard: "rediss://ops:s3cret@cache.example.com:6390/2")
        welcome.pasteURL()
        let sheet = try await waitForSheet(presenter)
        XCTAssertFalse(sheet.isEditing)
        XCTAssertEqual(sheet.host, "cache.example.com")
        XCTAssertEqual(sheet.port, "6390")
        XCTAssertEqual(sheet.database, "2")
        XCTAssertTrue(sheet.tlsEnabled)
        XCTAssertEqual(sheet.urlText, "")
        XCTAssertNil(sheet.urlMessage)
        sheet.cancel()
    }

    @MainActor func testPasteWithoutURLOpensEmptySheetAndSaysWhy() async throws {
        let store = await Self.makeStore(in: directory)
        let app = await makeApp(store)
        let (welcome, presenter) = try await makeWelcome(store, app, clipboard: "just some text")
        welcome.pasteURL()
        let sheet = try await waitForSheet(presenter)
        XCTAssertEqual(sheet.host, ConnectionSheetModel(mode: .create(folderID: nil), labels: [], hosts: nil, tester: FakeConnectionTester(), store: store).host)
        XCTAssertEqual(sheet.urlMessage, ConnectionSheetPresenter.noURLMessage)
        sheet.cancel()
    }

    /// A sheet already open (Edit Connection) is never filled from the clipboard.
    @MainActor func testPasteURLLeavesAnOpenSheetAlone() async throws {
        let store = await Self.makeStore(in: directory)
        let profile = try await store.create(ConnectionSettings(name: "keep", host: "keep.internal"))
        let app = await makeApp(store)
        let (welcome, presenter) = try await makeWelcome(store, app, clipboard: "redis://other.example.com")
        presenter.edit(profile.id)
        let sheet = try await waitForSheet(presenter)
        welcome.pasteURL()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(presenter.model === sheet)
        XCTAssertEqual(sheet.host, "keep.internal")
        sheet.cancel()
    }
}

final class WindowsDocumentRecentsTests: XCTestCase {
    /// A `windows.json` written before recents existed still loads.
    func testFileWithoutRecentsDecodes() throws {
        let document = try PersistenceCodec.decode(WindowsDocument.self, from: Data(#"{"schemaVersion":1,"windows":[]}"#.utf8))
        XCTAssertEqual(document, WindowsDocument())
    }

    func testRestorableRecentsKeepExistingProfilesOnce() {
        let a = UUID(), b = UUID(), gone = UUID()
        let document = WindowsDocument(recentProfileIDs: [a, gone, b, a] + (0..<20).map { _ in UUID() })
        XCTAssertEqual(document.restorable(profileIDs: [a, b]).recentProfileIDs, [a, b])
    }
}
