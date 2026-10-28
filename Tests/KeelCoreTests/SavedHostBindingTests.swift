import KeelSSH
import XCTest

@testable import KeelCore

/// The saved SSH hosts a store resolves, editable mid-test like `HostLibrary`.
private final class HostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [UUID: SavedHost] = [:]
    subscript(id: UUID) -> SavedHost? {
        get { lock.withLock { hosts[id] } }
        set { lock.withLock { hosts[id] = newValue } }
    }
}

/// FR-CN21: a password saved through a saved SSH host is bound to what that host connects to.
final class SavedHostBindingTests: XCTestCase {
    private var fixture: ProfileFixture!
    private let hosts = HostBox()

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    private func host(_ id: UUID = UUID(), name: String = "ops", destination: String = "bastion-a", user: String = "", revision: UInt64 = 1) throws -> SavedHost {
        SavedHost(id: id, draft: try HostDraft(name: name, destination: destination, user: user).validated(isRegularFile: { _ in true }), revision: revision)
    }

    private func store() async -> ProfileStore {
        let hosts = hosts
        let store = ProfileStore(persistence: Persistence(directory: fixture.directory), secrets: fixture.secrets, resolveSavedHost: { hosts[$0] })
        _ = await store.load()
        return store
    }

    private func tunneled(through hostID: UUID) -> ConnectionSettings { ConnectionSettings(name: "via ops", tunnel: .savedHost(id: hostID)) }

    func testRePointingTheSavedHostRefusesAndRemovesThePassword() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("secret".utf8))
        XCTAssertEqual(profile.savedHostBinding, SavedHostBinding(ops))
        let first = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertEqual(first, Data("secret".utf8))

        // Edit SSH Host: same id, another machine. The profile's own settings didn't change.
        hosts[ops.id] = try host(ops.id, destination: "bastion-b", revision: 2)
        let after = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertNil(after, "the old password never reaches the re-pointed host")
        XCTAssertNil(fixture.secrets.item(.password, profile.id), "the stale password is removed")
        let stored = await store.profile(profile.id)
        XCTAssertEqual(stored?.hasPassword, false)
        XCTAssertNil(stored?.savedHostBinding)
        XCTAssertEqual(stored?.revision, profile.revision, "an open editor keeps its revision")

        // Pointing the host back doesn't bring it back: the password is gone.
        hosts[ops.id] = ops
        let back = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertNil(back)
    }

    func testChangingTheUserAlsoRePointsTheHost() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("secret".utf8))
        hosts[ops.id] = try host(ops.id, user: "root", revision: 2)
        let after = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertNil(after)
    }

    func testRenamingTheSavedHostKeepsThePassword() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("secret".utf8))
        hosts[ops.id] = try host(ops.id, name: "Ops bastion", revision: 2)
        let after = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertEqual(after, Data("secret".utf8))
        XCTAssertEqual(fixture.secrets.item(.password, profile.id), Data("secret".utf8))
    }

    func testAGoneHostGetsNoPassword() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("secret".utf8))
        hosts[ops.id] = nil
        let after = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertNil(after)
    }

    func testANewPasswordBindsToTheHostAsItIsNow() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("old".utf8))
        let moved = try host(ops.id, destination: "bastion-b", revision: 2)
        hosts[ops.id] = moved
        // An edit that keeps the password keeps the binding it was saved with: still refused.
        var renamed = profile.settings; renamed.name = "renamed"
        let kept = try await store.update(profile.id, renamed, expectedRevision: profile.revision)
        XCTAssertEqual(kept.savedHostBinding, SavedHostBinding(ops))
        // Typing the password again binds it to the new machine.
        let updated = try await store.update(profile.id, renamed, password: .set(Data("new".utf8)), expectedRevision: kept.revision)
        XCTAssertEqual(updated.savedHostBinding, SavedHostBinding(moved))
        let after = try await store.password(profileID: profile.id, connectionRevision: updated.connectionRevision)
        XCTAssertEqual(after, Data("new".utf8))
    }

    func testAPasswordForAMissingHostIsRefusedBeforeTheKeychain() async throws {
        let store = await store()
        do {
            _ = try await store.create(tunneled(through: UUID()), password: Data("secret".utf8))
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual(error, .invalid(.tunnel)) }
        XCTAssertEqual(fixture.secrets.itemCount, 0)
        let profiles = await store.profiles
        XCTAssertTrue(profiles.isEmpty)
    }

    func testDuplicateAndRemovalCarryTheBinding() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let store = await store()
        let profile = try await store.create(tunneled(through: ops.id), password: Data("secret".utf8))
        let copy = try await store.duplicate(profile.id)
        XCTAssertEqual(copy.savedHostBinding, SavedHostBinding(ops))
        let removed = try await store.update(profile.id, profile.settings, password: .remove, expectedRevision: profile.revision)
        XCTAssertNil(removed.savedHostBinding)
    }

    /// A `connections.json` written before the binding existed: the first lookup binds to the host as it is, and a
    /// later re-point is caught.
    func testAProfileWithoutABindingAdoptsTheHostOnFirstUse() async throws {
        let ops = try host()
        hosts[ops.id] = ops
        let first = await store()
        let profile = try await first.create(tunneled(through: ops.id), password: Data("secret".utf8))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any])
        var records = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        records[0]["savedHostBinding"] = nil
        json["profiles"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.fileURL)

        let store = await store()
        let legacy = await store.profile(profile.id)
        XCTAssertNil(legacy?.savedHostBinding)
        let adopted = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertEqual(adopted, Data("secret".utf8))
        let bound = await store.profile(profile.id)
        XCTAssertEqual(bound?.savedHostBinding, SavedHostBinding(ops))
        hosts[ops.id] = try host(ops.id, destination: "bastion-b", revision: 2)
        let after = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertNil(after)
    }
}
