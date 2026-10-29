import XCTest

@testable import KeelCore

/// The identities `ProfileStore` asked to remove from the Keychain.
private final class RemovedIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    func append(_ reference: Data) { lock.withLock { stored.append(reference) } }
    var references: [Data] { lock.withLock { stored } }
}

/// FR-CN03 / INT-05: `ProfileStore` is the single writer of `Keel TLS`, sets `hasTLSSecret`, and lets go of an
/// identity Keel's import added once no profile uses it.
final class TLSIdentityStoreTests: XCTestCase {
    private var fixture: ProfileFixture!
    private let removed = RemovedIdentities()

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    private func store() async -> ProfileStore {
        let removed = removed
        return await fixture.store(removeTLSIdentity: { removed.append($0) })
    }

    private func saved(_ id: UUID) throws -> TLSIdentitySecret? {
        try fixture.secrets.item(.tls, id).map { try JSONDecoder().decode(TLSIdentitySecret.self, from: $0) }
    }

    func testCreateSavesTheIdentityKeychainFirst() async throws {
        let store = await store()
        let identity = ImportedTLSIdentity.fake(passphrase: "key-pass")
        fixture.events.reset()
        let profile = try await store.create(ConnectionSettings(name: "tls", tls: TLSSettings()), identity: identity)
        XCTAssertTrue(profile.hasTLSSecret)
        XCTAssertEqual(try saved(profile.id), TLSIdentitySecret(identity: identity.reference, passphrase: "key-pass", addedByKeel: true))
        XCTAssertEqual(fixture.events.events, ["keychain.write", "metadata.write"])
        let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("key-pass"))
    }

    func testReimportReplacesAndRemovesTheOldIdentity() async throws {
        let store = await store()
        let first = ImportedTLSIdentity.fake("first"), second = ImportedTLSIdentity.fake("second")
        let profile = try await store.create(.sample(), identity: first)
        let updated = try await store.update(profile.id, profile.settings, identity: .set(second), expectedRevision: profile.revision)
        XCTAssertTrue(updated.hasTLSSecret)
        XCTAssertEqual(try saved(profile.id)?.identity, second.reference)
        XCTAssertEqual(removed.references, [first.reference], "the replaced identity's key leaves the Keychain")
    }

    func testReimportingTheSameIdentityKeepsItAndItsOwnership() async throws {
        let store = await store()
        let first = ImportedTLSIdentity.fake("same")
        let profile = try await store.create(.sample(), identity: first)
        // The identity is in the Keychain now, so the second import reports it as not new.
        let again = ImportedTLSIdentity.fake("same", isNew: false)
        let updated = try await store.update(profile.id, profile.settings, identity: .set(again), expectedRevision: profile.revision)
        XCTAssertTrue(removed.references.isEmpty)
        XCTAssertEqual(try saved(profile.id)?.addedByKeel, true)
        _ = try await store.update(profile.id, profile.settings, identity: .remove, expectedRevision: updated.revision)
        XCTAssertEqual(removed.references, [first.reference])
    }

    func testRemoveClearsTheItemAndTheFlag() async throws {
        let store = await store()
        let identity = ImportedTLSIdentity.fake()
        let profile = try await store.create(.sample(), identity: identity)
        let updated = try await store.update(profile.id, profile.settings, identity: .remove, expectedRevision: profile.revision)
        XCTAssertFalse(updated.hasTLSSecret)
        XCTAssertNil(fixture.secrets.item(.tls, profile.id))
        XCTAssertEqual(removed.references, [identity.reference])
        // Removing nothing is no change.
        let again = try await store.update(profile.id, profile.settings, identity: .remove, expectedRevision: updated.revision)
        XCTAssertEqual(again, updated)
    }

    func testAnIdentityKeelDidNotAddIsNeverRemoved() async throws {
        let store = await store()
        let profile = try await store.create(.sample(), identity: .fake("users-own", isNew: false))
        let updated = try await store.update(profile.id, profile.settings, identity: .set(.fake("next")), expectedRevision: profile.revision)
        try await store.delete(profile.id, expectedRevision: updated.revision)
        XCTAssertEqual(removed.references, [ImportedTLSIdentity.fake("next").reference], "only the identity Keel added goes")
    }

    func testFailedMetadataWriteRestoresThePreviousIdentity() async throws {
        let store = await store()
        let first = ImportedTLSIdentity.fake("first")
        let profile = try await store.create(.sample(), identity: first)
        let before = fixture.secrets.item(.tls, profile.id)
        fixture.failWrites.isOn = true
        do {
            _ = try await store.update(profile.id, profile.settings, identity: .set(.fake("second")), expectedRevision: profile.revision)
            XCTFail("The write must fail")
        } catch {}
        XCTAssertEqual(fixture.secrets.item(.tls, profile.id), before)
        XCTAssertTrue(removed.references.isEmpty, "nothing leaves the Keychain before the metadata is saved")
        let stored = await store.profile(profile.id)
        XCTAssertEqual(stored, profile)
    }

    func testDuplicatesShareAnIdentityUntilTheLastOneGoes() async throws {
        let store = await store()
        let identity = ImportedTLSIdentity.fake()
        let profile = try await store.create(.sample(), identity: identity)
        let copy = try await store.duplicate(profile.id)
        XCTAssertTrue(copy.hasTLSSecret)
        XCTAssertEqual(try saved(copy.id)?.identity, identity.reference)
        try await store.delete(profile.id)
        XCTAssertTrue(removed.references.isEmpty, "the copy still uses it")
        try await store.delete(copy.id)
        XCTAssertEqual(removed.references, [identity.reference])
        XCTAssertEqual(fixture.secrets.itemCount, 0)
    }

    func testKeychainFailureSavesNothing() async throws {
        let store = await store()
        let profile = try await store.create(.sample())
        fixture.secrets.fail("write")
        do {
            _ = try await store.update(profile.id, profile.settings, identity: .set(.fake()), expectedRevision: profile.revision)
            XCTFail("The Keychain must fail")
        } catch { XCTAssertEqual(error, .secretStore(.keychain(-25308))) }
        let stored = await store.profile(profile.id)
        XCTAssertEqual(stored?.hasTLSSecret, false)
    }
}
