import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Connects without a server: records each connect and answers with `result` (an offline session when it succeeds).
final class FakeConnector: SessionConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(UUID, Int)] = []
    private var closes = 0
    var fails: ConnectionFailure?
    /// Runs inside each connect before it answers, so a test can act while a tab is connecting.
    var during: (@Sendable () async -> Void)?
    /// What the connected session enforces.
    var safety = SafetyProfile(name: "t", readOnly: true)

    var connects: [(profileID: UUID, database: Int)] { lock.withLock { calls.map { ($0.0, $0.1) } } }
    var closed: Int { lock.withLock { closes } }

    func connect(profileID: UUID, database: Int) async -> Result<ConnectedServer, ConnectionFailure> {
        lock.withLock { calls.append((profileID, database)) }
        await during?()
        if let fails { return .failure(fails) }
        let session = ServerSession(open: { _, _ throws(ConnectionFailure) in throw ConnectionFailure(category: .connectionRefused, message: "offline", suggestion: "") })
        let identity = ServerIdentity(kind: .redis, version: ServerVersion("7.4.0"), redisCompatibleVersion: ServerVersion("7.4.0"), mode: .standalone, role: "master")
        return .success(
            ConnectedServer(
                session: session, service: DataCommandService(session: session), identity: identity, databaseCount: 16, safety: safety,
                close: { [weak self] in self?.lock.withLock { self?.closes += 1 } }))
    }
}

final class WindowModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    @MainActor private func makeApp(_ store: ProfileStore, connector: FakeConnector = FakeConnector()) async -> AppModel {
        let app = AppModel(profiles: store, connector: connector, persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        return app
    }

    /// Waits for a tab's session to settle; connects run in tasks the model starts.
    @MainActor private func settle(_ app: AppModel, _ tabID: UUID, to status: ConnectionStatus) async throws {
        for _ in 0..<200 where app.session(tabID)?.status != status { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.session(tabID)?.status, status)
    }

    // MARK: - Story tests

