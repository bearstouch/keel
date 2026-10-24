import Foundation

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}

/// Layout-neutral chord. `key` is a single lowercase character as produced by the
/// active layout without modifiers, or one of `KeyChord.namedKeys`.
public struct KeyChord: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let namedKeys: Set<String> = Set(
        ["left", "right", "up", "down", "return", "tab", "space", "delete", "forwardDelete", "home", "end", "pageUp", "pageDown"]
            + (1...12).map { "f\($0)" })
    public let key: String
    public let modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = .command) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public var isSupported: Bool { key.count == 1 ? key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } : Self.namedKeys.contains(key) }

    /// Menu-style glyphs in Apple's modifier order, e.g. ⌃⌥⇧⌘D.
    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let glyphs = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space",
            "delete": "⌫", "forwardDelete": "⌦", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟"
        ]
        return text + (glyphs[key] ?? key.uppercased())
    }
}

/// A rebindable command. Keel's own table (FR-AP02, "Default shortcuts") is `KeelShortcut`; the binding rules
/// below do not depend on it. Raw values are what saved settings store, so they never change once shipped.
public protocol ShortcutAction: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {
    /// Menu title, used in conflict messages.
    var title: String { get }
    /// Nil leaves the action deliberately unbound; it stays reachable from its menu.
    var defaultChord: KeyChord? { get }
    /// Actions whose default chord shipped after saved maps already existed.
    static var laterDefaults: [Self] { get }
}

extension ShortcutAction {
    public static var laterDefaults: [Self] { [] }
}

public enum ShortcutIssue<Action: ShortcutAction>: Error, Equatable, Sendable, CustomStringConvertible {
    case conflict(KeyChord, [Action])
    case reserved(KeyChord, Action, reservedFor: String)
    case requiresCommand(KeyChord, Action)
    case unsupportedKey(KeyChord, Action)

    public var description: String {
        switch self {
        case .conflict(let chord, let actions):
            "\(chord) is assigned to both \(actions.map(\.title).joined(separator: " and ")). Choose a different shortcut for one of them."
        case .reserved(let chord, let action, let owner): "\(chord) is reserved for \(owner) and cannot be used for \(action.title)."
        case .requiresCommand(let chord, let action): "\(chord) for \(action.title) must include ⌘ so console control keys keep working."
        case .unsupportedKey(let chord, let action): "\(chord) is not a supported key for \(action.title)."
        }
    }
}

/// Native editing and application commands. Text fields and the console's
/// copy/paste depend on these, so they can never be reassigned (FR-AP02).
private let reservedChords: [KeyChord: String] = [
    KeyChord("c"): "Copy", KeyChord("v"): "Paste", KeyChord("x"): "Cut", KeyChord("a"): "Select All",
    KeyChord("z"): "Undo", KeyChord("z", [.command, .shift]): "Redo", KeyChord("q"): "Quit Keel",
    KeyChord("h"): "Hide Keel", KeyChord("h", [.command, .option]): "Hide Others", KeyChord(","): "Settings…",
    KeyChord("m"): "Minimize", KeyChord("`"): "Cycle Windows", KeyChord("tab"): "Switch Applications",
    KeyChord("space"): "Spotlight"
]

/// Complete action → chord map. A nil entry means the action is deliberately
/// unbound; it stays reachable from its menu. Validation never mutates `self`.
public struct ShortcutMap<Action: ShortcutAction>: Equatable, Sendable {
    public static var reserved: [KeyChord: String] { reservedChords }
    public private(set) var chords: [Action: KeyChord]

    public static var defaults: Self { Self(chords: Dictionary(uniqueKeysWithValues: Action.allCases.compactMap { action in action.defaultChord.map { (action, $0) } })) }

    public init(chords: [Action: KeyChord]) { self.chords = chords }

    public subscript(action: Action) -> KeyChord? { chords[action] }

    public func action(for chord: KeyChord) -> Action? { chords.first { $0.value == chord }?.key }

    /// Every problem, in a stable order, so the UI can name all affected actions.
    public func issues() -> [ShortcutIssue<Action>] {
        var result: [ShortcutIssue<Action>] = []
        var owners: [KeyChord: [Action]] = [:]
        for action in Action.allCases {
            guard let chord = chords[action] else { continue }
            if !chord.isSupported {
                result.append(.unsupportedKey(chord, action))
            } else if !chord.modifiers.contains(.command) {
                result.append(.requiresCommand(chord, action))
            } else if let owner = Self.reserved[chord] {
                result.append(.reserved(chord, action, reservedFor: owner))
            }
            owners[chord, default: []].append(action)
        }
        for action in Action.allCases {
            if let chord = chords[action], let shared = owners[chord], shared.count > 1, shared.first == action {
                result.append(.conflict(chord, shared))
            }
        }
        return result
    }

    /// Unvalidated draft edit, so a user can swap two shortcuts in steps.
    public func assigning(_ chord: KeyChord?, to action: Action) -> Self {
        var next = self
        next.chords[action] = chord
        return next
    }

    /// Returns the updated map or throws the first issue; the receiver is unchanged.
    public func binding(_ action: Action, to chord: KeyChord?) throws(ShortcutIssue<Action>) -> Self {
        let next = assigning(chord, to: action)
        if let issue = next.issues().first(where: { $0.involves(action) }) { throw issue }
        return next
    }
}

extension ShortcutIssue {
    public func involves(_ action: Action) -> Bool {
        switch self {
        case .conflict(_, let actions): actions.contains(action)
        case .reserved(_, let owner, _), .requiresCommand(_, let owner), .unsupportedKey(_, let owner): owner == action
        }
    }
}

/// Persisted keyboard preferences. Only differences from the defaults are stored
/// so new default bindings reach existing users.
public struct ShortcutSettings<Action: ShortcutAction>: Equatable, Sendable, Codable {
    public var shortcuts = ShortcutMap<Action>.defaults
    public init() {}

    private enum CodingKeys: String, CodingKey { case overrides }
    /// A missing chord encodes as JSON null so an unbound default survives a round trip.
    private struct Override: Codable { var chord: KeyChord? }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var chords = ShortcutMap<Action>.defaults.chords
        var overridden: Set<Action> = []
        // Unknown action names from a newer build are ignored rather than fatal.
        for (name, override) in try values.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:] {
            guard let action = Action(rawValue: name) else { continue }
            chords[action] = override.chord; overridden.insert(action)
        }
        // A default added in a later build yields to a chord the user already chose,
        // instead of turning the whole saved map into a conflict. Other conflicts still reject the map.
        let chosen = Set(overridden.compactMap { chords[$0] })
        for action in Action.laterDefaults where !overridden.contains(action) {
            if let chord = chords[action], chosen.contains(chord) { chords[action] = nil }
        }
        shortcuts = ShortcutMap(chords: chords)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        var overrides: [String: Override] = [:]
        for action in Action.allCases where shortcuts[action] != action.defaultChord {
            overrides[action.rawValue] = Override(chord: shortcuts[action])
        }
        try values.encode(overrides, forKey: .overrides)
    }
}
