import Foundation

/// The committed release decision record (`release/manifest.json`, MAC-10).
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Dependency: Codable, Equatable, Sendable {
        public let name: String, version: String, revision: String, license: String, licenseFile: String
    }
    /// The update channel (INT-11): the HTTPS appcast, where its archives are served, and the public EdDSA key every
    /// archive and the appcast itself must verify against. The private key never enters the repository.
    public struct Sparkle: Codable, Equatable, Sendable {
        public let version: String, feedURL: String, downloadURLPrefix: String, publicEDKey: String
    }
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let minimumMacOS: String
    public let architectures: [String]
    public let packageFormat: String
    /// `CFBundleIconName` / `CFBundleIconFile`: `Assets.car` (compiled from `release/icon/AppIcon.icon`) and `AppIcon.icns`.
    public let iconName: String
    public let artifacts: [String]
    public let dependencies: [Dependency]
    public let sparkle: Sparkle
    /// The checks `package-release.sh` records in `release-evidence.json`, by ID (MAC-11); see `ReleaseChecklist`.
    public let releaseChecks: [String]

    /// Facts read from the built product, compared with the manifest.
    public struct BuiltProduct: Equatable, Sendable {
        public var bundleIdentifier: String
        public var minimumMacOS: String
        public var architectures: Set<String>
        public var files: Set<String>
        /// Info.plist `CFBundleIconName`; nil when the key is missing.
        public var iconName: String?
        public init(bundleIdentifier: String, minimumMacOS: String, architectures: Set<String>, files: Set<String>, iconName: String?) {
            self.bundleIdentifier = bundleIdentifier; self.minimumMacOS = minimumMacOS; self.architectures = architectures; self.files = files; self.iconName = iconName
        }
    }

    /// The deployment target declared in `Package.swift` (`.macOS(.vNN)`), as `"NN.0"`; nil when none is found.
    public static func packageMinimumMacOS(in packageSource: String) -> String? {
        guard let range = packageSource.range(of: #"\.macOS\(\.v(\d+)\)"#, options: .regularExpression) else { return nil }
        return String(packageSource[range].filter(\.isNumber)) + ".0"
    }

    /// Every mismatch between policy and product; empty means consistent.
    public func problems(packageMinimumMacOS: String, product: BuiltProduct) -> [String] {
        var problems: [String] = []
        // `package-release.sh` only produces a DMG (MAC-10), so any other format is a manifest error.
        if packageFormat != "dmg" { problems.append("Package format \(packageFormat) is not a DMG.") }
        if minimumMacOS != packageMinimumMacOS { problems.append("Package.swift targets macOS \(packageMinimumMacOS) but the manifest says \(minimumMacOS).") }
        if product.minimumMacOS != minimumMacOS { problems.append("Info.plist LSMinimumSystemVersion is \(product.minimumMacOS), expected \(minimumMacOS).") }
        if product.bundleIdentifier != bundleIdentifier { problems.append("Bundle identifier is \(product.bundleIdentifier), expected \(bundleIdentifier).") }
        if product.iconName != iconName { problems.append("Info.plist CFBundleIconName is \(product.iconName ?? "missing"), expected \(iconName).") }
        for architecture in architectures where !product.architectures.contains(architecture) { problems.append("The executable lacks the \(architecture) slice.") }
        for artifact in artifacts where !product.files.contains(artifact) { problems.append("Missing artifact \(artifact).") }
        for dependency in dependencies where dependency.license.isEmpty || dependency.licenseFile.isEmpty {
            problems.append("Dependency \(dependency.name) has no recorded license.")
        }
        problems += sparkleProblems
        return problems
    }

    /// The Sparkle record on its own: an HTTPS feed and download host, a real Ed25519 public key, and the same Sparkle
    /// version as the recorded dependency (which `Package.swift` pins exactly).
    public var sparkleProblems: [String] {
        var problems: [String] = []
        for (name, url) in [("feed", sparkle.feedURL), ("download prefix", sparkle.downloadURLPrefix)] {
            let parsed = URL(string: url)
            if parsed?.scheme != "https" || parsed?.host == nil { problems.append("The Sparkle \(name) \(url) is not an HTTPS URL.") }
        }
        if !sparkle.downloadURLPrefix.hasSuffix("/") { problems.append("The Sparkle download prefix must end in /.") }
        if !UpdatePolicy.isPublicEDKey(sparkle.publicEDKey) { problems.append("The Sparkle public key is not a base64 Ed25519 key.") }
        if dependencies.first(where: { $0.name == "Sparkle" })?.version != sparkle.version { problems.append("Sparkle \(sparkle.version) is not a recorded dependency.") }
        return problems
    }
}
