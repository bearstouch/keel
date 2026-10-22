import Foundation
import Security
import XCTest
@testable import KeelCore

/// The TLS fixtures in `Tests/Fixtures/TLS`; `.p12` and encrypted-key passphrase "keel-fixture".
enum TLSFixturePaths {
    static let passphrase = "keel-fixture"
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS/\(name)")
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// The fixture client identity, decoded in memory only (never in a keychain).
    static func memoryIdentity() throws -> SecIdentity? {
        guard #available(macOS 15, *) else { throw XCTSkip("in-memory PKCS#12 decoding needs macOS 15") }
        var items: CFArray?
        guard SecPKCS12Import(try data("client.p12") as CFData, [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true] as CFDictionary, &items) == errSecSuccess,
            let found = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String]
        else { return nil }
        return (found as! SecIdentity)
    }

    static func certificate(_ name: String) throws -> SecCertificate {
        let der = try XCTUnwrap(TLSConfigurationLike.firstCertificate(try data(name)))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }
}

/// Reads the first PEM certificate without depending on KeelRESP's test target.
private enum TLSConfigurationLike {
    static func firstCertificate(_ pem: Data) -> Data? {
        let text = String(decoding: pem, as: UTF8.self)
        guard let body = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first?.components(separatedBy: "-----END CERTIFICATE-----").first else { return nil }
        return Data(base64Encoded: body.filter { !$0.isWhitespace })
    }
}

/// An in-memory Keychain. Imports are decoded (memory-only) to prove each bundle really holds the identity.
final class FakeTLSKeychain: TLSIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Data: SecIdentity] = [:]
    private var secrets: [String: Data] = [:]
    private var removedReferences: [Data] = []
    var failSecretWrites = false
    var preexisting = false

    var importCount: Int { lock.withLock { identities.count } }
    var secretCount: Int { lock.withLock { secrets.count } }
    var removed: [Data] { lock.withLock { removedReferences } }
    func storedSecret(_ account: String) -> Data? { lock.withLock { secrets["Keel TLS/\(account)"] } }

    func importPKCS12(_ data: Data, passphrase: String, certificate: SecCertificate?) throws(TLSIdentityImportError) -> KeychainIdentity {
        guard #available(macOS 15, *) else { throw .keychain(errSecUnimplemented) }
        var items: CFArray?
        switch SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true] as CFDictionary, &items) {
        case errSecSuccess: break
        case errSecAuthFailed: throw .wrongPassphrase
        case let status: throw .keychain(status)
        }
        guard let found = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String] else { throw .noIdentity }
        let identity = found as! SecIdentity
        let reference = Data(UUID().uuidString.utf8)
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        lock.withLock { identities[reference] = identity }
        return KeychainIdentity(reference: reference, isNew: !preexisting, summary: leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "")
    }

    func identity(reference: Data) -> SecIdentity? { lock.withLock { identities[reference] } }
    func removeIdentity(reference: Data) {
        lock.withLock {
            identities[reference] = nil; removedReferences.append(reference)
        }
    }
    func secret(service: String, account: String) throws(TLSIdentityImportError) -> Data? { lock.withLock { secrets["\(service)/\(account)"] } }
    func setSecret(_ data: Data, service: String, account: String) throws(TLSIdentityImportError) {
        if failSecretWrites { throw .keychain(errSecIO) }
        lock.withLock { secrets["\(service)/\(account)"] = data }
    }
}

@available(macOS 15, *)
final class IdentityImporterTests: XCTestCase {
    private typealias F = TLSFixturePaths
    private let profile = UUID()

    private func leafSubject(_ identity: SecIdentity?) -> String? {
        var leaf: SecCertificate?
        guard let identity, SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }

    // MARK: - Story tests

