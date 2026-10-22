import Foundation
import Security
import XCTest
@testable import KeelRESP

/// Certificates in `Tests/Fixtures/TLS` (see `generate.sh`). Trust is evaluated at a fixed date inside every
/// fixture's validity, with revocation fetches off, so these tests never expire and never use the network.
enum TLSFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS")
    static let date = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static func ders(_ name: String) throws -> [Data] { try TLSConfiguration.certificates(fromPEM: data(name)) }

    /// A trust object for the chain in `name`, as a server would present it.
    static func trust(_ name: String) throws -> SecTrust {
        let chain = try ders(name).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, nil), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }
}

final class TLSConfigurationTests: XCTestCase {
    private typealias F = TLSFixtures

    private func evaluate(_ configuration: TLSConfiguration, _ chain: String, name: String?) throws -> TLSTrustFailure? {
        configuration.evaluate(try F.trust(chain), serverName: name, at: F.date)
    }

    // MARK: - Story tests

    func testAnchorOnlyTrustRejectsSystemRoots() throws {
        // A public chain (www.apple.com, captured 2026-10) verifies against the system roots by default...
        XCTAssertNil(try evaluate(TLSConfiguration(), "public-chain.pem", name: "www.apple.com"))
        // ...and is refused once a custom CA is selected: anchor-only trust never consults the system roots.
        let custom = TLSConfiguration(anchorCertificates: try F.ders("keel-ca.pem"))
        guard case .untrusted(let issuer, customCA: true)? = try evaluate(custom, "public-chain.pem", name: "www.apple.com") else { return XCTFail("system root was trusted") }
        XCTAssertFalse(issuer.isEmpty)

        // The private CA's server verifies only with that CA selected (AC1), and the refusal names the issuer.
        XCTAssertNil(try evaluate(custom, "server.pem", name: "redis.keel.test"))
        XCTAssertEqual(try evaluate(TLSConfiguration(), "server.pem", name: "redis.keel.test"), .untrusted(issuer: "Keel Fixture CA", customCA: false))
        let other = TLSConfiguration(anchorCertificates: try F.ders("other-ca.pem"))
        XCTAssertEqual(try evaluate(other, "server.pem", name: "redis.keel.test"), .untrusted(issuer: "Keel Fixture CA", customCA: true))
        // A bundle holding the right CA among others works.
        XCTAssertNil(try evaluate(TLSConfiguration(anchorCertificates: try F.ders("bundle.pem")), "server.pem", name: "redis.keel.test"))
    }

    func testSkipVerificationAcceptsAnyChain() throws {
        XCTAssertEqual(try evaluate(TLSConfiguration(), "self-signed.pem", name: "localhost"), .untrusted(issuer: "self-signed.keel.test", customCA: false))
        let skip = TLSConfiguration(skipVerification: true)
        XCTAssertNil(try evaluate(skip, "self-signed.pem", name: "localhost"))
        XCTAssertNil(try evaluate(skip, "server.pem", name: "not-the-name"))
        XCTAssertNil(try evaluate(TLSConfiguration(anchorCertificates: try F.ders("other-ca.pem"), skipVerification: true), "server.pem", name: nil))

        // Surfaced on the connection, so the UI can show "TLS not verified".
        let endpoint = RedisEndpoint.tcp(host: "127.0.0.1", port: 6380)
        XCTAssertEqual(RedisConnection(endpoint: endpoint, tls: skip).tlsVerified, false)
        XCTAssertEqual(RedisConnection(endpoint: endpoint, tls: TLSConfiguration()).tlsVerified, true)
        XCTAssertNil(RedisConnection(endpoint: endpoint).tlsVerified)
        XCTAssertFalse(TLSConfiguration().skipVerification, "verification is on by default (NFR-SC02)")
    }

