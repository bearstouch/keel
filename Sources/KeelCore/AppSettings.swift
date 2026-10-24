import Foundation

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

/// `settings.json` (02 Architecture → Persistence): appearance today; KEEL-049 adds the browser, editor and console
/// options to this same document, so the file keeps one writer. Never holds values, key names or secrets.
public struct SettingsDocument: PersistedDocument, Equatable {
    public static let file = PersistedFile.settings
    public static let currentVersion = 1

    public var theme: ThemeChoice

    public init(theme: ThemeChoice = .default) { self.theme = theme }

    private enum CodingKeys: String, CodingKey { case theme }

    /// A missing or unknown theme (hand-edited, or a choice a later build added) reads as the default rather than
    /// sending the whole file to recovery.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(ThemeChoice.self, forKey: .theme)) ?? .default
    }
}
