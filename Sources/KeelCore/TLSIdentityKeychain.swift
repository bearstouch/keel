import Foundation
import Security

/// An identity the Keychain now holds.
public struct KeychainIdentity: Sendable, Equatable {
    public var reference: Data
    /// False when the certificate was in the Keychain before this import, so a rollback must leave it alone.
    public var isNew: Bool
    public var summary: String

    public init(reference: Data, isNew: Bool, summary: String) { self.reference = reference; self.isNew = isNew; self.summary = summary }
}

/// The Keychain calls TLS identity import needs, injectable so tests never touch the user's Keychain.
public protocol TLSIdentityKeychain: Sendable {
    /// Imports a PKCS#12 into the login Keychain. `certificate`, when known, decides `isNew`; without it the
    /// identity counts as pre-existing, so it is never removed by a rollback.
    func importPKCS12(_ data: Data, passphrase: String, certificate: SecCertificate?) throws(TLSIdentityImportError) -> KeychainIdentity
    func identity(reference: Data) -> SecIdentity?
    /// Removes the identity's certificate and private key; best effort.
    func removeIdentity(reference: Data)
    func secret(service: String, account: String) throws(TLSIdentityImportError) -> Data?
    func setSecret(_ data: Data, service: String, account: String) throws(TLSIdentityImportError)
}

/// The login Keychain. Generic passwords are *when unlocked, this device only* (02 Architecture → Keychain).
/// Keel never writes the system keychain or changes trust settings (INT-05).
public struct SystemTLSIdentityKeychain: TLSIdentityKeychain {
    /// A `SecKeychain` to use instead of the login keychain; tests pass a throwaway one.
    private let target: Target?

    private struct Target: @unchecked Sendable { let keychain: CFTypeRef }

    public init() { target = nil }

    /// `keychain` is a `SecKeychain`, typed loosely because that type is deprecated.
    init(keychain: CFTypeRef) { target = Target(keychain: keychain) }

    /// Searches are confined to the target keychain, when there is one.
    private func query(_ attributes: [CFString: Any]) -> CFDictionary {
        var query = attributes
        if let target { query[kSecMatchSearchList] = [target.keychain] }
        return query as CFDictionary
    }

    public func importPKCS12(_ data: Data, passphrase: String, certificate: SecCertificate?) throws(TLSIdentityImportError) -> KeychainIdentity {
        let existed = certificate.map(contains) ?? true
        var options: [CFString: Any] = [kSecImportExportPassphrase: passphrase]
        if let target { options[kSecImportExportKeychain] = target.keychain }
        // On macOS this imports into the default (login) keychain; re-importing an identity already there succeeds.
        let found = try PKCS12Import.identity(data, options: options)
        guard let leaf = found.certificate, let reference = persistentReference(for: leaf) else {
            // Imported but unreachable by reference: no profile could point at it, so a new one doesn't stay.
            if !existed { SecItemDelete(query([kSecClass: kSecClassIdentity, kSecValueRef: found])) }
            throw .keychain(errSecItemNotFound)
        }
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? "Client certificate"
        return KeychainIdentity(reference: reference, isNew: !existed, summary: summary)
    }

    /// The persistent reference of the identity holding `certificate`. It must come from an identity search: the
    /// reference returned for a `kSecValueRef` lookup names the certificate item and doesn't resolve as an identity.
    private func persistentReference(for certificate: SecCertificate) -> Data? {
        var result: CFTypeRef?
        let search = query([kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true, kSecReturnPersistentRef: true])
        guard SecItemCopyMatching(search, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        let wanted = SecCertificateCopyData(certificate) as Data
        let match = items.first { item in
            PKCS12Import.asIdentity(item[kSecValueRef as String])?.certificate.map { SecCertificateCopyData($0) as Data } == wanted
        }
        return match?[kSecValuePersistentRef as String] as? Data
    }

    /// Whether the keychain already holds this certificate (alone or as part of an identity). Compared by bytes: a
    /// `kSecValueRef` query also "finds" a certificate that only exists in memory.
    private func contains(_ certificate: SecCertificate) -> Bool {
        var result: CFTypeRef?
        let search = query([kSecClass: kSecClassCertificate, kSecMatchLimit: kSecMatchLimitAll, kSecReturnData: true])
        guard SecItemCopyMatching(search, &result) == errSecSuccess, let stored = result as? [Data] else { return false }
        return stored.contains(SecCertificateCopyData(certificate) as Data)
    }

    public func identity(reference: Data) -> SecIdentity? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(query([kSecClass: kSecClassIdentity, kSecValuePersistentRef: reference, kSecReturnRef: true]), &result) == errSecSuccess else { return nil }
        return PKCS12Import.asIdentity(result)
    }

    public func removeIdentity(reference: Data) {
        guard let identity = identity(reference: reference) else { return }
        // Deleting the identity removes both its certificate and its private key.
        SecItemDelete(query([kSecClass: kSecClassIdentity, kSecValueRef: identity]))
    }

    public func secret(service: String, account: String) throws(TLSIdentityImportError) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw .keychain(status)
        }
    }

    public func setSecret(_ data: Data, service: String, account: String) throws(TLSIdentityImportError) {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = SecItemUpdate(query(item), [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if let target { add[kSecUseKeychain] = target.keychain }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .keychain(status) }
    }
}

/// `SecPKCS12Import` shared by the in-memory check and the Keychain import, with its statuses as import errors.
enum PKCS12Import {
    /// The first identity in the `.p12`.
    static func identity(_ data: Data, options: [CFString: Any]) throws(TLSIdentityImportError) -> SecIdentity {
        var items: CFArray?
        switch SecPKCS12Import(data as CFData, options as CFDictionary, &items) {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw .wrongPassphrase
        case errSecDecode, errSecUnknownFormat: throw .unreadableKey
        case let status: throw .keychain(status)
        }
        guard let identity = asIdentity((items as? [[String: Any]])?.lazy.compactMap({ $0[kSecImportItemIdentity as String] }).first) else { throw .noIdentity }
        return identity
    }

    /// `value` as a `SecIdentity`, checked by CF type ID (a conditional cast to a CF type always succeeds).
    static func asIdentity(_ value: Any?) -> SecIdentity? {
        guard let value, CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
        return (value as! SecIdentity)  // type checked above
    }
}

extension SecIdentity {
    var certificate: SecCertificate? {
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(self, &certificate) == errSecSuccess ? certificate : nil
    }
}
