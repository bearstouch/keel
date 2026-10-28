import Foundation
import KeelRESP
import KeelSSH
import Security
import os

/// Where this launch keeps its secrets. A `--fixture` run is throwaway: its passwords live in memory and end with
/// the process, so nothing it saves is orphaned in the login Keychain and nothing there (the installed app's items
/// included) is read or removed by it. A `SecIdentity` needs a keychain, so a fixture run refuses client-certificate
/// imports with a message (`NoTLSIdentityKeychain`) and connects without one.
public struct LaunchSecrets: Sendable {
    /// False for a fixture run: Help → Remove Keel Data… then plans no Keychain items (MAC-22).
    public let usesKeychain: Bool
    /// `Keel Connection` and `Keel TLS` for the profile store.
    public let profiles: any SecretStore
    /// `Keel SSH Host` for the saved-host library.
    public let hosts: any HostSecretStore
    /// Client-certificate import, lookup and removal (FR-CN03).
    public let identities: TLSIdentityImporter

    public init(arguments: LaunchArguments) {
        usesKeychain = !arguments.fixture
        if usesKeychain {
            profiles = KeychainSecretStore(); hosts = KeychainHostSecretStore(); identities = TLSIdentityImporter()
        } else {
            profiles = InMemorySecretStore(); hosts = InMemoryHostSecretStore(); identities = TLSIdentityImporter(keychain: NoTLSIdentityKeychain())
        }
    }

    /// The profile's TLS client identity for Test and connect.
    public var clientIdentity: @Sendable (UUID) -> TLSClientIdentity? { { [identities] in try? identities.clientIdentity(profileID: $0) } }
}

/// The TLS keychain of a `--fixture` run: there is none. Imports are refused after the in-memory checks (so a wrong
/// passphrase still says so), nothing is found and nothing is removed.
public struct NoTLSIdentityKeychain: TLSIdentityKeychain {
    public static let message = "A --fixture run never uses the Keychain, so client certificates can't be imported. Run Keel without --fixture to use one."

    public init() {}
    public func importPKCS12(_ data: Data, passphrase: String, certificate: SecCertificate?) throws(TLSIdentityImportError) -> KeychainIdentity {
        throw .unsupportedKey(Self.message)
    }
    public func identity(reference: Data) -> SecIdentity? { nil }
    public func removeIdentity(reference: Data) {}
    public func secret(service: String, account: String) throws(TLSIdentityImportError) -> Data? { nil }
    public func setSecret(_ data: Data, service: String, account: String) throws(TLSIdentityImportError) { throw .unsupportedKey(Self.message) }
}

/// Profile secrets held for this process only (a fixture run's Keychain).
public final class InMemorySecretStore: SecretStore, Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [String: Data]())

    public init() {}

    private static func key(_ secret: ProfileSecret, _ id: UUID) -> String { "\(secret.rawValue)/\(id.uuidString)" }
    public func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data? { items.withLock { $0[Self.key(secret, profileID)] } }
    public func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) { items.withLock { $0[Self.key(secret, profileID)] = data } }
    public func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) { items.withLock { $0[Self.key(secret, profileID)] = nil } }
}

/// Saved-host passwords held for this process only (a fixture run's Keychain).
public final class InMemoryHostSecretStore: HostSecretStore, Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [UUID: Data]())

    public init() {}

    public func store(_ password: Data, hostID: UUID) throws { items.withLock { $0[hostID] = password } }
    public func read(hostID: UUID) throws -> Data? { items.withLock { $0[hostID] } }
    public func remove(hostID: UUID) { _ = items.withLock { $0.removeValue(forKey: hostID) } }
}
