import Foundation
import KeelAskpass
import XCTest
@testable import KeelSSH

/// Keel never touches Trellis's state, settings or Keychain items at run time (INT-07): the code it ships, including
/// what is vendored from Trellis, must not name Trellis's Keychain services, state paths, environment variables,
/// helper or port (KEEL-002 AC3).
final class VendoredIdentifiersTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Everything that is compiled into or bundled with the app.
    private static let scanned = ["Sources", "ThirdParty/TrellisShared", "release"]
    private static let forbidden: [(name: String, pattern: String)] = [
        ("Trellis Keychain service or item label", #"(?i)Trellis (SSH Host|Automation|Connection|TLS|Control)"#),
        ("Trellis bundle or state path", #"(?i)com\.bearstouch\.trellis"#),
        ("Trellis Application Support folder", #"Application Support/Trellis"#),
        ("Trellis environment variable", #"TRELLIS_"#),
        ("Trellis helper", #"trellis-(askpass|broker|cli)"#),
        ("Trellis port", #"\b7777\b"#)
    ]

    func testNoTrellisRuntimeIdentifiers() throws {
        var files: [URL] = []
        for folder in Self.scanned {
            let url = Self.root.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
        }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "PROVENANCE.md" }, "The scan must reach the vendored folder")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "HostSecrets.swift" })
        let patterns = try Self.forbidden.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var findings: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for (name, pattern) in patterns where pattern.firstMatch(in: text, range: range) != nil {
                findings.append("\(file.path.replacingOccurrences(of: Self.root.path + "/", with: "")): \(name)")
            }
        }
        XCTAssertEqual(findings, [])
    }

    func testVendoredKeychainServiceAndHelperUseKeelNames() {
        XCTAssertEqual(KeychainHostSecretStore.service, "Keel SSH Host")
        XCTAssertEqual(AskpassBroker.helperName, "keel-askpass")
        XCTAssertTrue(AskpassProtocol.socketVariable.hasPrefix("SSH_ASKPASS_KEEL_"))
        XCTAssertTrue(AskpassProtocol.nonceVariable.hasPrefix("SSH_ASKPASS_KEEL_"))
    }
}
