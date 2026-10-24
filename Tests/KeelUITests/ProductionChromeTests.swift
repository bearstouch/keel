import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Connects every tab to one scripted in-memory server and remembers the data path it built, so a test can write
/// through the tab's own service.
final class ScriptedConnector: SessionConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [DataCommandService] = []
    private let answer: @Sendable ([String]) -> String
    let safety: SafetyProfile

    init(safety: SafetyProfile, answer: @escaping @Sendable ([String]) -> String = ScriptedConnector.defaultAnswer) { self.safety = safety; self.answer = answer }

    /// An empty database: `SCAN` finds nothing, writes answer `+OK`.
    static let defaultAnswer: @Sendable ([String]) -> String = { $0[0] == "SCAN" ? "*2\r\n$1\r\n0\r\n*0\r\n" : $0[0] == "DBSIZE" ? ":0\r\n" : "+OK\r\n" }

    var lastService: DataCommandService? { lock.withLock { services.last } }

    func connect(profileID: UUID, database: Int) async -> Result<ConnectedServer, ConnectionFailure> {
        let answer = answer
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: ScriptedTransport(answer: answer))
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            return connection
        }
        let service = DataCommandService(session: session)
        lock.withLock { services.append(service) }
        let identity = ServerIdentity(kind: .redis, version: ServerVersion("7.4.0"), redisCompatibleVersion: ServerVersion("7.4.0"), mode: .standalone, role: "master")
        return .success(ConnectedServer(session: session, service: service, identity: identity, databaseCount: 16, safety: safety, close: { await session.closeAll() }))
    }
}

/// Answers every command frame in a chunk (pipelines included) with `answer`.
final class ScriptedTransport: KeelRESP.Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var parser = RESPParser()
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    private var cancelled = false
    private let answer: @Sendable ([String]) -> String

    init(answer: @escaping @Sendable ([String]) -> String) { self.answer = answer }

    func connect() async throws(TransportError) {}

    func send(_ data: Data) {
        let ready: (CheckedContinuation<Result<Data, TransportError>, Never>, Data)? = lock.withLock {
            parser.append(data)
            var reply = Data()
            while case .array(let items)? = try? parser.next() {
                reply += Data(answer(items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }).utf8)
            }
            if let receiver { self.receiver = nil; return (receiver, reply) }
            pending.append(reply)
            return nil
        }
        if let (receiver, reply) = ready { receiver.resume(returning: .success(reply)) }
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let ready: Result<Data, TransportError>? = lock.withLock {
                if !pending.isEmpty { return .success(pending.removeFirst()) }
                if cancelled { return .failure(.cancelled) }
                receiver = waiter
                return nil
            }
            if let ready { waiter.resume(returning: ready) }
        }
        return try result.get()
    }

    func cancel() {
        let waiter = lock.withLock {
            defer { cancelled = true; receiver = nil }
            return receiver
        }
        waiter?.resume(returning: .failure(.cancelled))
    }
}

final class ProductionChromeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-production-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    @MainActor private func makeApp(_ store: ProfileStore, connector: any SessionConnecting) async -> AppModel {
        let app = AppModel(profiles: store, connector: connector, persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        return app
    }