    func testImportsP12AndPEMPairs() throws {
        let keychain = FakeTLSKeychain()
        let importer = TLSIdentityImporter(keychain: keychain)

        let p12 = try importer.importPKCS12(try F.data("client.p12"), passphrase: F.passphrase, profileID: profile)
        XCTAssertEqual(p12.summary, "keel-client")
        XCTAssertEqual(leafSubject(try importer.clientIdentity(profileID: profile)?.identity), "keel-client")
        let secret = try XCTUnwrap(keychain.storedSecret(profile.uuidString))
        XCTAssertEqual(try JSONDecoder().decode(TLSIdentitySecret.self, from: secret), TLSIdentitySecret(identity: p12.reference, passphrase: F.passphrase))
        XCTAssertEqual(try importer.passphrase(profileID: profile), F.passphrase)

        // PEM certificate + every supported key shape; each lands as an identity whose certificate is the input.
        let pairs: [(certificate: String, key: String, passphrase: String?, subject: String)] = [
            ("client.pem", "client.key", nil, "keel-client"),  // PKCS#8
            ("client.pem", "client-pkcs1.key", nil, "keel-client"),  // PKCS#1
            ("client.pem", "client-encrypted.key", F.passphrase, "keel-client"),  // PBES2 / AES-256
            ("client-ec.pem", "client-ec.key", nil, "keel-client-ec")  // EC P-256
        ]
        for (index, pair) in pairs.enumerated() {
            let id = UUID()
            let imported = try importer.importPEM(certificate: try F.data(pair.certificate), privateKey: try F.data(pair.key), passphrase: pair.passphrase, profileID: id)
            XCTAssertEqual(imported.summary, pair.subject, pair.key)
            XCTAssertEqual(leafSubject(try importer.clientIdentity(profileID: id)?.identity), pair.subject, pair.key)
            XCTAssertEqual(keychain.importCount, index + 2)
            XCTAssertEqual(try importer.passphrase(profileID: id), pair.passphrase, "only the user's passphrase is saved, never the one-time one")
        }
        XCTAssertNil(try importer.clientIdentity(profileID: UUID()))
    }

    func testWrongPassphraseFailsWithoutPartialImport() throws {
        let keychain = FakeTLSKeychain()
        let importer = TLSIdentityImporter(keychain: keychain)

        XCTAssertThrowsError(try importer.importPKCS12(try F.data("client.p12"), passphrase: "wrong", profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .wrongPassphrase)
        }
        XCTAssertThrowsError(try importer.importPEM(certificate: try F.data("client.pem"), privateKey: try F.data("client-encrypted.key"), passphrase: "wrong", profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .wrongPassphrase)
        }
        XCTAssertThrowsError(try importer.importPEM(certificate: try F.data("client.pem"), privateKey: try F.data("client-encrypted.key"), passphrase: nil, profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .passphraseRequired)
        }
        XCTAssertThrowsError(try importer.importPEM(certificate: try F.data("client.pem"), privateKey: try F.data("server.key"), passphrase: nil, profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .keyDoesNotMatchCertificate)
        }
        XCTAssertThrowsError(try importer.importPEM(certificate: try F.data("client.key"), privateKey: try F.data("client.key"), passphrase: nil, profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .unreadableCertificate)
        }
        XCTAssertThrowsError(try importer.importPEM(certificate: try F.data("client.pem"), privateKey: try F.data("client.pem"), passphrase: nil, profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .unreadableKey)
        }
        XCTAssertEqual(keychain.importCount, 0)
        XCTAssertEqual(keychain.secretCount, 0)
        XCTAssertNil(try importer.clientIdentity(profileID: profile))
    }

    // MARK: - Rollback and formats

    func testFailedSecretWriteRemovesOnlyANewIdentity() throws {
        let keychain = FakeTLSKeychain()
        keychain.failSecretWrites = true
        let importer = TLSIdentityImporter(keychain: keychain)
        XCTAssertThrowsError(try importer.importPKCS12(try F.data("client.p12"), passphrase: F.passphrase, profileID: profile)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .keychain(errSecIO))
        }
        XCTAssertEqual(keychain.importCount, 0)
        XCTAssertEqual(keychain.removed.count, 1)

