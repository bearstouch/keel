import Combine
import Foundation
import KeelCore

/// A connection's state as the sidebar and tab bar show it: a link icon when connected, the word "Failed" when the
/// last attempt failed (FR-CN13).
public enum ConnectionStatus: String, Sendable, Equatable {
    case disconnected, connecting, connected, failed

    /// What VoiceOver reads after the name and label (DS-04: status has words).
    public var spoken: String {
        switch self {
        case .disconnected: "not connected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        }
    }
}

/// One open connection: a profile on a database, in a mode. Its live session is the app's `TabSession` with the
/// same ID, so a tab keeps its connection when it moves to another window.
public struct ConnectionTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public var database: Int
    public var mode: TabMode
    public var status: ConnectionStatus

    public init(id: UUID = UUID(), profileID: UUID, database: Int, mode: TabMode = .browser, status: ConnectionStatus = .disconnected) {
        self.id = id; self.profileID = profileID; self.database = database; self.mode = mode; self.status = status
    }

    /// A restored tab starts disconnected: statuses aren't saved.
    public init(saved: SavedTab) { self.init(id: saved.id, profileID: saved.profileID, database: saved.database, mode: saved.mode) }

    public var saved: SavedTab { SavedTab(id: id, profileID: profileID, database: database, mode: mode) }
}

/// One window's tabs (FR-AP01): the tab bar's order and selection. The sidebar opens and focuses tabs here. In the app
/// an `AppModel` owns every window's tabs: it connects tabs, keeps sessions across moves, answers statuses across
/// windows and saves `windows.json` after each change; without one (previews, tests) the tabs are only a list.
@MainActor
public final class ConnectionTabs: ObservableObject, Identifiable {
    public let id: UUID
    @Published public private(set) var tabs: [ConnectionTab] = []
    @Published public var selectedID: ConnectionTab.ID? { didSet { if selectedID != oldValue { app?.windowChanged(self) } } }
    /// ⌘T: the tab bar shows its connection picker.
    @Published public var showsConnectionPicker = false
    /// A tab whose close is waiting for the user to confirm discarding its unsaved edits (AC3).
    @Published public var confirmingCloseTabID: ConnectionTab.ID?
    weak var app: AppModel?

    public init(id: UUID = UUID(), tabs: [ConnectionTab] = [], selectedID: ConnectionTab.ID? = nil) {
        self.id = id; self.tabs = tabs; self.selectedID = selectedID
    }

    public var selected: ConnectionTab? { tabs.first { $0.id == selectedID } }

    /// Focuses the tab already showing `profileID` on `database`, or opens a new one; `newTab` (⌥) always opens a new
    /// one. Opening is asking to connect: the app connects the tab unless it is connected or connecting. Returns the
    /// focused tab.
    @discardableResult
    public func open(profileID: UUID, database: Int, newTab: Bool = false) -> ConnectionTab {
        let tab: ConnectionTab
        if !newTab, let existing = tabs.first(where: { $0.profileID == profileID && $0.database == database }) {
            tab = existing
        } else {
            tab = ConnectionTab(profileID: profileID, database: database)
            tabs.append(tab)
        }
        selectedID = tab.id
        app?.recordOpened(profileID)
        app?.windowChanged(self)
        app?.connectIfNeeded(tab.id)
        return tab
    }

    /// Closes the tab and ends its session; the selection moves to its neighbor, as in a native tab bar. Unsaved edits
    /// are asked about before this (`AppModel.requestClose`).
    public func close(_ id: ConnectionTab.ID) {
        guard remove(id) != nil else { return }
        app?.tabClosed(id)
    }

    /// Closes every tab of a deleted profile, in every window when the app owns the tabs.
    public func closeAll(profileID: UUID) {
        if let app { app.closeAll(profileID: profileID); return }
        for tab in tabs where tab.profileID == profileID { close(tab.id) }
    }

    /// Takes the tab out of this window without ending its session (a move to another window).
    @discardableResult
    func remove(_ id: ConnectionTab.ID) -> ConnectionTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        app?.windowChanged(self)
        return tab
    }

    /// Puts a tab (moved from another window) at `index` and selects it.
    func insert(_ tab: ConnectionTab, at index: Int? = nil) {
        tabs.insert(tab, at: min(max(index ?? tabs.count, 0), tabs.count))
        selectedID = tab.id
        app?.windowChanged(self)
    }

    /// Reorders a tab within this window (a drag inside the tab bar).
    func move(_ id: ConnectionTab.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        // Dropping after itself means one place further left once it is out of the list.
        tabs.insert(tab, at: min(max(from < index ? index - 1 : index, 0), tabs.count))
        app?.windowChanged(self)
    }

    public func setStatus(_ status: ConnectionStatus, for id: ConnectionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].status != status else { return }
        tabs[index].status = status
        // Statuses aren't saved: a restored tab always starts disconnected.
        app?.statusChanged()
    }

    func setDatabase(_ database: Int, for id: ConnectionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].database != database else { return }
        tabs[index].database = database
        app?.windowChanged(self)
    }

    /// ⌘1 / ⌘2 / ⌘3: the selected tab's mode. Nothing happens without a tab.
    public func setMode(_ mode: TabMode) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }), tabs[index].mode != mode else { return }
        tabs[index].mode = mode
        app?.windowChanged(self)
    }

    /// ⇧⌘] / ⇧⌘[: the next or previous tab, wrapping around.
    public func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedID } ?? 0
        selectedID = tabs[((current + offset) % tabs.count + tabs.count) % tabs.count].id
    }

    /// The profile's status across every window's tabs: connected if any tab is, then connecting, then failed.
    public func status(ofProfile profileID: UUID) -> ConnectionStatus {
        if let app { return app.status(ofProfile: profileID) }
        return Self.combined(tabs.lazy.filter { $0.profileID == profileID }.map(\.status))
    }

    static func combined(_ statuses: some Sequence<ConnectionStatus>) -> ConnectionStatus {
        let statuses = Set(statuses)
        for status in [ConnectionStatus.connected, .connecting, .failed] where statuses.contains(status) { return status }
        return .disconnected
    }

    func saved(frame: SavedFrame?) -> SavedWindow { SavedWindow(id: id, frame: frame, tabs: tabs.map(\.saved), selectedTabID: selectedID) }
}
