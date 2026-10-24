import Foundation
import os

/// The app's theme (FR-AP04, 08 Design → DS-11): Light on first launch, Dark, or System (follows macOS live).
public enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case light, dark, system

    public static let `default` = ThemeChoice.light

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// Settings → Browser (FR-AP09): what every new scan starts from. A profile's own separator wins over this one.
public struct BrowserSettings: Codable, Sendable, Equatable {
    public static let pageSizeRange = 10...KeyIndexConfiguration.maximumPageSize
    public static let autoPageLimitRange = 1_000...KeyIndexConfiguration.maximumLimit

    /// 1–4 bytes, no control characters (FR-KB03); `:` by default.
    public var separator: String
    /// SCAN's `COUNT` (FR-KB02).
    public var pageSize: Int
    /// Loaded keys at which Auto-page stops; Continue raises it by this much again (FR-KB02).
    public var autoPageLimit: Int

    public init(separator: String = ":", pageSize: Int = KeyIndexConfiguration.defaultPageSize, autoPageLimit: Int = KeyIndexConfiguration.defaultLimit) {
        self.separator = separator; self.pageSize = pageSize; self.autoPageLimit = autoPageLimit
    }

    public static func isValidSeparator(_ text: String) -> Bool { (1...4).contains(text.utf8.count) && !ConnectionSettings.hasControl(text) }

    /// Never nil: the setting is validated before it is applied, and decoding replaces an invalid one.
    public var namespaceSeparator: NamespaceSeparator { NamespaceSeparator(profile: separator) }

    /// The scan configuration for a new scan with `filter`.
    public func configuration(filter: KeyFilter = KeyFilter()) -> KeyIndexConfiguration {
        KeyIndexConfiguration(pageSize: pageSize, limit: autoPageLimit, filter: filter)
    }

    private enum CodingKeys: String, CodingKey { case separator, pageSize, autoPageLimit }

    /// Each field on its own: a hand-edited bad value reads as its default, never sending the file to recovery.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = BrowserSettings()
        separator = (decoded(c, .separator) as String?).flatMap { Self.isValidSeparator($0) ? $0 : nil } ?? d.separator
        pageSize = decodeInRange(c, .pageSize, Self.pageSizeRange) ?? d.pageSize
        autoPageLimit = decodeInRange(c, .autoPageLimit, Self.autoPageLimitRange) ?? d.autoPageLimit
    }
}

/// The value viewer an editor opens a key in when the tab hasn't remembered one for its pattern (FR-AP09).
public enum DefaultViewer: String, Codable, CaseIterable, Sendable {
    /// JSON when the value parses, else Text (03 → Value editors).
    case automatic, text, json, hex, raw

    public var title: String { mode?.rawValue ?? "Automatic" }

    /// Nil leaves the choice to the value (JSON or Text).
    public var mode: ValueViewMode? {
        switch self {
        case .automatic: nil
        case .text: .text
        case .json: .json
        case .hex: .hex
        case .raw: .raw
        }
    }
}

/// Settings → Editors (FR-AP09).
public struct EditorSettings: Codable, Sendable, Equatable {
    public var defaultViewer: DefaultViewer

    public init(defaultViewer: DefaultViewer = .automatic) { self.defaultViewer = defaultViewer }

    private enum CodingKeys: String, CodingKey { case defaultViewer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultViewer = decoded(c, .defaultViewer) ?? .automatic
    }
}

/// Settings → Console (FR-AP09). RESP3 asks for `HELLO 3` (a server without it answers on RESP2 anyway); RESP2 shows
/// replies exactly as a RESP2 redis-cli would.
public struct ConsoleSettings: Codable, Sendable, Equatable {
    public static let protocolVersions = [3, 2]

    public var protocolVersion: Int

    public init(protocolVersion: Int = 3) { self.protocolVersion = protocolVersion }

    private enum CodingKeys: String, CodingKey { case protocolVersion }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = (decoded(c, .protocolVersion) as Int?).flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? 3
    }
}