    @MainActor func testTabsPersistAndRestoreDisconnected() async throws {
        let store = await Self.makeStore(in: directory)
        let payments = try await store.create(ConnectionSettings(name: "payments", database: 2))
        let cache = try await store.create(ConnectionSettings(name: "cache"))
        let connector = FakeConnector()
        let app = await makeApp(store, connector: connector)
        XCTAssertEqual(app.windows.count, 1, "a first launch opens one empty window")
        let first = try XCTUnwrap(app.windows.first)

        // AC1: two windows show different tabs of the same profile.
        let a = first.open(profileID: payments.id, database: 2)
        let b = first.open(profileID: cache.id, database: 0)
        first.setMode(.info)
        let second = app.newWindow()
        let c = second.open(profileID: payments.id, database: 5)
        second.setMode(.console)
        app.setFrame(SavedFrame(x: 40, y: 60, width: 1200, height: 760), for: second.id)
        for id in [a.id, b.id, c.id] { try await settle(app, id, to: .connected) }
        XCTAssertEqual(app.status(ofProfile: payments.id), .connected)
        first.selectedID = a.id
        await app.flush()

        // Relaunch: the same windows, tabs, modes, dbs, selection and frame, all disconnected; nothing connects.
        let relaunched = AppModel(profiles: store, connector: connector, persistence: Persistence(directory: directory))
        let restored = await relaunched.restore()
        let connectsBefore = connector.connects.count
        XCTAssertEqual(relaunched.windows.map(\.id), [first.id, second.id])
        XCTAssertEqual(relaunched.windows[0].tabs.map(\.saved), [a.id, b.id].map { id in first.tabs.first { $0.id == id }!.saved })
        XCTAssertEqual(relaunched.windows[0].tabs.map(\.mode), [.browser, .info])
        XCTAssertEqual(relaunched.windows[0].selectedID, a.id)
        XCTAssertEqual(relaunched.windows[1].tabs.map(\.database), [5])
        XCTAssertEqual(relaunched.windows[1].tabs.map(\.mode), [.console])
        XCTAssertEqual(restored.map(\.frame), [nil, SavedFrame(x: 40, y: 60, width: 1200, height: 760)])
        XCTAssertTrue(relaunched.windows.flatMap(\.tabs).allSatisfy { $0.status == .disconnected })
        XCTAssertTrue(relaunched.sessions.values.allSatisfy { $0.status == .disconnected })
        XCTAssertEqual(connector.connects.count, connectsBefore)

        // The file never names a key, a value or a status.
        let text = try String(contentsOf: directory.appendingPathComponent("windows.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("connected"))
        XCTAssertTrue(text.contains("\"schemaVersion\""))
    }

    @MainActor func testMoveTabBetweenWindows() async throws {
        let store = await Self.makeStore(in: directory)
        let payments = try await store.create(ConnectionSettings(name: "payments"))
        let cache = try await store.create(ConnectionSettings(name: "cache"))
        let connector = FakeConnector()
        let app = await makeApp(store, connector: connector)
        let left = try XCTUnwrap(app.windows.first)
        let moving = left.open(profileID: payments.id, database: 0)
        let staying = left.open(profileID: cache.id, database: 0)
        left.selectedID = moving.id
        try await settle(app, moving.id, to: .connected)
        let session = try XCTUnwrap(app.session(moving.id))
        let right = app.newWindow()

        // Dragged to the other window: it keeps its session (no new connect), is selected there, and the source
        // selects its neighbor.
        app.moveTab(moving.id, to: right, at: 0)
        XCTAssertEqual(left.tabs.map(\.id), [staying.id])
        XCTAssertEqual(left.selectedID, staying.id)
        XCTAssertEqual(right.tabs.map(\.id), [moving.id])
        XCTAssertEqual(right.selectedID, moving.id)
        XCTAssertTrue(app.session(moving.id) === session)
        XCTAssertEqual(session.status, .connected)
        XCTAssertEqual(right.tabs.first?.status, .connected)
        XCTAssertEqual(connector.connects.count, 2)
        XCTAssertEqual(connector.closed, 0)
        XCTAssertEqual(app.document.windows.map { $0.tabs.map(\.id) }, [[staying.id], [moving.id]])

        // Status changes after the move reach the window that shows the tab now.
        await app.disconnect(moving.id)
        XCTAssertEqual(right.tabs.first?.status, .disconnected)
        XCTAssertEqual(connector.closed, 1)

        // Within one window a drop reorders; "Move to New Window" makes a window of its own.
        let third = right.open(profileID: cache.id, database: 1, newTab: true)
        app.moveTab(third.id, to: right, at: 0)
        XCTAssertEqual(right.tabs.map(\.id), [third.id, moving.id])
        var presented: [UUID] = []
        app.presentWindow = { presented.append($0.id) }
        let own = try XCTUnwrap(app.moveTabToNewWindow(moving.id))
        XCTAssertEqual(own.tabs.map(\.id), [moving.id])
        XCTAssertEqual(presented, [own.id])
        XCTAssertEqual(app.windows.count, 3)

        // Closing a window ends its tabs' sessions.
        app.closeWindow(right.id)
        XCTAssertNil(app.session(third.id))
        XCTAssertEqual(app.windows.map(\.id), [left.id, own.id])
    }

    @MainActor func testProductionNeverAutoReconnects() async throws {
        let store = await Self.makeStore(in: directory)
        let dev = try await store.create(ConnectionSettings(name: "dev", reconnectOnLaunch: true))
        let prod = try await store.create(ConnectionSettings(name: "payments-prod", label: .red, reconnectOnLaunch: true))
        let staging = try await store.create(ConnectionSettings(name: "staging", label: .orange, reconnectOnLaunch: true))
        let manual = try await store.create(ConnectionSettings(name: "manual"))
        // A label that opts in to production counts as production too.
        try await store.setTreatAsProduction(.orange, true)
        let document = WindowsDocument(windows: [
            SavedWindow(tabs: [dev, prod, staging, manual].map { SavedTab(profileID: $0.id, database: 0) })
        ])
        let persistence = Persistence<WindowsDocument>(directory: directory)
        _ = await persistence.load()
        _ = try await persistence.save(document, sequence: 1)

        let connector = FakeConnector()
        let app = AppModel(profiles: store, connector: connector, persistence: Persistence(directory: directory))
        await app.restore()
        let tabs = try XCTUnwrap(app.windows.first).tabs
        try await settle(app, tabs[0].id, to: .connected)
        XCTAssertEqual(connector.connects.map(\.profileID), [dev.id], "only the non-production profile with Reconnect on launch")
        for tab in tabs.dropFirst() { XCTAssertEqual(app.session(tab.id)?.status, .disconnected) }
        XCTAssertTrue(ReconnectPolicy.reconnectsOnLaunch(dev, isProduction: false))
        XCTAssertFalse(ReconnectPolicy.reconnectsOnLaunch(prod, isProduction: true))
    }

    @MainActor func testModeShortcuts() async throws {
        XCTAssertEqual(TabMode.allCases.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertEqual(TabMode.allCases.map(\.title), ["Browser", "Console", "Info"])
        let store = await Self.makeStore(in: directory)
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let app = await makeApp(store)
        let window = try XCTUnwrap(app.windows.first)
        // Without a tab there is nothing to switch.
        window.setMode(.console)
        XCTAssertTrue(window.tabs.isEmpty)

        let first = window.open(profileID: profile.id, database: 0)
        let second = window.open(profileID: profile.id, database: 1, newTab: true)
        XCTAssertEqual(window.selected?.mode, .browser, "a new tab opens in Browser")
        // ⌘2 / ⌘3 change only the selected tab, and the mode is saved.
        window.setMode(.console)
        XCTAssertEqual(window.tabs.map(\.mode), [.browser, .console])
        window.selectedID = first.id
        window.setMode(.info)
        XCTAssertEqual(window.tabs.map(\.mode), [.info, .console])
        XCTAssertEqual(app.document.windows.first?.tabs.map(\.mode), [.info, .console])
        // ⇧⌘] / ⇧⌘[ wrap around.
        window.selectTab(offset: 1)
        XCTAssertEqual(window.selectedID, second.id)
        window.selectTab(offset: 1)
        XCTAssertEqual(window.selectedID, first.id)
        window.selectTab(offset: -1)
        XCTAssertEqual(window.selectedID, second.id)
    }

    // MARK: - More

    @MainActor func testClosingATabWithUnsavedEditsAsksFirst() async throws {
        let store = await Self.makeStore(in: directory)
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let connector = FakeConnector()
        let app = await makeApp(store, connector: connector)
        let window = try XCTUnwrap(app.windows.first)
        let tab = window.open(profileID: profile.id, database: 0)
        try await settle(app, tab.id, to: .connected)
        app.session(tab.id)?.hasUnsavedEdits = true

        // AC3: the first close only asks; the tab and its connection stay.
        XCTAssertEqual(app.requestClose(tab.id), .needsConfirmation)
        XCTAssertEqual(window.confirmingCloseTabID, tab.id)
        XCTAssertEqual(window.tabs.map(\.id), [tab.id])
        XCTAssertEqual(app.unsavedTabs(in: window.id).map(\.id), [tab.id])
        XCTAssertEqual(connector.closed, 0)
        // Confirming closes it and ends its session.
        XCTAssertEqual(app.requestClose(tab.id, discardingEdits: true), .closed)
        XCTAssertTrue(window.tabs.isEmpty)
        XCTAssertNil(window.confirmingCloseTabID)
        XCTAssertNil(app.session(tab.id))
        for _ in 0..<200 where connector.closed == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(connector.closed, 1)
    }

    @MainActor func testFailedConnectShowsTheFailureAndDisconnectWhileConnectingClosesTheLateSession() async throws {
        let store = await Self.makeStore(in: directory)
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let connector = FakeConnector()
        connector.fails = ConnectionFailure(category: .connectionRefused, message: "Nothing is listening on 127.0.0.1:6379.", suggestion: "Check the port.")
        let app = await makeApp(store, connector: connector)
        let window = try XCTUnwrap(app.windows.first)
        let tab = window.open(profileID: profile.id, database: 0)
        try await settle(app, tab.id, to: .failed)
        XCTAssertEqual(app.session(tab.id)?.failure?.message, "Nothing is listening on 127.0.0.1:6379.")
        XCTAssertEqual(window.tabs.first?.status, .failed)
        XCTAssertEqual(app.status(ofProfile: profile.id), .failed)

        // A disconnect while connecting wins: the session that lands afterwards is closed, not shown.
        connector.fails = nil
        let session = try XCTUnwrap(app.session(tab.id))
        connector.during = { await session.disconnect() }
        await session.connect(database: 0)
        XCTAssertEqual(session.status, .disconnected)
        XCTAssertNil(session.browser)
        XCTAssertEqual(connector.closed, 1)
    }

    @MainActor func testDeletedProfilesTabsCloseInEveryWindowAndAreNotRestored() async throws {
        let store = await Self.makeStore(in: directory)
        let gone = try await store.create(ConnectionSettings(name: "gone"))
        let kept = try await store.create(ConnectionSettings(name: "kept"))
        let app = await makeApp(store)
        let first = try XCTUnwrap(app.windows.first)
        first.open(profileID: gone.id, database: 0)
        first.open(profileID: kept.id, database: 0)
        let second = app.newWindow()
        second.open(profileID: gone.id, database: 3)
        await app.flush()

        // Gone before the next launch: its tabs aren't restored; the emptied window still is.
        try await store.delete(gone.id)
        let relaunched = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory))
        await relaunched.restore()
        XCTAssertEqual(relaunched.windows.map { $0.tabs.map(\.profileID) }, [[kept.id], []])

        // Deleting while open (the sidebar) closes its tabs in every window.
        first.closeAll(profileID: gone.id)
        XCTAssertEqual(first.tabs.map(\.profileID), [kept.id])
        XCTAssertTrue(second.tabs.isEmpty)
    }

    func testFramesStayOnADisplay() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let saved = NSRect(x: 100, y: 100, width: 1200, height: 760)
        XCTAssertEqual(MainWindow.constrained(saved, to: [screen]), saved)
        // A display that's gone: centered instead.
        XCTAssertNil(MainWindow.constrained(NSRect(x: 3000, y: 100, width: 1200, height: 760), to: [screen]))
        // Larger than the display (its title bar still on it): shrunk and moved inside it.
        let big = MainWindow.constrained(NSRect(x: -50, y: -400, width: 2000, height: 1200), to: [screen])
        XCTAssertEqual(big, NSRect(x: 0, y: 0, width: 1440, height: 875))
    }
}
