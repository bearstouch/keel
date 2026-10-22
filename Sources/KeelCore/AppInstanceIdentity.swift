import Foundation

/// Which Keel this process is. The installed app (`com.bearstouch.keel`) and development builds (`swift run`,
/// unbundled binaries) get separate state directories and settings, so both can run at once (MAC-17).
public struct AppInstanceIdentity: Equatable, Sendable {
    public static let production = "com.bearstouch.keel"
    public static let development = "com.bearstouch.keel.dev"
    public let identifier: String

    /// An unbundled executable has no bundle identifier and is always a development build.
    public init(bundleIdentifier: String?) { identifier = bundleIdentifier ?? Self.development }

    public var isDevelopment: Bool { identifier != Self.production }
}
