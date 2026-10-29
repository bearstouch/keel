import Foundation
@testable import KeelCore

/// An in-memory Keychain that records every call, so tests can check order and inject failures.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    enum Call: Equatable { case read(ProfileSecret, UUID), write(ProfileSecret, UUID), remove(ProfileSecret, UUID) }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var log: [Call] = []
    /// Shared with the persistence hook, so one timeline shows Keychain calls and metadata writes.
    let events: EventLog?
    private var failing: Set<String> = []

    init(events: EventLog? = nil) { self.events = events }

    private func key(_ secret: ProfileSecret, _ id: UUID) -> String { "\(secret.rawValue)/\(id.uuidString)" }

    func item(_ secret: ProfileSecret, _ id: UUID) -> Data? { lock.withLock { items[key(secret, id)] } }
    func seed(_ data: Data, _ secret: ProfileSecret, _ id: UUID) { lock.withLock { items[key(secret, id)] = data } }
    var calls: [Call] { lock.withLock { log } }
    var itemCount: Int { lock.withLock { items.count } }
    /// Makes writes (`"write"`), removals (`"remove"`) or reads (`"read"`) fail.
    func fail(_ operation: String, _ on: Bool = true) { lock.withLock { if on { failing.insert(operation) } else { failing.remove(operation) } } }

    private func check(_ operation: String) throws(SecretStoreError) {
        if lock.withLock({ failing.contains(operation) }) { throw .keychain(-25308) }
    }

    func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data? {
        try check("read")
        return lock.withLock {
            log.append(.read(secret, profileID)); return items[key(secret, profileID)]
        }
    }

    func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) {
        try check("write")
        lock.withLock {
            log.append(.write(secret, profileID)); items[key(secret, profileID)] = data
        }
        events?.append("keychain.write")
    }

    func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) {
        try check("remove")
        lock.withLock {
            log.append(.remove(secret, profileID)); items[key(secret, profileID)] = nil
        }
        events?.append("keychain.remove")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ event: String) { lock.withLock { stored.append(event) } }
    var events: [String] { lock.withLock { stored } }
    func reset() { lock.withLock { stored = [] } }
}

/// A switch the persistence hook reads: on, the metadata write fails just before its rename.
final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// A temporary state folder, a fake Keychain and a store over both.
struct ProfileFixture {
    let root: URL
    var directory: URL { root.appendingPathComponent("state", isDirectory: true) }
    let secrets: FakeSecretStore
    let events = EventLog()
    let failWrites = FailSwitch()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keel-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        secrets = FakeSecretStore(events: events)
    }

    /// A store whose metadata writes go through `Persistence` with the failure hook; already loaded.
    func store(removeTLSIdentity: @escaping @Sendable (Data) -> Void = { _ in }) async -> ProfileStore {
        let failWrites = failWrites, events = events
        let persistence = Persistence<ConnectionsDocument>(
            directory: directory,
            beforeReplace: { _ in
                if failWrites.isOn { throw POSIXError(.EIO) }
                events.append("metadata.write")
            })
        let store = ProfileStore(persistence: persistence, secrets: secrets, removeTLSIdentity: removeTLSIdentity)
        _ = await store.load()
        return store
    }

    var fileURL: URL { directory.appendingPathComponent("connections.json") }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

extension ImportedTLSIdentity {
    /// An identity as `TLSIdentityImporter` returns it; the reference names no real Keychain item.
    static func fake(_ name: String = "keel-client", isNew: Bool = true, passphrase: String? = nil) -> ImportedTLSIdentity {
        ImportedTLSIdentity(reference: Data("ref-\(name)".utf8), summary: name, isNew: isNew, passphrase: passphrase)
    }
}

extension ConnectionSettings {
    static func sample(_ name: String = "local", host: String = "127.0.0.1") -> ConnectionSettings { ConnectionSettings(name: name, host: host) }
}
