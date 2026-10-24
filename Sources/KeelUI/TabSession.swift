import Combine
import Foundation
import KeelCore

/// One tab's live connection (FR-CN15): connecting, the connected server and the browser over it. It belongs to the
/// tab, not the window, so moving a tab between windows keeps it connected.
@MainActor
public final class TabSession: ObservableObject, Identifiable {
    public let id: UUID
    public let profileID: UUID
    @Published public private(set) var status = ConnectionStatus.disconnected
    /// Why the last connect failed; shown in the tab with Connect.
    @Published public private(set) var failure: ConnectionFailure?
    @Published public private(set) var server: ServerIdentity?
    /// The key browser, once connected.
    @Published public private(set) var browser: BrowserModel?
    /// The console, made the first time the tab shows Console mode on this connection (`openConsole()`).
    @Published public private(set) var console: ConsoleModel?
    /// Info mode, made the first time the tab shows it on this connection (`openInfo()`).
    @Published public private(set) var info: InfoModel?
    /// Value edits not yet saved (KEEL-027's editors set it); closing the tab or its window asks first (MAC-06).
    @Published public var hasUnsavedEdits = false
    /// Whether the connected session refuses writes (FR-SF01): the profile was read-only when it connected, or was made
    /// read-only since. Nil while not connected, when the profile's own flag is what the tab shows.
    @Published public private(set) var writesBlocked: Bool?
    /// The server refused a write because this user or server can't write; until the session ends.
    @Published public private(set) var serverReadOnly = false
    /// FR-SF07: the "Writing to PRODUCTION" banner, shown once per tab (reconnects included) until dismissed.
    @Published public private(set) var showsProductionWriteNotice = false
    /// Whether the profile is treated as production now; set at connect and by every profile change (`applyProfile`).
    public private(set) var isProduction = false
    private var productionNoticeShown = false

    private let connector: any SessionConnecting
    private let histories: ConsoleHistoryBook
    private var connected: ConnectedServer?
    /// Bumped by every connect and disconnect, so a connect that lands after a newer one (or a disconnect) is closed.
    private var attempt = 0
    private var databaseChanges: AnyCancellable?
    private var editChanges: AnyCancellable?
    /// Status and database changes, for the window that holds the tab.
    var onStatus: ((ConnectionStatus) -> Void)?
    var onDatabase: ((Int) -> Void)?
    /// What the production strip and window title show changed (read-only locked, server read-only).
    var onChromeChange: (() -> Void)?
    /// A key the browser opened, with its database (the palette's recent keys).
    var onKeyOpened: ((Data, Int) -> Void)?
    /// A recent key picked in the palette before the browser existed; revealed once the first page is loaded.
    private var pendingReveal: Data?

    init(id: UUID, profileID: UUID, connector: any SessionConnecting, histories: ConsoleHistoryBook = ConsoleHistoryBook()) {
        self.id = id; self.profileID = profileID; self.connector = connector; self.histories = histories
    }

    /// Connects on `database` (Connect, Reconnect, opening from the sidebar, Reconnect on launch). Does nothing while
    /// connecting or connected; Reconnect disconnects first.
    public func connect(database: Int) async {
        guard status != .connecting, status != .connected else { return }
        attempt += 1
        let mine = attempt
        set(.connecting); failure = nil
        let result = await connector.connect(profileID: profileID, database: database)
        guard mine == attempt else {
            // Disconnected (or closed) while connecting: the late connection must not stay open behind the tab.
            if case .success(let server) = result { await server.close() }
            return
        }
        switch result {
        case .failure(let error):
            failure = error; pendingReveal = nil; set(.failed)
        case .success(let server):
            await server.service.observeWrites { [weak self] event in Task { @MainActor in self?.written(event, attempt: mine) } }
            guard mine == attempt else { await server.close(); return }
            connected = server; self.server = server.identity
            isProduction = server.safety.production; writesBlocked = server.safety.readOnly; serverReadOnly = false
            let browser = Self.browser(for: server, database: database)
            browser.onKeyOpened = { [weak self] key, database in self?.onKeyOpened?(key, database) }
            self.browser = browser
            // The tab saves the database the switcher moves to (FR-AP01 restores it).
            databaseChanges = browser.$database.dropFirst().sink { [weak self] in self?.onDatabase?($0) }
            // The open editor's draft is the tab's unsaved edits: closing asks first (MAC-06).
            editChanges = browser.$editor
                .map { editor in editor.map { $0.$changedRows.map { !$0.isEmpty }.eraseToAnyPublisher() } ?? Just(false).eraseToAnyPublisher() }
                .switchToLatest().removeDuplicates()
                .sink { [weak self] in self?.hasUnsavedEdits = $0 }
            set(.connected)
            await browser.start()
            // Only this attempt reveals: a reconnect or disconnect during the first load superseded it.
            if mine == attempt, let key = pendingReveal { pendingReveal = nil; await browser.reveal(key) }
        }
    }