        // An identity the user already had stays, even when the import fails.
        let existing = FakeTLSKeychain()
        existing.failSecretWrites = true; existing.preexisting = true
        XCTAssertThrowsError(try TLSIdentityImporter(keychain: existing).importPKCS12(try F.data("client.p12"), passphrase: F.passphrase, profileID: profile))
        XCTAssertEqual(existing.importCount, 1)
        XCTAssertTrue(existing.removed.isEmpty)
    }

    func testLegacyEncryptedPEMAsksForConversion() throws {
        let legacy = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,0011\n\nAAAA\n-----END RSA PRIVATE KEY-----\n"
        XCTAssertThrowsError(try TLSIdentityImporter(keychain: FakeTLSKeychain()).importPEM(certificate: try F.data("client.pem"), privateKey: Data(legacy.utf8), passphrase: "x", profileID: profile)) {
            guard case .unsupportedKey(let text)? = $0 as? TLSIdentityImportError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("openssl pkcs8 -topk8"), text)
        }
    }

    func testPKCS12KDFMatchesKnownAnswer() {
        // RFC 7292 B.2 with SHA-256 (id 3, 2048 rounds); the reference value comes from an independent
        // implementation that reproduces OpenSSL's SHA-1 vector ("smeg", 0A58CF64530D823F → 8AAAE629…).
        let key = PKCS12Builder.kdf("keel", salt: Array("saltsaltsaltsalt".utf8), id: 3, iterations: 2_048, length: 32)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "9f86a656b67705fc7c493df14bfaf186f9ac2609e8f376d80f6db070eb625db5")
        XCTAssertNotEqual(key, PKCS12Builder.kdf("keel", salt: Array("saltsaltsaltsalt".utf8), id: 1, iterations: 2_048, length: 32))
    }
}

/// The real Keychain code against a throwaway keychain file, never the user's login keychain.
@available(macOS 15, *)
final class SystemTLSIdentityKeychainTests: XCTestCase {
    private var path = ""
    private var keychain: CFTypeRef?

    // `SecKeychainCreate` is the only way to make a throwaway file keychain; deprecated, so kept to tests.
    @available(macOS, deprecated: 12.0)
    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("keel-test-\(UUID().uuidString).keychain-db").path
        var created: SecKeychain?
        guard SecKeychainCreate(path, 4, "test", false, nil, &created) == errSecSuccess, let created else { throw XCTSkip("can't create a temporary keychain") }
        keychain = created
    }

    @available(macOS, deprecated: 12.0)
    override func tearDownWithError() throws {
        if let keychain { SecKeychainDelete((keychain as! SecKeychain)) }
        unlink(path)
    }

    func testImportsResolvesAndRemovesInFileKeychain() throws {
        let system = SystemTLSIdentityKeychain(keychain: try XCTUnwrap(keychain))
        let importer = TLSIdentityImporter(keychain: system)
        let profile = UUID()

        let imported = try importer.importPEM(
            certificate: try TLSFixturePaths.data("client-ec.pem"), privateKey: try TLSFixturePaths.data("client-ec.key"), passphrase: nil, profileID: profile)
        XCTAssertEqual(imported.summary, "keel-client-ec")
        let identity = try XCTUnwrap(try importer.clientIdentity(profileID: profile)?.identity)
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &key), errSecSuccess, "the private key is in the keychain")

        // The p12 path, and a re-import of an identity that is already there (not new, so never rolled back).
        let p12 = try system.importPKCS12(try TLSFixturePaths.data("client.p12"), passphrase: TLSFixturePaths.passphrase, certificate: try TLSFixturePaths.certificate("client.pem"))
        XCTAssertTrue(p12.isNew)
        let again = try system.importPKCS12(try TLSFixturePaths.data("client.p12"), passphrase: TLSFixturePaths.passphrase, certificate: try TLSFixturePaths.certificate("client.pem"))
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.reference, p12.reference)
        XCTAssertThrowsError(try system.importPKCS12(try TLSFixturePaths.data("client.p12"), passphrase: "wrong", certificate: nil)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .wrongPassphrase)
        }

        system.removeIdentity(reference: p12.reference)
        XCTAssertNil(system.identity(reference: p12.reference))
        XCTAssertNotNil(system.identity(reference: imported.reference))

        // Secrets update in place.
        try system.setSecret(Data("a".utf8), service: TLSIdentityImporter.service, account: "x")
        try system.setSecret(Data("b".utf8), service: TLSIdentityImporter.service, account: "x")
        XCTAssertEqual(try system.secret(service: TLSIdentityImporter.service, account: "x"), Data("b".utf8))
        XCTAssertNil(try system.secret(service: TLSIdentityImporter.service, account: "missing"))
    }
}
