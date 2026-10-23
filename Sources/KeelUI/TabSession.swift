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
    /// Value edits not yet saved (KEEL-027's editors set it); closing the tab or its window asks first (MAC-06).
    @Published public var hasUnsavedEdits = false

    private let connector: any SessionConnecting
    private var connected: ConnectedServer?
    /// Bumped by every connect and disconnect, so a connect that lands after a newer one (or a disconnect) is closed.
    private var attempt = 0
    private var databaseChanges: AnyCancellable?
    /// Status and database changes, for the window that holds the tab.
    var onStatus: ((ConnectionStatus) -> Void)?
    var onDatabase: ((Int) -> Void)?

    init(id: UUID, profileID: UUID, connector: any SessionConnecting) { self.id = id; self.profileID = profileID; self.connector = connector }

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
            failure = error; set(.failed)
        case .success(let server):
            connected = server; self.server = server.identity
            let browser = Self.browser(for: server, database: database)
            self.browser = browser
            // The tab saves the database the switcher moves to (FR-AP01 restores it).
            databaseChanges = browser.$database.dropFirst().sink { [weak self] in self?.onDatabase?($0) }
            set(.connected)
            await browser.start()
        }
    }

    /// Disconnect (⇧⌘D): closes every connection of the tab and its tunnel lease. The browser goes with it.
    public func disconnect() async {
        attempt += 1
        let server = connected
        connected = nil; browser = nil; self.server = nil; databaseChanges = nil; failure = nil
        set(.disconnected)
        await server?.close()
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
            list: list, filter: KeyFilterModel(list: list), database: database, serverMode: server.identity.mode, databaseCount: server.databaseCount)
    }
}
