import AppKit
import Combine
import KeelCore

/// The app's current shortcut bindings (FR-AP02): Settings → Keyboard edits them, the menus are built from them. Saved
/// in `UserDefaults` (02 → Persistence) as the vendored settings' JSON, which stores only differences from the defaults.
/// A rejected chord leaves the bindings as they were.
@MainActor
public final class ShortcutBindings: ObservableObject {
    public static let defaultsKey = "keyboardShortcuts"

    @Published public private(set) var map: KeelShortcutMap
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        map = Self.load(from: defaults)
    }

    /// A saved map that no longer validates (edited by hand, from a build with other rules) falls back to the defaults
    /// for this run; the saved value is left alone until the user changes a shortcut.
    private static func load(from defaults: UserDefaults) -> KeelShortcutMap {
        guard let data = defaults.data(forKey: defaultsKey), let settings = try? JSONDecoder().decode(KeelShortcutSettings.self, from: data),
            settings.shortcuts.issues().isEmpty
        else { return .defaults }
        return settings.shortcuts
    }

    public subscript(action: KeelShortcut) -> KeyChord? { map[action] }

    /// Binds `chord` to `action`, or clears it with nil. Throws the rule it breaks (a conflict names the other command).
    public func bind(_ action: KeelShortcut, to chord: KeyChord?) throws(KeelShortcutIssue) {
        apply(try map.binding(action, to: chord))
    }

    /// The action's default again; refused like any other chord if another command took it meanwhile.
    public func restoreDefault(_ action: KeelShortcut) throws(KeelShortcutIssue) { try bind(action, to: action.defaultChord) }

    public func restoreAllDefaults() { apply(.defaults) }

    private func apply(_ next: KeelShortcutMap) {
        guard next != map else { return }
        map = next
        var settings = KeelShortcutSettings()
        settings.shortcuts = next
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension KeyChord {
    /// NSMenuItem's key equivalent and modifier mask for this chord.
    public var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        for (modifier, flag) in Self.modifierFlags where modifiers.contains(modifier) { mask.insert(flag) }
        return (Self.menuKeys[key] ?? key, mask)
    }

    /// The chord a key press in Settings → Keyboard means: the key as the active layout types it without modifiers, so
    /// ⇧⌘] records as "]" with ⇧, not "}". Nil for a bare modifier press or a key Keel can't bind.
    public init?(event: NSEvent) {
        var modifiers: KeyModifiers = []
        for (modifier, flag) in Self.modifierFlags where event.modifierFlags.contains(flag) { modifiers.insert(modifier) }
        let key: String
        if let named = Self.namedKeyCodes[event.keyCode] {
            key = named
        } else if let typed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, typed.count == 1 {
            key = typed
        } else {
            return nil
        }
        let chord = KeyChord(key, modifiers)
        guard chord.isSupported else { return nil }
        self = chord
    }

    /// Keel's modifiers and AppKit's flags for them; other flags (Caps Lock, Fn) never take part in a chord.
    private static let modifierFlags: [(KeyModifiers, NSEvent.ModifierFlags)] = [(.command, .command), (.shift, .shift), (.option, .option), (.control, .control)]

    /// AppKit's characters for the named keys.
    private static let menuKeys: [String: String] = {
        var keys = [
            "return": "\r", "tab": "\t", "space": " ", "delete": "\u{8}", "forwardDelete": String(UnicodeScalar(NSDeleteFunctionKey)!),
            "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
            "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!),
            "home": String(UnicodeScalar(NSHomeFunctionKey)!), "end": String(UnicodeScalar(NSEndFunctionKey)!),
            "pageUp": String(UnicodeScalar(NSPageUpFunctionKey)!), "pageDown": String(UnicodeScalar(NSPageDownFunctionKey)!)
        ]
        for number in 1...12 { keys["f\(number)"] = String(UnicodeScalar(NSF1FunctionKey + number - 1)!) }
        return keys
    }()

    /// Virtual key codes of the named keys (layout independent).
    private static let namedKeyCodes: [UInt16: String] = [
        36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete", 117: "forwardDelete", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12"
    ]
}
