import Foundation

/// Keel's rebindable commands (FR-AP02, 03 → Default shortcuts). Raw values are what saved bindings store: never rename
/// one once shipped. The binding rules (conflicts, ⌘ required, reserved chords) are the vendored `ShortcutMap`'s.
public enum KeelShortcut: String, ShortcutAction {
    case newWindow, newTab, closeTab, closeWindow, saveChanges
    case commandPalette, browserMode, consoleMode, infoMode, toggleTreeFlat, filterKeys, refresh, toggleConsolePanel
    case database0, database1, database2, database3, database4, database5, database6, database7, database8, database9
    case clearConsole, stopCommand, zoomIn, zoomOut, zoomReset, toggleSidebar
    case newKey, renameKey, setTTL, deleteKeys
    case reconnect, disconnect
    case nextTab, previousTab

    /// The menu each command lives in, in menu-bar order; Settings → Keyboard groups by it.
    public enum Menu: String, CaseIterable, Sendable { case file = "File", view = "View", key = "Key", connection = "Connection", window = "Window" }

    public var menu: Menu {
        switch self {
        case .newWindow, .newTab, .closeTab, .closeWindow, .saveChanges: .file
        case .newKey, .renameKey, .setTTL, .deleteKeys: .key
        case .reconnect, .disconnect: .connection
        case .nextTab, .previousTab: .window
        default: .view
        }
    }

    public var title: String {
        if let database { return "Database db\(database)" }
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .closeWindow: return "Close Window"
        case .saveChanges: return "Save Changes"
        case .commandPalette: return "Command Palette…"
        case .browserMode: return "Browser"
        case .consoleMode: return "Console"
        case .infoMode: return "Info"
        case .toggleTreeFlat: return "Toggle Tree / Flat"
        case .filterKeys: return "Filter Keys"
        case .refresh: return "Refresh"
        case .toggleConsolePanel: return "Toggle Console Panel"
        case .clearConsole: return "Clear Console"
        case .stopCommand: return "Stop"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Actual Size"
        case .toggleSidebar: return "Hide / Show Sidebar"
        case .newKey: return "New Key…"
        case .renameKey: return "Rename Key…"
        case .setTTL: return "Set TTL…"
        case .deleteKeys: return "Delete Selected Keys…"
        case .reconnect: return "Reconnect"
        case .disconnect: return "Disconnect"
        case .nextTab: return "Show Next Tab"
        case .previousTab: return "Show Previous Tab"
        default: return rawValue  // only the database cases, titled above
        }
    }

    /// 0–9 for the Select db0–db9 commands.
    public var database: Int? {
        guard rawValue.hasPrefix("database"), let digit = Int(rawValue.dropFirst("database".count)) else { return nil }
        return digit
    }

    public static func database(_ index: Int) -> Self? { Self(rawValue: "database\(index)") }

    public var defaultChord: KeyChord? {
        if let database { return KeyChord(String(database), [.command, .option]) }
        let shift: KeyModifiers = [.command, .shift]
        switch self {
        case .newWindow: return KeyChord("n")
        case .newTab: return KeyChord("t")
        case .closeTab: return KeyChord("w")
        case .closeWindow: return KeyChord("w", shift)
        case .saveChanges: return KeyChord("s")
        case .commandPalette: return KeyChord("k")
        case .browserMode: return KeyChord("1")
        case .consoleMode: return KeyChord("2")
        case .infoMode: return KeyChord("3")
        case .toggleTreeFlat: return KeyChord("t", shift)
        case .filterKeys: return KeyChord("f")
        case .refresh: return KeyChord("r")
        case .toggleConsolePanel: return KeyChord("j")
        case .clearConsole: return KeyChord("k", [.command, .option])
        case .stopCommand: return KeyChord(".")
        case .zoomIn: return KeyChord("+")
        case .zoomOut: return KeyChord("-")
        case .zoomReset: return KeyChord("0")
        case .toggleSidebar: return KeyChord("s", [.command, .control])
        case .newKey: return KeyChord("n", shift)
        case .renameKey: return KeyChord("e")
        case .setTTL: return KeyChord("e", [.command, .option])
        case .deleteKeys: return KeyChord("delete")
        case .reconnect: return KeyChord("r", shift)
        case .disconnect: return KeyChord("d", shift)
        case .nextTab: return KeyChord("]", shift)
        case .previousTab: return KeyChord("[", shift)
        default: return nil  // only the database cases, keyed above
        }
    }

    /// Commands whose shortcut can't be rebound (FR-AP02), in menu order. Revert Changes keeps ⌘Z: it stands where Undo
    /// would be (editors have no undo stack), so it is as fixed as Undo. Settings → Keyboard lists these read-only.
    public static let fixed: [(title: String, chord: KeyChord)] = [
        ("Settings…", KeyChord(",")), ("Hide Keel", KeyChord("h")), ("Hide Others", KeyChord("h", [.command, .option])), ("Quit Keel", KeyChord("q")),
        ("Revert Changes", KeyChord("z")), ("Redo", KeyChord("z", [.command, .shift])), ("Cut", KeyChord("x")), ("Copy", KeyChord("c")),
        ("Paste", KeyChord("v")), ("Select All", KeyChord("a")), ("Minimize", KeyChord("m"))
    ]
}

public typealias KeelShortcutMap = ShortcutMap<KeelShortcut>
public typealias KeelShortcutSettings = ShortcutSettings<KeelShortcut>
public typealias KeelShortcutIssue = ShortcutIssue<KeelShortcut>

extension ShortcutIssue where Action == KeelShortcut {
    /// What Settings → Keyboard says when a new chord is rejected for `action`: the other command it belongs to is named
    /// (AC2), as is a reserved system command.
    public func rejection(for action: KeelShortcut) -> String {
        switch self {
        case .conflict(let chord, let actions):
            let others = actions.filter { $0 != action }.map(\.title).joined(separator: " and ")
            return "\(chord) is already used by \(others). Choose another shortcut or change that one first."
        default: return description
        }
    }
}

extension KeelShortcut {
    /// Commands whose feature isn't built yet (the Browser console panel, data-font zoom). Their defaults are reserved so a
    /// user's own chord never collides with them later; menus and the palette leave them out until they ship.
    public static let notYetAvailable: Set<KeelShortcut> = [.toggleConsolePanel, .zoomIn, .zoomOut, .zoomReset]
}

extension TabMode {
    /// The command that switches a tab to this mode (⌘1 / ⌘2 / ⌘3 by default).
    public var shortcut: KeelShortcut {
        switch self {
        case .browser: .browserMode
        case .console: .consoleMode
        case .info: .infoMode
        }
    }
}