/// Settings → Advanced (FR-AP09): what a profile without its own timeouts uses, and whether connections send
/// `CLIENT SETNAME keel` (NFR-PV04).
public struct AdvancedSettings: Codable, Sendable, Equatable {
    /// The profile editor's range (`ConnectionSettings.timeoutRange`), in milliseconds.
    public static let timeoutRange = ConnectionSettings.timeoutRange

    public var connectTimeoutMilliseconds: Int
    public var commandTimeoutMilliseconds: Int
    public var setsClientName: Bool

    public init(connectTimeoutMilliseconds: Int = 10_000, commandTimeoutMilliseconds: Int = 30_000, setsClientName: Bool = true) {
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds; self.commandTimeoutMilliseconds = commandTimeoutMilliseconds; self.setsClientName = setsClientName
    }

    public var connectTimeout: Duration { .milliseconds(connectTimeoutMilliseconds) }
    public var commandTimeout: Duration { .milliseconds(commandTimeoutMilliseconds) }

    private enum CodingKeys: String, CodingKey { case connectTimeoutMilliseconds, commandTimeoutMilliseconds, setsClientName }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = AdvancedSettings()
        connectTimeoutMilliseconds = decodeInRange(c, .connectTimeoutMilliseconds, Self.timeoutRange) ?? d.connectTimeoutMilliseconds
        commandTimeoutMilliseconds = decodeInRange(c, .commandTimeoutMilliseconds, Self.timeoutRange) ?? d.commandTimeoutMilliseconds
        setsClientName = decoded(c, .setsClientName) ?? d.setsClientName
    }
}

/// `settings.json` (02 Architecture → Persistence): the Settings window's panes in one document with one writer.
/// Never holds values, key names or secrets. Keyboard bindings live in `UserDefaults` (FR-AP02), not here.
public struct SettingsDocument: PersistedDocument, Equatable {
    public static let file = PersistedFile.settings
    public static let currentVersion = 1

    public var theme: ThemeChoice
    /// General: reopen the last session's windows and tabs at launch (FR-AP01); off opens one empty window.
    public var restoresWindows: Bool
    public var browser: BrowserSettings
    public var editors: EditorSettings
    public var console: ConsoleSettings
    public var advanced: AdvancedSettings

    public init(
        theme: ThemeChoice = .default, restoresWindows: Bool = true, browser: BrowserSettings = BrowserSettings(), editors: EditorSettings = EditorSettings(),
        console: ConsoleSettings = ConsoleSettings(), advanced: AdvancedSettings = AdvancedSettings()
    ) {
        self.theme = theme; self.restoresWindows = restoresWindows; self.browser = browser; self.editors = editors; self.console = console; self.advanced = advanced
    }

    private enum CodingKeys: String, CodingKey { case theme, restoresWindows, browser, editors, console, advanced }

    /// A missing or unknown value (hand-edited, a file from before KEEL-049, or a choice a later build added) reads as
    /// its default rather than sending the whole file to recovery.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = decoded(c, .theme) ?? .default
        restoresWindows = decoded(c, .restoresWindows) ?? true
        browser = decoded(c, .browser) ?? BrowserSettings()
        editors = decoded(c, .editors) ?? EditorSettings()
        console = decoded(c, .console) ?? ConsoleSettings()
        advanced = decoded(c, .advanced) ?? AdvancedSettings()
    }
}

/// The applied settings for code off the main actor: a new scan reads the browser defaults, a new connect the
/// timeouts, `CLIENT SETNAME` and the console's protocol. The settings model writes it on load and on every Apply.
public final class SettingsSnapshot: Sendable {
    private let state: OSAllocatedUnfairLock<SettingsDocument>

    public init(_ document: SettingsDocument = SettingsDocument()) { state = OSAllocatedUnfairLock(initialState: document) }

    public var current: SettingsDocument {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A field, or nil when it is missing or doesn't decode.
private func decoded<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> T? { try? container.decodeIfPresent(T.self, forKey: key) }

/// An Int field within `range`, else nil (missing, wrong type or out of range).
private func decodeInRange<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K, _ range: ClosedRange<Int>) -> Int? {
    (decoded(container, key) as Int?).flatMap { range.contains($0) ? $0 : nil }
}
