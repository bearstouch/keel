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

/// A client identity now in the login Keychain.
public struct ImportedTLSIdentity: Sendable, Equatable {
    /// The identity's persistent reference: the only thing a profile keeps (INT-05).
    public var reference: Data
    /// The certificate's subject summary, for the profile editor ("keel-client").
    public var summary: String
}

/// What `Keel TLS` / `<profile-uuid>` holds (02 Architecture → Keychain): the identity's persistent reference and
/// the passphrase the user typed for the key or `.p12`.
struct TLSIdentitySecret: Codable, Equatable {
    var identity: Data
    var passphrase: String?
}

/// Imports client certificates for TLS profiles (FR-CN03, INT-05): a `.p12`, or a PEM/DER certificate plus a PEM
/// PKCS#8, PKCS#1 or SEC1 key (encrypted PKCS#8 keys need their passphrase).
///
/// Every input is decoded and checked in memory first, so a wrong passphrase, a key that doesn't match its
/// certificate or an unreadable file changes nothing. Only then is the identity added to the login Keychain and
/// the secret written; if the secret can't be written, an identity this import added is removed again.
public struct TLSIdentityImporter: Sendable {
    public static let service = "Keel TLS"
    private let keychain: any TLSIdentityKeychain

    public init(keychain: any TLSIdentityKeychain = SystemTLSIdentityKeychain()) { self.keychain = keychain }

    public func importPKCS12(_ data: Data, passphrase: String, profileID: UUID) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        // macOS 14 can only decode a .p12 by importing it, which SecPKCS12Import does atomically.
        let certificate: SecCertificate?
        if #available(macOS 15, *) { certificate = try Self.decodePKCS12(data, passphrase: passphrase) } else { certificate = nil }
        return try store(data, passphrase: passphrase, storedPassphrase: passphrase, certificate: certificate, profileID: profileID)
    }

    public func importPEM(certificate: Data, privateKey: Data, passphrase: String?, profileID: UUID) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        let certificateDER = PEM.blocks(in: certificate).first { $0.label == "CERTIFICATE" }?.der ?? certificate
        guard let parsed = SecCertificateCreateWithData(nil, certificateDER as CFData) else { throw .unreadableCertificate }
        let pkcs8 = try PrivateKeyDecoder.pkcs8(from: privateKey, passphrase: passphrase, certificate: parsed)
        // A one-time passphrase protects the bundle only between here and the Keychain.
        let transport = PBES2.random(24).map { String(format: "%02x", $0) }.joined()
        guard let bundle = PKCS12Builder.build(certificate: Array(certificateDER), pkcs8: pkcs8, passphrase: transport) else { throw .keychain(errSecInternalComponent) }
        if #available(macOS 15, *) { _ = try Self.decodePKCS12(bundle, passphrase: transport) }
        return try store(bundle, passphrase: transport, storedPassphrase: passphrase.flatMap { $0.isEmpty ? nil : $0 }, certificate: parsed, profileID: profileID)
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

    private func store(_ bundle: Data, passphrase: String, storedPassphrase: String?, certificate: SecCertificate?, profileID: UUID) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        let added = try keychain.importPKCS12(bundle, passphrase: passphrase, certificate: certificate)
        do {
            let secret = try JSONEncoder().encode(TLSIdentitySecret(identity: added.reference, passphrase: storedPassphrase))
            try keychain.setSecret(secret, service: Self.service, account: profileID.uuidString)
        } catch {
            // Never leave an identity behind that no profile points at, unless it was in the Keychain already.
            if added.isNew { keychain.removeIdentity(reference: added.reference) }
            throw error as? TLSIdentityImportError ?? .keychain(errSecInternalComponent)
        }
        return ImportedTLSIdentity(reference: added.reference, summary: added.summary)
    }

    /// Decodes a `.p12` in memory only and returns its identity's certificate.
    @available(macOS 15, *)
    static func decodePKCS12(_ data: Data, passphrase: String) throws(TLSIdentityImportError) -> SecCertificate {
        let identity = try PKCS12Import.identity(data, options: [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true])
        guard let certificate = identity.certificate else { throw .noIdentity }
        return certificate
    }
}
