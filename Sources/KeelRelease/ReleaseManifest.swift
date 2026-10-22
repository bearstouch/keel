import Foundation

/// The committed release decision record (`release/manifest.json`, MAC-10).
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Dependency: Codable, Equatable, Sendable {
        public let name: String, version: String, revision: String, license: String, licenseFile: String
    }
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let minimumMacOS: String
    public let architectures: [String]
    public let packageFormat: String
    public let artifacts: [String]
    public let dependencies: [Dependency]

    /// Facts read from the built product, compared with the manifest.
    public struct BuiltProduct: Equatable, Sendable {
        public var bundleIdentifier: String
        public var minimumMacOS: String
        public var architectures: Set<String>
        public var files: Set<String>
        public init(bundleIdentifier: String, minimumMacOS: String, architectures: Set<String>, files: Set<String>) {
            self.bundleIdentifier = bundleIdentifier; self.minimumMacOS = minimumMacOS; self.architectures = architectures; self.files = files
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
        for architecture in architectures where !product.architectures.contains(architecture) { problems.append("The executable lacks the \(architecture) slice.") }
        for artifact in artifacts where !product.files.contains(artifact) { problems.append("Missing artifact \(artifact).") }
        for dependency in dependencies where dependency.license.isEmpty || dependency.licenseFile.isEmpty {
            problems.append("Dependency \(dependency.name) has no recorded license.")
        }
        return problems
    }
}