    /// Opens `key` in the browser (a recent key from the palette); the tab is already on `database`, or moves there.
    /// While still connecting, the key waits for the browser.
    public func reveal(_ key: Data, database: Int) async {
        guard let browser, status == .connected else { pendingReveal = key; return }
        if browser.database != database { await browser.selectDatabase(database) }
        await browser.reveal(key)
    }

    /// Disconnect (⇧⌘D): closes every connection of the tab and its tunnel lease. The browser goes with it.
    public func disconnect() async {
        attempt += 1
        let server = connected, console = console
        info?.shutdown()
        connected = nil; browser = nil; pendingReveal = nil; self.console = nil; info = nil; self.server = nil; databaseChanges = nil; editChanges = nil; hasUnsavedEdits = false; failure = nil
        writesBlocked = nil; serverReadOnly = false
        set(.disconnected)
        await server?.service.observeWrites(nil)
        await console?.shutdown()
        await server?.close()
    }

    /// The profile was saved (or its label changed): production follows at once; read-only turned on locks the open
    /// session so nothing more is written. Turning read-only off takes effect on the next connect, never mid-session.
    func applyProfile(readOnly: Bool, production: Bool) async {
        isProduction = production
        guard readOnly, writesBlocked == false, let connected else { return }
        writesBlocked = true; onChromeChange?()
        await connected.service.lockReadOnly()
    }

    /// The tab's console on this connection (FR-CO01): its own connection, starting on the browser's database. Made once;
    /// it keeps its own database (`SELECT`) from then on.
    public func openConsole() {
        guard console == nil, let connected, status == .connected else { return }
        let database = browser?.database ?? 0
        let session = ConsoleSession(service: connected.service, profile: connected.safety, database: database)
        console = ConsoleModel(console: session, profileID: profileID, histories: histories, prompt: ConsoleSession.prompt(address: session.address, database: database))
    }

    /// The tab's Info mode (FR-SI01): `INFO` through the data path on the browser's connection and database. Browse on a
    /// database row moves the browser there; the window switches the mode.
    public func openInfo(browse: @escaping (Int) -> Void) {
        guard info == nil, let connected, status == .connected else { return }
        let model = InfoModel(service: connected.service, context: DataContext(profile: connected.safety, database: browser?.database ?? 0))
        model.onBrowse = { [weak self] database in
            browse(database)
            guard let browser = self?.browser else { return }
            Task { await browser.selectDatabase(database) }
        }
        info = model
    }

    /// Hides the "Writing to PRODUCTION" banner; it doesn't come back for this tab.
    public func dismissProductionWriteNotice() { showsProductionWriteNotice = false }

    /// A write event from the data path of connect `attempt`; one from an older session is ignored.
    private func written(_ event: WriteEvent, attempt: Int) {
        guard attempt == self.attempt else { return }
        switch event {
        case .sent:
            // FR-SF07: only on writable production profiles, and only the first time in this tab.
            guard isProduction, writesBlocked == false, !productionNoticeShown else { return }
            productionNoticeShown = true; showsProductionWriteNotice = true
        case .serverRefused:
            guard !serverReadOnly else { return }
            serverReadOnly = true; onChromeChange?()
        }
    }

    /// Reconnect (⇧⌘R): a fresh session on the tab's database.
    public func reconnect(database: Int) async {
        await disconnect()
        await connect(database: database)
    }

    private func set(_ status: ConnectionStatus) {
        self.status = status
        onStatus?(status)
    }

    /// The browser over a new session: index, row metadata, list, filters and the database switcher.
    static func browser(for server: ConnectedServer, database: Int) -> BrowserModel {
        let index = KeyIndex(service: server.service, context: DataContext(profile: server.safety, database: database), separator: server.separator)
        let list = KeyListDataSource(index: index, metadataLoader: RowMetadataLoader(index: index))
        return BrowserModel(
            list: list, filter: KeyFilterModel(list: list), database: database, serverMode: server.identity.mode, databaseCount: server.databaseCount,
            editorBinding: { EditorBinding.editor(for: $0) })
    }
}