    /// Polls a main-actor condition that tasks the models start will make true.
    @MainActor private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }

    private static let write = DataOperation.stringSet(key: Data("a".utf8), value: Data("1".utf8), keepTTL: false)
    private static let writable = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: false, production: true))

    // MARK: - Story tests

    /// AC1: the strip shows over a production tab only, and goes when a non-production tab is selected.
    @MainActor func testStripVisibilityFollowsTab() async throws {
        let store = await Self.makeStore(in: directory)
        let payments = try await store.create(ConnectionSettings(name: "payments-prod", label: .red, readOnly: true))
        let orders = try await store.create(ConnectionSettings(name: "orders-prod", label: .red))
        let staging = try await store.create(ConnectionSettings(name: "api-staging", label: .orange))
        let local = try await store.create(ConnectionSettings(name: "local-dev", label: .green, readOnly: true))
        let tabs = ConnectionTabs()
        let sidebar = SidebarModel(store: store, tabs: tabs, copy: { _ in })
        await sidebar.reload()
        XCTAssertNil(sidebar.productionStrip, "a window without tabs has no strip")

        let paymentsTab = tabs.open(profileID: payments.id, database: 0)
        XCTAssertEqual(sidebar.productionStrip, "Production · Read-only")
        tabs.open(profileID: local.id, database: 0)
        XCTAssertNil(sidebar.productionStrip, "read-only alone is not production")
        tabs.open(profileID: orders.id, database: 0)
        XCTAssertEqual(sidebar.productionStrip, "Production", "writes allowed: the strip says Production alone")
        let stagingTab = tabs.open(profileID: staging.id, database: 0)
        XCTAssertNil(sidebar.productionStrip)
        tabs.selectedID = paymentsTab.id
        XCTAssertEqual(sidebar.productionStrip, "Production · Read-only")

        // Any label can be treated as production.
        try await store.setTreatAsProduction(.orange, true)
        await sidebar.reload()
        tabs.selectedID = stagingTab.id
        XCTAssertEqual(sidebar.productionStrip, "Production")
        XCTAssertTrue(sidebar.isProduction(staging.id))
        XCTAssertFalse(sidebar.isProduction(local.id))
    }

    /// AC2: turning read-only off on a Production profile asks first; No keeps it on, Yes saves it writable.
    @MainActor func testDisablingReadOnlyAsks() async throws {
        let store = await Self.makeStore(in: directory)
        let payments = try await store.create(ConnectionSettings(name: "payments-prod", label: .red, readOnly: true))
        let edit = ConnectionSheetModel(mode: .edit(payments), tester: FakeConnectionTester(), store: store)
        edit.setReadOnly(false)
        XCTAssertTrue(edit.readOnly, "the switch stays on until the user agrees")
        XCTAssertTrue(edit.confirmingWritableProduction)
        XCTAssertEqual(edit.writableProductionTitle, "Allow writes to “payments-prod”?")
        edit.cancelWritableProduction()
        XCTAssertTrue(edit.readOnly)
        XCTAssertFalse(edit.confirmingWritableProduction)

        edit.setReadOnly(false)
        XCTAssertFalse(edit.confirmWritableProduction(), "no save was waiting")
        XCTAssertFalse(edit.readOnly)
        let saved = await edit.save()
        XCTAssertEqual(saved?.settings.readOnly, false)
        let stored = await store.profile(payments.id)
        XCTAssertEqual(stored?.settings.readOnly, false)

        // Not production: no question.
        let local = try await store.create(ConnectionSettings(name: "local-dev", label: .green, readOnly: true))
        let plain = ConnectionSheetModel(mode: .edit(local), tester: FakeConnectionTester(), store: store)
        plain.setReadOnly(false)
        XCTAssertFalse(plain.readOnly)
        XCTAssertFalse(plain.confirmingWritableProduction)

        // A writable profile given the Production label asks on Save, and nothing is saved until Yes.
        let cache = try await store.create(ConnectionSettings(name: "cache"))
        let relabel = ConnectionSheetModel(mode: .edit(cache), tester: FakeConnectionTester(), store: store)
        relabel.label = .red
        let refused = await relabel.save()
        XCTAssertNil(refused)
        XCTAssertTrue(relabel.confirmingWritableProduction)
        let unchanged = await store.profile(cache.id)
        XCTAssertEqual(unchanged?.settings.label, LabelColor.none, "nothing saved while the question is up")
        XCTAssertTrue(relabel.confirmWritableProduction(), "the waiting Save runs after Yes")
        let relabeled = await relabel.save()
        XCTAssertEqual(relabeled?.settings.label, .red)
        XCTAssertEqual(relabeled?.settings.readOnly, false)

        // An already writable production profile saves other edits without asking.
        let rename = ConnectionSheetModel(mode: .edit(try XCTUnwrap(relabeled)), tester: FakeConnectionTester(), store: store)
        rename.name = "cache-prod"
        let renamed = await rename.save()
        XCTAssertEqual(renamed?.settings.name, "cache-prod")
        XCTAssertFalse(rename.confirmingWritableProduction)
    }

    /// The window title (and so the Window menu) names the selected tab and marks production "[PROD]".
    @MainActor func testWindowTitleMarksProd() async throws {
        let store = await Self.makeStore(in: directory)
        let payments = try await store.create(ConnectionSettings(name: "payments-prod", label: .red, readOnly: true))
        let local = try await store.create(ConnectionSettings(name: "local-dev", label: .green))
        let tabs = ConnectionTabs()
        let sidebar = SidebarModel(store: store, tabs: tabs, copy: { _ in })
        await sidebar.reload()
        XCTAssertEqual(sidebar.windowTitle, "Keel")
        let paymentsTab = tabs.open(profileID: payments.id, database: 0)
        XCTAssertEqual(sidebar.windowTitle, "payments-prod [PROD]")
        tabs.open(profileID: local.id, database: 0)
        XCTAssertEqual(sidebar.windowTitle, "local-dev")
        tabs.selectedID = paymentsTab.id
        XCTAssertEqual(sidebar.windowTitle, "payments-prod [PROD]")
        tabs.close(paymentsTab.id)
        XCTAssertEqual(sidebar.windowTitle, "local-dev")
    }

    /// DS-03 / FR-SF02: strip text ≥ 4.5:1 in both themes; in light the strip stands ≥ 3:1 off the tab bar and content.
    /// In dark the maroon sits on dark graphite by design, so its text carries it. Never the accent's lightness.
    @MainActor func testStripContrast() {
        let strip = Tokens.Hex.prodStrip, text = Tokens.Hex.onProdStrip
        XCTAssertGreaterThanOrEqual(Tokens.contrast(text.light, strip.light), 4.5)
        XCTAssertGreaterThanOrEqual(Tokens.contrast(text.dark, strip.dark), 4.5)
        XCTAssertGreaterThanOrEqual(Tokens.contrast(strip.light, Tokens.Hex.tabBar.light), 3)
        XCTAssertGreaterThanOrEqual(Tokens.contrast(strip.light, Tokens.Hex.bg.light), 3)
        XCTAssertGreaterThanOrEqual(Tokens.contrast(strip.light, Tokens.Hex.accent.light), 1.5, "maroon is darker than the accent")
        XCTAssertGreaterThanOrEqual(Tokens.contrast(strip.dark, Tokens.Hex.accent.dark), 3)
        XCTAssertEqual(Tokens.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ProductionChrome.stripHeight, 28)
    }

    // MARK: - Writes on production

    /// FR-SF07: the first write in a writable production tab shows the notice; once dismissed it stays away for the tab,
    /// across a reconnect.
    @MainActor func testWritingToProductionNoticeShowsOncePerTab() async throws {
        let store = await Self.makeStore(in: directory)
        let orders = try await store.create(ConnectionSettings(name: "orders-prod", label: .red))
        let connector = ScriptedConnector(safety: SafetyProfile(name: "orders-prod", readOnly: false, production: true))
        let app = await makeApp(store, connector: connector)
        let window = try XCTUnwrap(app.windows.first)
        let tab = window.open(profileID: orders.id, database: 0)
        try await eventually("connected") { app.session(tab.id)?.status == .connected }
        let session = try XCTUnwrap(app.session(tab.id))
        XCTAssertFalse(session.showsProductionWriteNotice, "connecting writes nothing")

        _ = try await connector.lastService?.execute(.operation(.get(key: Data("a".utf8))), origin: .editor, context: Self.writable)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(session.showsProductionWriteNotice, "a read is not a write")
        _ = try await connector.lastService?.execute(.operation(Self.write), origin: .editor, context: Self.writable)
        try await eventually("the first write shows the notice") { session.showsProductionWriteNotice }
        session.dismissProductionWriteNotice()
        _ = try await connector.lastService?.execute(.operation(Self.write), origin: .editor, context: Self.writable)
        await app.reconnect(tab.id)
        _ = try await connector.lastService?.execute(.operation(Self.write), origin: .editor, context: Self.writable)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(session.showsProductionWriteNotice, "once per tab")
    }

    @MainActor func testNoNoticeOutsideWritableProduction() async throws {
        let store = await Self.makeStore(in: directory)
        let local = try await store.create(ConnectionSettings(name: "local-dev"))
        let connector = ScriptedConnector(safety: SafetyProfile(name: "local-dev", readOnly: false))
        let app = await makeApp(store, connector: connector)
        let tab = try XCTUnwrap(app.windows.first).open(profileID: local.id, database: 0)
        try await eventually("connected") { app.session(tab.id)?.status == .connected }
        _ = try await connector.lastService?.execute(.operation(Self.write), origin: .editor, context: DataContext(profile: SafetyProfile(name: "local-dev", readOnly: false)))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(app.session(tab.id)?.showsProductionWriteNotice, false)
    }

    // MARK: - Read-only while connected

    /// Turning read-only on while a tab is connected locks its session at once: the strip says so and nothing more is
    /// written. Turning it off again waits for a reconnect.
    @MainActor func testTurningReadOnlyOnLocksOpenTabs() async throws {
        let store = await Self.makeStore(in: directory)
        let orders = try await store.create(ConnectionSettings(name: "orders-prod", label: .red))
        let connector = ScriptedConnector(safety: SafetyProfile(name: "orders-prod", readOnly: false, production: true))
        let app = await makeApp(store, connector: connector)
        let window = try XCTUnwrap(app.windows.first)
        let sidebar = SidebarModel(store: store, tabs: window, copy: { _ in })
        await sidebar.reload()
        let tab = window.open(profileID: orders.id, database: 0)
        try await eventually("connected") { app.session(tab.id)?.status == .connected }
        XCTAssertEqual(sidebar.productionStrip, "Production")

        var settings = orders.settings
        settings.readOnly = true
        _ = try await store.update(orders.id, settings, password: .keep, expectedRevision: orders.revision)
        await sidebar.reload()
        try await eventually("the session locks") { app.session(tab.id)?.writesBlocked == true }
        XCTAssertEqual(sidebar.productionStrip, "Production · Read-only")
        let service = try XCTUnwrap(connector.lastService)
        for _ in 0..<200 { if await service.isReadOnlyLocked { break }; try await Task.sleep(for: .milliseconds(5)) }
        do {
            _ = try await service.execute(.operation(Self.write), origin: .editor, context: Self.writable)
            XCTFail("a write ran after read-only was turned on")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
    }

    /// The server refusing a write (ACL `NOPERM`, a read-only replica) shows "server-enforced read-only".
    @MainActor func testServerRefusalShowsServerEnforcedReadOnly() async throws {
        let store = await Self.makeStore(in: directory)
        let orders = try await store.create(ConnectionSettings(name: "orders-prod", label: .red))
        let connector = ScriptedConnector(safety: SafetyProfile(name: "orders-prod", readOnly: false, production: true)) { arguments in
            arguments[0] == "SET" ? "-NOPERM User reader has no permissions to run the 'set' command\r\n" : ScriptedConnector.defaultAnswer(arguments)
        }
        let app = await makeApp(store, connector: connector)
        let window = try XCTUnwrap(app.windows.first)
        let sidebar = SidebarModel(store: store, tabs: window, copy: { _ in })
        await sidebar.reload()
        let tab = window.open(profileID: orders.id, database: 0)
        try await eventually("connected") { app.session(tab.id)?.status == .connected }
        _ = try await connector.lastService?.execute(.operation(Self.write), origin: .editor, context: Self.writable)
        try await eventually("server read-only") { app.session(tab.id)?.serverReadOnly == true }
        XCTAssertEqual(sidebar.productionStrip, "Production · Read-only")
        await app.disconnect(tab.id)
        XCTAssertEqual(app.session(tab.id)?.serverReadOnly, false, "a new session asks the server again")
    }
}
