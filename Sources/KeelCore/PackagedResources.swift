import Foundation

extension Bundle {
    /// A SwiftPM resource bundle inside a packaged app's `Contents/Resources`. SwiftPM's own `Bundle.module` looks beside
    /// `Keel.app` itself, where codesign refuses unsealed content, then in the build folder, which a user's Mac doesn't
    /// have; so packaged builds look here first and `swift run` falls through to `Bundle.module`.
    public static func packagedResources(_ name: String, in main: Bundle = .main) -> Bundle? {
        main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("\(name).bundle")) }
    }

    /// KeelCore's resources (server detection rules, the command catalog).
    static let keelCore = packagedResources("Keel_KeelCore") ?? .module
}
