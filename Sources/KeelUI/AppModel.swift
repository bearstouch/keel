import Combine
import Foundation
import KeelCore

/// Every window's tabs and every tab's session (FR-AP01, FR-CN15, MAC-05). It restores `windows.json` at launch —
/// tabs disconnected unless their profile reconnects on launch, never production — saves it after each change
/// (debounced by `Persistence`), connects tabs the sidebar opens, moves tabs between windows with their sessions,
/// and asks before closing a tab with unsaved edits. The app delegate turns each window here into an `NSWindow`.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var windows: [ConnectionTabs] = []
    public private(set) var sessions: [UUID: TabSession] = [:]
    /// Window frames as the app last reported them (`setFrame`); saved, never published.
    private var frames: [UUID: SavedFrame] = [:]

    public let profiles: ProfileStore
    private let connector: any SessionConnecting
    /// Nil in previews: nothing is saved.
    private let persistence: Persistence<WindowsDocument>?
    private var sequence: UInt64 = 0
    /// Off until `restore` has read `windows.json`, so an early change never replaces a file that wasn't read, and off
    /// for the session while `connections.json` can't be used (recovery, newer version): its tabs have no profile then,
    /// and saving would drop them from `windows.json` for good.
    private var restored = false
    private var didRestore = false
    /// The window that presents the app-wide sheets: the key window, chosen again only while no sheet is up (the app
    /// delegate sets it), so a sheet stays where it opened.
    @Published public var sheetWindowID: UUID?
    /// Shows a window this model created by itself (a tab moved out to a new window). Set by the app delegate.
    public var presentWindow: ((ConnectionTabs) -> Void)?

    public init(profiles: ProfileStore, connector: any SessionConnecting, persistence: Persistence<WindowsDocument>?) {
        self.profiles = profiles; self.connector = connector; self.persistence = persistence
    }

    // MARK: - Launch

    /// Reads `windows.json` and rebuilds the windows; the saved frame of each is returned for the app to apply. Tabs
    /// of deleted profiles are dropped. With no saved window (first launch, or an unreadable file waiting for
    /// recovery) one empty window opens. Load the profiles first: a tab needs its profile to restore.
    @discardableResult
    public func restore() async -> [(window: ConnectionTabs, frame: SavedFrame?)] {
        guard !didRestore else { return [] }
        didRestore = true
        let document: WindowsDocument
        switch await persistence?.load() {
        case .loaded(let saved)?: document = saved
        // Missing: first launch. Recovery: KEEL-050 offers the choice; until then nothing is saved over the file.
        case .missing?, .recovery?, nil: document = WindowsDocument()
        }
        let catalog = await profiles.document, writable = await profiles.isWritable
        let restorable = document.restorable(profileIDs: Set(catalog.profiles.map(\.id)))
        // A window opened while the file was read (⌘N at launch) stays, after the restored ones.
        let early = windows
        windows = []
        var result: [(window: ConnectionTabs, frame: SavedFrame?)] = []
        for saved in restorable.windows where !early.contains(where: { $0.id == saved.id }) {
            let window = ConnectionTabs(id: saved.id, tabs: saved.tabs.map(ConnectionTab.init(saved:)), selectedID: saved.selectedTabID)
            adopt(window)
            frames[saved.id] = saved.frame
            result.append((window, saved.frame))
        }
        windows += early
        if windows.isEmpty { result.append((newWindow(), nil)) }
        restored = writable
        save()
        // FR-CN15: only profiles with Reconnect on launch, and never one treated as production.
        for window in windows {
            for tab in window.tabs {
                guard let profile = catalog.profiles.first(where: { $0.id == tab.profileID }),
                    ReconnectPolicy.reconnectsOnLaunch(profile, isProduction: catalog.label(profile.settings.label).treatAsProduction)
                else { continue }
                connectIfNeeded(tab.id)
            }
        }
        return result
    }

    // MARK: - Windows

    /// File → New Window (⌘N): an empty window, after the others.
    @discardableResult
    public func newWindow() -> ConnectionTabs {
        let window = ConnectionTabs()
        adopt(window)
        save()
        return window
    }

    /// The window is closing (its close button, ⇧⌘W): its tabs' sessions end. Ask `unsavedTabs(in:)` first.
    public func closeWindow(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: index)
        frames[id] = nil
        for tab in window.tabs { tabClosed(tab.id) }
        save()
    }

    public func window(_ id: UUID) -> ConnectionTabs? { windows.first { $0.id == id } }

    /// The window that shows `tabID` now.
    public func window(containing tabID: UUID) -> ConnectionTabs? { windows.first { $0.tabs.contains { $0.id == tabID } } }

    /// The app reports a window's frame after a move or resize; it is saved with the window.
    public func setFrame(_ frame: SavedFrame, for windowID: UUID) {
        // A late report from a window already closed must not bring its frame back into the file.
        guard frames[windowID] != frame, window(windowID) != nil else { return }
        frames[windowID] = frame
        save()
    }

    private func adopt(_ window: ConnectionTabs) {
        window.app = self
        windows.append(window)
        for tab in window.tabs { session(for: tab) }
    }

    // MARK: - Tabs

    /// Moves a tab to another window at `index` (a drag between tab bars), keeping its session; a move within one
    /// window reorders it. The source window may be left empty, as after dragging out its last tab.
    public func moveTab(_ tabID: UUID, to target: ConnectionTabs, at index: Int? = nil) {
        guard let source = window(containing: tabID) else { return }
        if source === target {
            source.move(tabID, to: index ?? source.tabs.count)
            return
        }
        guard let tab = source.remove(tabID) else { return }
        target.insert(tab, at: index)
    }

    /// A deleted profile's tabs close in every window (FR-CN01).
    public func closeAll(profileID: UUID) {
        for window in windows { for tab in window.tabs where tab.profileID == profileID { window.close(tab.id) } }
    }

    /// "Move to New Window": the tab leaves for a window of its own.
    @discardableResult
    public func moveTabToNewWindow(_ tabID: UUID) -> ConnectionTabs? {
        guard window(containing: tabID) != nil else { return nil }
        let window = newWindow()
        moveTab(tabID, to: window)
        presentWindow?(window)
        return window
    }

    public enum CloseRequest: Equatable { case closed, needsConfirmation }

    /// ⌘W or the tab's ×. A tab with unsaved edits isn't closed until the user confirms (`discardingEdits`) (AC3).
    @discardableResult
    public func requestClose(_ tabID: UUID, discardingEdits: Bool = false) -> CloseRequest {
        guard let window = window(containing: tabID) else { return .closed }
        if !discardingEdits, sessions[tabID]?.hasUnsavedEdits == true {
            // The tab bar asks; its Close Tab comes back here with `discardingEdits`.
            window.confirmingCloseTabID = tabID
            return .needsConfirmation
        }
        window.confirmingCloseTabID = nil
        window.close(tabID)
        return .closed
    }

    /// Tabs of a window with unsaved edits, for its close confirmation (MAC-06 asks once per window).
    public func unsavedTabs(in windowID: UUID) -> [ConnectionTab] {
        window(windowID)?.tabs.filter { sessions[$0.id]?.hasUnsavedEdits == true } ?? []
    }

    public func session(_ tabID: UUID) -> TabSession? { sessions[tabID] }

    /// Connects the tab unless it is connected or connecting (opening from the sidebar, Reconnect on launch).
    public func connectIfNeeded(_ tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        let session = session(for: tab)
        guard session.status == .disconnected || session.status == .failed else { return }
        Task { await session.connect(database: tab.database) }
    }

    /// ⇧⌘R: a fresh session for the tab, on its current database.
    public func reconnect(_ tabID: UUID) async {
        guard let tab = tab(tabID), let session = sessions[tabID] else { return }
        await session.reconnect(database: tab.database)
    }

    /// ⇧⌘D for one tab.
    public func disconnect(_ tabID: UUID) async { await sessions[tabID]?.disconnect() }

    /// Disconnect for a profile (sidebar): every tab of it, in every window.
    public func disconnect(profileID: UUID) async {
        for session in sessions.values where session.profileID == profileID { await session.disconnect() }
    }

    private func tab(_ id: UUID) -> ConnectionTab? { window(containing: id)?.tabs.first { $0.id == id } }

    @discardableResult
    private func session(for tab: ConnectionTab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TabSession(id: tab.id, profileID: tab.profileID, connector: connector)
        let id = tab.id
        // Whichever window holds the tab now shows its status and saves its database.
        session.onStatus = { [weak self] status in self?.window(containing: id)?.setStatus(status, for: id) }
        session.onDatabase = { [weak self] database in self?.window(containing: id)?.setDatabase(database, for: id) }
        sessions[tab.id] = session
        return session
    }

    /// A tab left every window: its session ends.
    func tabClosed(_ tabID: UUID) {
        // Still in a window means it was moved, not closed: the session stays.
        guard window(containing: tabID) == nil, let session = sessions.removeValue(forKey: tabID) else { return }
        Task { await session.disconnect() }
    }

    // MARK: - Status and saving

    /// A profile's status across every window: connected if any tab is, then connecting, then failed (FR-CN13).
    public func status(ofProfile profileID: UUID) -> ConnectionStatus {
        ConnectionTabs.combined(sessions.values.lazy.filter { $0.profileID == profileID }.map(\.status))
    }

    /// Sidebars in every window show profile statuses across windows, so all of them redraw.
    func statusChanged() { for window in windows { window.objectWillChange.send() } }

    func windowChanged(_ window: ConnectionTabs) { save() }

    /// What `windows.json` holds now.
    public var document: WindowsDocument { WindowsDocument(windows: windows.map { $0.saved(frame: frames[$0.id]) }) }

    private func save() {
        guard restored, let persistence else { return }
        sequence += 1
        let document = document, sequence = sequence
        Task { await persistence.scheduleSave(document, sequence: sequence) }
    }

    /// On quit: the latest windows are written now rather than after the debounce.
    public func flush() async {
        guard restored, let persistence else { return }
        sequence += 1
        await persistence.scheduleSave(document, sequence: sequence)
        try? await persistence.flush()
    }
}