    func testMinimumVersionIsTLS12() throws {
        XCTAssertEqual(TLSConfiguration.minimumVersion, .TLSv12)
        let host = TLSConfiguration().protocolSettings(for: .tcp(host: "cache.internal", port: 6380))
        XCTAssertEqual(host.minimumVersion, .TLSv12)
        XCTAssertEqual(host.sniName, "cache.internal")
        XCTAssertNil(host.clientIdentity)
        // IP literals are matched against the certificate but never sent as SNI (RFC 6066).
        XCTAssertNil(TLSConfiguration().protocolSettings(for: .tcp(host: "10.0.0.5", port: 6380)).sniName)
        XCTAssertNil(TLSConfiguration().protocolSettings(for: .tcp(host: "::1", port: 6380)).sniName)
        // The override wins for SNI and for matching, for IP hosts and tunnels alike.
        let override = TLSConfiguration(serverName: "redis.keel.test")
        XCTAssertEqual(override.protocolSettings(for: .tcp(host: "10.0.0.5", port: 6380)).sniName, "redis.keel.test")
        XCTAssertEqual(override.protocolSettings(for: .unixSocket(path: "/tmp/t.sock")).sniName, "redis.keel.test")
        XCTAssertEqual(override.protocolSettings(for: .unixSocket(path: "/tmp/t.sock")).minimumVersion, .TLSv12)
        _ = override.makeOptions(for: .tcp(host: "10.0.0.5", port: 6380), queue: DispatchQueue(label: "test")) { _ in }
    }

    // MARK: - Hostname and bundles

    func testHostnameMismatchListsCertificateNames() throws {
        let custom = TLSConfiguration(anchorCertificates: try F.ders("keel-ca.pem"))
        XCTAssertEqual(try evaluate(custom, "server.pem", name: "127.0.0.1"), .hostnameMismatch(expected: "127.0.0.1", certificateNames: ["redis.keel.test"]))
        XCTAssertNil(try evaluate(custom, "server.pem", name: "redis.keel.test"))
        // A Unix-socket endpoint without an override has nothing to match: fail closed.
        XCTAssertEqual(try evaluate(custom, "server.pem", name: nil), .noServerName)
        XCTAssertNil(custom.expectedName(for: .unixSocket(path: "/tmp/t.sock")))
        XCTAssertEqual(custom.expectedName(for: .tcp(host: "h", port: 1)), "h")
        XCTAssertEqual(TLSConfiguration(serverName: "").expectedName(for: .tcp(host: "h", port: 1)), "h", "an empty override means none")
    }

    func testBundleParsingFailsClosed() throws {
        XCTAssertEqual(try F.ders("bundle.pem").count, 2)
        XCTAssertThrowsError(try TLSConfiguration.certificates(fromPEM: try F.data("client.key"))) { XCTAssertEqual($0 as? TLSBundleError, .noCertificates) }
        let junk = Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)
        XCTAssertThrowsError(try TLSConfiguration.certificates(fromPEM: junk)) { XCTAssertEqual($0 as? TLSBundleError, .unreadableCertificate) }
        // Anchors that don't decode leave no anchors at all, never the system roots.
        XCTAssertEqual(try evaluate(TLSConfiguration(anchorCertificates: [Data([1, 2, 3])]), "public-chain.pem", name: "www.apple.com")?.isUntrusted, true)
    }

    func testPEMBlocksKeepLabelsAndHeaders() throws {
        let text = "junk\n-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAQID\n-----END RSA PRIVATE KEY-----\n-----BEGIN X-----\nAQ==\n-----END Y-----\n"
        let blocks = PEM.blocks(in: Data(text.utf8))
        XCTAssertEqual(blocks, [PEMBlock(label: "RSA PRIVATE KEY", headers: ["Proc-Type": "4,ENCRYPTED", "DEK-Info": "AES-128-CBC,00"], der: Data([1, 2, 3]))])
    }

    func testCertificateNamesAreSanitized() {
        XCTAssertEqual(TLSConfiguration.sanitized("evil\u{1B}[31m\nname"), "evil[31mname")
        XCTAssertEqual(TLSConfiguration.sanitized(String(repeating: "a", count: 500)).count, 128)
    }
}

extension TLSTrustFailure {
    var isUntrusted: Bool { if case .untrusted = self { true } else { false } }
}
