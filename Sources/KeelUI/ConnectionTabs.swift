import Combine
import Foundation

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

/// One open connection: a profile on a database. KEEL-026 adds the mode and selected key path.
public struct ConnectionTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public var database: Int
    public var status: ConnectionStatus

    public init(id: UUID = UUID(), profileID: UUID, database: Int, status: ConnectionStatus = .disconnected) {
        self.id = id; self.profileID = profileID; self.database = database; self.status = status
    }
}

/// The window's open connection tabs (FR-AP01). The sidebar opens and focuses tabs here; the tab bar, persistence in
/// `windows.json` and moving tabs between windows arrive with KEEL-026, and the session that sets `status` with the
/// browser. Nothing here touches the network.
@MainActor
public final class ConnectionTabs: ObservableObject {
    @Published public private(set) var tabs: [ConnectionTab] = []
    @Published public var selectedID: ConnectionTab.ID?

    public init() {}

    public var selected: ConnectionTab? { tabs.first { $0.id == selectedID } }

    /// Focuses the tab already showing `profileID` on `database`, or opens a new one; `newTab` (⌥) always opens a new
    /// one. Returns the focused tab.
    @discardableResult
    public func open(profileID: UUID, database: Int, newTab: Bool = false) -> ConnectionTab {
        if !newTab, let existing = tabs.first(where: { $0.profileID == profileID && $0.database == database }) {
            selectedID = existing.id
            return existing
        }
        let tab = ConnectionTab(profileID: profileID, database: database)
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    /// Closes the tab; the selection moves to its neighbor, as in a native tab bar.
    public func close(_ id: ConnectionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    /// Closes every tab of a deleted profile.
    public func closeAll(profileID: UUID) {
        for tab in tabs where tab.profileID == profileID { close(tab.id) }
    }

    public func setStatus(_ status: ConnectionStatus, for id: ConnectionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].status = status
    }

    /// The profile's status across its tabs: connected if any tab is, then connecting, then failed.
    public func status(ofProfile profileID: UUID) -> ConnectionStatus {
        let statuses = Set(tabs.lazy.filter { $0.profileID == profileID }.map(\.status))
        for status in [ConnectionStatus.connected, .connecting, .failed] where statuses.contains(status) { return status }
        return .disconnected
    }
}
