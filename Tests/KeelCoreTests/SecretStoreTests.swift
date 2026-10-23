import XCTest
@testable import KeelCore

final class SecretStoreTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    private let old = Data("old-secret".utf8), new = Data("new-secret".utf8)

    func testKeychainWrittenBeforeMetadataWithRollback() async throws {
        let store = await fixture.store()
        let profile = try await store.create(.sample(), password: old)
        XCTAssertEqual(fixture.events.events.first, "keychain.write", "the Keychain is written before the metadata")
        XCTAssertEqual(fixture.events.events.last, "metadata.write")

        // A failed metadata write restores the previous password and leaves the profile as it was.
        fixture.failWrites.isOn = true
        var renamed = profile.settings; renamed.name = "renamed"
        do { _ = try await store.update(profile.id, renamed, password: .set(new), expectedRevision: profile.revision); XCTFail("The write must fail") } catch {
            guard case .persistence = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(fixture.secrets.item(.password, profile.id), old)
        let current = await store.profile(profile.id)
        XCTAssertEqual(current, profile)

        // Removing a password and a host change both put the item back when the metadata can't be written.
        var moved = profile.settings; moved.host = "10.0.0.2"
        let attempts: [() async throws -> ConnectionProfile] = [
            { try await store.update(profile.id, profile.settings, password: .remove, expectedRevision: profile.revision) },
            { try await store.update(profile.id, moved, expectedRevision: profile.revision) }
        ]
        for attempt in attempts {
            do { _ = try await attempt(); XCTFail("The write must fail") } catch {}
            XCTAssertEqual(fixture.secrets.item(.password, profile.id), old)
        }
        let after = await store.profile(profile.id)
        XCTAssertEqual(after, profile)
    }

    func testRollbackOfCreateDeleteAndTLS() async throws {
        let store = await fixture.store()
        let kept = try await store.create(.sample("kept"), password: old)
        _ = try await store.setTLSSecret(kept.id, Data("tls".utf8), expectedRevision: kept.revision)
        let fetched = await store.profile(kept.id)
        let tls = try XCTUnwrap(fetched)
        XCTAssertTrue(tls.hasTLSSecret)

        fixture.failWrites.isOn = true
        // A create whose metadata fails leaves no Keychain item behind.
        do { _ = try await store.create(.sample("lost"), password: new); XCTFail("The write must fail") } catch {}
        XCTAssertEqual(fixture.secrets.itemCount, 2)
        // A delete whose metadata fails restores both items.
        do { try await store.delete(kept.id); XCTFail("The write must fail") } catch {}
        XCTAssertEqual(fixture.secrets.item(.password, kept.id), old)
        XCTAssertEqual(fixture.secrets.item(.tls, kept.id), Data("tls".utf8))
        // Replacing the TLS item restores the previous one.
        do { _ = try await store.setTLSSecret(kept.id, Data("other".utf8), expectedRevision: tls.revision); XCTFail("The write must fail") } catch {}
        XCTAssertEqual(fixture.secrets.item(.tls, kept.id), Data("tls".utf8))
        let profiles = await store.profiles
        XCTAssertEqual(profiles, [tls])
    }

    func testKeychainFailureChangesNothing() async throws {
        let store = await fixture.store()
        let profile = try await store.create(.sample(), password: old)
        fixture.events.reset()
        fixture.secrets.fail("write")
        do { _ = try await store.update(profile.id, profile.settings, password: .set(new), expectedRevision: profile.revision); XCTFail("The Keychain must fail") } catch {
            XCTAssertEqual(error, .secretStore(.keychain(-25308)))
        }
        do { _ = try await store.create(.sample("second"), password: new); XCTFail("The Keychain must fail") } catch {}
        XCTAssertFalse(fixture.events.events.contains("metadata.write"), "no metadata is written when the Keychain refuses")
        let profiles = await store.profiles
        XCTAssertEqual(profiles, [profile])

        // A delete that can't remove the Keychain items keeps the profile, so they aren't orphaned.
        fixture.secrets.fail("write", false); fixture.secrets.fail("remove")
        do { try await store.delete(profile.id); XCTFail("The Keychain must fail") } catch {}
        let kept = await store.profile(profile.id)
        XCTAssertEqual(kept, profile)
        XCTAssertEqual(fixture.secrets.item(.password, profile.id), old)
    }

    func testConnectionRevisionChangeDeletesPassword() async throws {
        let store = await fixture.store()
        var settings = ConnectionSettings.sample(); settings.tls = TLSSettings(serverName: "redis.internal")
        let profile = try await store.create(settings, password: old)
        let password = try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision)
        XCTAssertEqual(password, old)

        // Renaming, relabeling or toggling read-only keeps the password and the connection revision.
        var renamed = settings; renamed.name = "renamed"; renamed.label = .green; renamed.readOnly = true; renamed.database = 3
        let kept = try await store.update(profile.id, renamed, expectedRevision: profile.revision)
        XCTAssertTrue(kept.hasPassword)
        XCTAssertEqual(kept.connectionRevision, profile.connectionRevision)
        XCTAssertEqual(fixture.secrets.item(.password, profile.id), old)

        // Each connection field removes the password and advances the connection revision.
        let changes: [(String, (inout ConnectionSettings) -> Void)] = [
            ("host", { $0.host = "10.0.0.2" }), ("port", { $0.port = 6380 }), ("username", { $0.username = "app" }),
            ("server name", { $0.tls?.serverName = "other.internal" }),
            ("tunnel", { $0.tunnel = .inline(destination: "bastion", user: nil, port: nil, identityFile: nil) })
        ]
        var current = kept
        for (field, change) in changes {
            let restored = try await store.update(current.id, current.settings, password: .set(old), expectedRevision: current.revision)
            var edited = restored.settings; change(&edited)
            let updated = try await store.update(current.id, edited, expectedRevision: restored.revision)
            XCTAssertFalse(updated.hasPassword, field)
            XCTAssertGreaterThan(updated.connectionRevision, restored.connectionRevision, field)
            XCTAssertNil(fixture.secrets.item(.password, profile.id), "\(field) change removes the saved password")
            // A connect resolved at the old connection revision gets nothing.
            let stale = try await store.password(profileID: profile.id, connectionRevision: restored.connectionRevision)
            XCTAssertNil(stale, field)
            current = updated
        }

        // A new password saved with the change is bound to the new connection.
        var moved = current.settings; moved.host = "10.0.0.9"
        let withPassword = try await store.update(current.id, moved, password: .set(new), expectedRevision: current.revision)
        XCTAssertTrue(withPassword.hasPassword)
        let bound = try await store.password(profileID: profile.id, connectionRevision: withPassword.connectionRevision)
        XCTAssertEqual(bound, new)
    }

    func testDeletingAProfileRemovesItsKeychainItems() async throws {
        let store = await fixture.store()
        let profile = try await store.create(.sample(), password: old)
        _ = try await store.setTLSSecret(profile.id, Data("tls".utf8), expectedRevision: profile.revision)
        let other = try await store.create(.sample("other"), password: new)
        try await store.delete(profile.id)
        XCTAssertNil(fixture.secrets.item(.password, profile.id))
        XCTAssertNil(fixture.secrets.item(.tls, profile.id))
        XCTAssertEqual(fixture.secrets.item(.password, other.id), new, "other profiles keep theirs")
        let gone = await store.profile(profile.id)
        XCTAssertNil(gone)
    }
}
