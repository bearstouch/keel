import Foundation

/// What a tab shows (FR-AP01, 08 Design → Toolbar): ⌘1 / ⌘2 / ⌘3.
public enum TabMode: String, Codable, Sendable, CaseIterable {
    case browser, console, info

    public var title: String {
        switch self {
        case .browser: "Browser"
        case .console: "Console"
        case .info: "Info"
        }
    }

    /// The digit of its ⌘ shortcut.
    public var keyEquivalent: String {
        switch self {
        case .browser: "1"
        case .console: "2"
        case .info: "3"
        }
    }
}

/// One tab as `windows.json` keeps it: the profile, its database and mode. The selected key is kept in memory only:
/// key names from browsing are never persisted (02 Architecture → Persistence).
public struct SavedTab: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var database: Int
    public var mode: TabMode

    public init(id: UUID = UUID(), profileID: UUID, database: Int, mode: TabMode = .browser) {
        self.id = id; self.profileID = profileID; self.database = database; self.mode = mode
    }
}

/// A window's frame in screen coordinates (AppKit's, origin at the bottom left of the main display).
public struct SavedFrame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct SavedWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var frame: SavedFrame?
    public var tabs: [SavedTab]
    public var selectedTabID: UUID?

    public init(id: UUID = UUID(), frame: SavedFrame? = nil, tabs: [SavedTab] = [], selectedTabID: UUID? = nil) {
        self.id = id; self.frame = frame; self.tabs = tabs; self.selectedTabID = selectedTabID
    }
}

/// `windows.json` (02 Architecture → Persistence): native windows in order, their frames and tabs. Restored
/// disconnected unless a tab's profile reconnects on launch (FR-CN15).
public struct WindowsDocument: PersistedDocument, Equatable {
    public static let file = PersistedFile.windows
    public static let currentVersion = 1
    /// More is a hand-edited or hostile file: restoring it would open that many windows. The rest are dropped.
    public static let maximumWindows = 64
    public static let maximumTabsPerWindow = 128

    /// The welcome screen's recent connections (FR-AP08): profiles most recently opened in a tab, newest first. Profile
    /// IDs only, never key names. Absent in files written before KEEL-050, so it decodes as empty.
    public static let maximumRecents = 8

    public var windows: [SavedWindow]
    public var recentProfileIDs: [UUID]

    public init(windows: [SavedWindow] = [], recentProfileIDs: [UUID] = []) { self.windows = windows; self.recentProfileIDs = recentProfileIDs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([SavedWindow].self, forKey: .windows)
        recentProfileIDs = try container.decodeIfPresent([UUID].self, forKey: .recentProfileIDs) ?? []
    }

    /// What a launch restores: at most the limits above, tabs whose profile still exists, every window and tab ID once
    /// (the first wins) and a selection that names one of the window's tabs. Windows left empty are kept: an empty window is
    /// a window the user had open. Recents keep existing profiles, each once, at most `maximumRecents`.
    public func restorable(profileIDs: Set<UUID>) -> WindowsDocument {
        var seen = Set<UUID>(), seenWindows = Set<UUID>()
        // A repeated window ID would be a second model window that no native window shows.
        let unique = self.windows.filter { seenWindows.insert($0.id).inserted }
        let windows = unique.prefix(Self.maximumWindows).map { window in
            var window = window
            window.tabs = window.tabs.prefix(Self.maximumTabsPerWindow).filter { profileIDs.contains($0.profileID) && seen.insert($0.id).inserted }
            if !window.tabs.contains(where: { $0.id == window.selectedTabID }) { window.selectedTabID = window.tabs.first?.id }
            return window
        }
        var seenRecents = Set<UUID>()
        let recents = recentProfileIDs.filter { profileIDs.contains($0) && seenRecents.insert($0).inserted }.prefix(Self.maximumRecents)
        return WindowsDocument(windows: Array(windows), recentProfileIDs: Array(recents))
    }
}

/// FR-CN15: Reconnect on launch is per profile and off by default. Profiles treated as production never reconnect by
/// themselves, whatever the option says: connecting to production is always the user's explicit action.
public enum ReconnectPolicy {
    public static func reconnectsOnLaunch(_ profile: ConnectionProfile, isProduction: Bool) -> Bool {
        profile.settings.reconnectOnLaunch && !isProduction
    }
}
