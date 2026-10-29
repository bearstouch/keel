import Foundation
import KeelRESP
import Security

public enum TLSIdentityImportError: Error, Equatable, Sendable {
    case wrongPassphrase
    /// The key is encrypted and no passphrase was given.
    case passphraseRequired
    case unreadableCertificate
    case unreadableKey
    /// Readable but not importable; the text says why and what to do.
    case unsupportedKey(String)
    case keyDoesNotMatchCertificate
    /// The `.p12` holds certificates but no private key.
    case noIdentity
    /// A Keychain call failed with this OSStatus.
    case keychain(Int32)
}

/// A client identity now in the login Keychain, not yet saved with any profile. `ProfileStore` saves it
/// (`create(…identity:)`, `update(…identity:)`); until then its owner discards it if it isn't kept.
public struct ImportedTLSIdentity: Sendable, Equatable {
    /// The identity's persistent reference: the only thing a profile keeps (INT-05).
    public var reference: Data
    /// The certificate's subject summary, for the profile editor ("keel-client").
    public var summary: String
    /// False when the identity was in the Keychain before this import: Keel never removes it then.
    public var isNew: Bool
    /// The passphrase the user typed for the key or `.p12`; saved only in `Keel TLS`.
    let passphrase: String?
}

/// What `Keel TLS` / `<profile-uuid>` holds (02 Architecture → Keychain): the identity's persistent reference and
/// the passphrase the user typed for the key or `.p12`. `addedByKeel` records that one of Keel's imports put the
/// identity in the Keychain, so Keel may remove it once no profile uses it; nil (older items) never removes it.
struct TLSIdentitySecret: Codable, Equatable {
    var identity: Data
    var passphrase: String?
    var addedByKeel: Bool?
}

/// Imports client certificates for TLS profiles (FR-CN03, INT-05): a `.p12`, or a PEM/DER certificate plus a PEM
/// PKCS#8, PKCS#1 or SEC1 key (encrypted PKCS#8 keys need their passphrase).
///
/// Every input is decoded and checked in memory first, so a wrong passphrase, a key that doesn't match its
/// certificate or an unreadable file changes nothing. Only then is the identity added to the login Keychain. The
/// importer never writes `Keel TLS`: `ProfileStore` is its single writer, and `discard(_:)` removes an import that
/// no profile kept.
public struct TLSIdentityImporter: Sendable {
    public static let service = "Keel TLS"
    private let keychain: any TLSIdentityKeychain

    public init(keychain: any TLSIdentityKeychain = SystemTLSIdentityKeychain()) { self.keychain = keychain }

    public func importPKCS12(_ data: Data, passphrase: String) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        // macOS 14 can only decode a .p12 by importing it, which SecPKCS12Import does atomically.
        let certificate: SecCertificate?
        if #available(macOS 15, *) { certificate = try Self.decodePKCS12(data, passphrase: passphrase) } else { certificate = nil }
        return try add(data, passphrase: passphrase, storedPassphrase: passphrase, certificate: certificate)
    }

    public func importPEM(certificate: Data, privateKey: Data, passphrase: String?) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        let certificateDER = PEM.blocks(in: certificate).first { $0.label == "CERTIFICATE" }?.der ?? certificate
        guard let parsed = SecCertificateCreateWithData(nil, certificateDER as CFData) else { throw .unreadableCertificate }
        let pkcs8 = try PrivateKeyDecoder.pkcs8(from: privateKey, passphrase: passphrase, certificate: parsed)
        // A one-time passphrase protects the bundle only between here and the Keychain.
        let transport = PBES2.random(24).map { String(format: "%02x", $0) }.joined()
        guard let bundle = PKCS12Builder.build(certificate: Array(certificateDER), pkcs8: pkcs8, passphrase: transport) else { throw .keychain(errSecInternalComponent) }
        if #available(macOS 15, *) { _ = try Self.decodePKCS12(bundle, passphrase: transport) }
        return try add(bundle, passphrase: transport, storedPassphrase: passphrase.flatMap { $0.isEmpty ? nil : $0 }, certificate: parsed)
    }

    /// An import no profile kept (the sheet was cancelled, or another file replaced it): removed if it added the
    /// identity, left alone if the identity was already in the Keychain.
    public func discard(_ identity: ImportedTLSIdentity) { if identity.isNew { keychain.removeIdentity(reference: identity.reference) } }

    /// Removes an identity (certificate and private key) from the Keychain; best effort. `ProfileStore` calls it for
    /// one Keel added once no profile uses it.
    public func removeIdentity(reference: Data) { keychain.removeIdentity(reference: reference) }

    /// The subject summary of the profile's identity, for the editor; nil when it has none or it left the Keychain.
    public func subject(profileID: UUID) -> String? {
        guard let found = try? clientIdentity(profileID: profileID), let certificate = found.identity.certificate else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    /// The profile's identity for `TLSConfiguration.clientIdentity`; nil when it has none or the item is gone.
    public func clientIdentity(profileID: UUID) throws(TLSIdentityImportError) -> TLSClientIdentity? {
        guard let secret = try secret(profileID: profileID) else { return nil }
        return keychain.identity(reference: secret.identity).map(TLSClientIdentity.init)
    }

    /// The passphrase saved with the profile's identity, if any.
    public func passphrase(profileID: UUID) throws(TLSIdentityImportError) -> String? { try secret(profileID: profileID)?.passphrase }

    /// The profile's `Keel TLS` item; nil when there is none or it doesn't decode.
    private func secret(profileID: UUID) throws(TLSIdentityImportError) -> TLSIdentitySecret? {
        guard let data = try keychain.secret(service: Self.service, account: profileID.uuidString) else { return nil }
        return try? JSONDecoder().decode(TLSIdentitySecret.self, from: data)
    }

    private func add(_ bundle: Data, passphrase: String, storedPassphrase: String?, certificate: SecCertificate?) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        let added = try keychain.importPKCS12(bundle, passphrase: passphrase, certificate: certificate)
        return ImportedTLSIdentity(reference: added.reference, summary: added.summary, isNew: added.isNew, passphrase: storedPassphrase)
    }

    /// Decodes a `.p12` in memory only and returns its identity's certificate.
    @available(macOS 15, *)
    static func decodePKCS12(_ data: Data, passphrase: String) throws(TLSIdentityImportError) -> SecCertificate {
        let identity = try PKCS12Import.identity(data, options: [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true])
        guard let certificate = identity.certificate else { throw .noIdentity }
        return certificate
    }
}
