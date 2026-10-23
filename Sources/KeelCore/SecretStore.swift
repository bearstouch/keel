import Foundation
import Security

/// The Keychain services a profile owns (02 Architecture → Keychain items). The account is the profile's UUID.
public enum ProfileSecret: String, CaseIterable, Sendable {
    /// The Redis password (ACL or `requirepass`).
    case password = "Keel Connection"
    /// The client identity's persistent reference and key passphrase (`TLSIdentityImporter`).
    case tls = "Keel TLS"
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed with this OSStatus (locked, denied, unavailable).
    case keychain(Int32)
}

/// Keychain boundary for profile secrets, injectable so tests never touch the user's Keychain. Values are raw bytes;
/// they are never logged or persisted anywhere else.
public protocol SecretStore: Sendable {
    func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data?
    /// Adds or replaces the item.
    func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError)
    /// Removes the item; a missing item is not an error.
    func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError)
}

/// Generic passwords in the login Keychain, *when unlocked, this device only*.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    private func query(_ secret: ProfileSecret, _ profileID: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: secret.rawValue, kSecAttrAccount: profileID.uuidString]
    }

    public func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data? {
        var item = query(secret, profileID)
        item[kSecReturnData] = true; item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw .keychain(status) }
        return data
    }

    public func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) {
        let status = SecItemUpdate(query(secret, profileID) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw .keychain(status) }
        var item = query(secret, profileID)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel] = secret == .password ? "Keel connection password" : "Keel TLS client identity"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw .keychain(added) }
    }

    public func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) {
        let status = SecItemDelete(query(secret, profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }
}
