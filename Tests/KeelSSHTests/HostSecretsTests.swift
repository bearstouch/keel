import XCTest
@testable import KeelSSH

/// The saved password's binding to the host's connection revision (FR-CN06, KEEL-010 AC4).
final class HostSecretsTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)

    private func savedHost() async throws -> (HostLibrary, MemoryHostSecrets, SavedHost) {
        let secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: MemoryHostStorage(), secrets: secrets)
        let host = try await library.create(HostDraft(name: "Bastion", destination: "bastion", user: "deploy"))
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        return (library, secrets, saved)
    }

    func testDestinationChangeDeletesPassword() async throws {
        let (library, secrets, host) = try await savedHost()
        let lookup = try XCTUnwrap(library.savedPassword(for: host, gate: FixedGate(allow: true)))
        let before = await lookup()
        XCTAssertEqual(before, secret)
        let moved = try await library.update(id: host.id, HostDraft(name: "Bastion", destination: "bastion-2", user: "deploy"), expectedRevision: host.revision)
        XCTAssertNil(moved.savedPassword)
        XCTAssertNil(secrets[host.id], "The Keychain item is deleted")
        XCTAssertGreaterThan(moved.connectionRevision, host.connectionRevision)
        let after = await lookup()
        XCTAssertNil(after, "A tunnel started for the old destination gets nothing")
        XCTAssertNil(library.savedPassword(for: moved, gate: FixedGate(allow: true)), "Nothing to offer the new destination")
    }

    func testRenameKeepsPasswordAndLookup() async throws {
        let (library, _, host) = try await savedHost()
        let lookup = try XCTUnwrap(library.savedPassword(for: host, gate: FixedGate(allow: true)))
        _ = try await library.update(id: host.id, HostDraft(name: "Bastion (prod)", destination: "bastion", user: "deploy"), expectedRevision: host.revision)
        let value = await lookup()
        XCTAssertEqual(value, secret)
    }

    func testDeclinedConfirmationReadsNothing() async throws {
        let secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: MemoryHostStorage(), secrets: secrets)
        let host = try await library.create(HostDraft(name: "Bastion", destination: "bastion"))
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: true), expectedRevision: host.revision)
        let value = await library.savedPassword(for: saved, gate: FixedGate(allow: false))?()
        XCTAssertNil(value)
        XCTAssertEqual(secrets.reads, 0)
    }
}
