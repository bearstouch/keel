import Foundation

/// What production tabs look like (FR-SF02, FR-SF07, 08 Design → Production strip): the strip's text, the window title
/// the Window menu lists and the one-time write notice. Text always carries the meaning, never the maroon alone.
public enum ProductionChrome {
    public static let stripHeight: CGFloat = 28
    public static let writeNotice = "Writing to PRODUCTION"
    /// The toolbar's words when the server itself refuses writes (02 Architecture → Safety policy).
    public static let serverReadOnly = "Server-enforced read-only"

    /// "Production · Read-only", or "Production" alone while writes are allowed.
    public static func stripText(readOnly: Bool) -> String { readOnly ? "Production · Read-only" : "Production" }

    /// The window's title (Window menu, VoiceOver): the selected tab's connection, marked "[PROD]" when it is production;
    /// "Keel" for a window without tabs.
    @MainActor public static func windowTitle(name: String?, production: Bool) -> String {
        guard let name else { return MainWindow.title }
        return production ? "\(name) [PROD]" : name
    }
}
