import XCTest
@testable import KeelCore

final class ProfileImportTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    /// A store with a folder, a profile inside it with a saved password, and one at the top level.
    private func seeded() async throws -> (ProfileStore, ProfileFolder, ConnectionProfile, ConnectionProfile) {
        let store = await fixture.store()
        let folder = try await store.createFolder(named: "Payments")
        let inside = try await store.create(.sample("payments", host: "10.0.0.1"), folderID: folder.id, password: Data("pw".utf8))
        let top = try await store.create(.sample("local"))
        return (store, folder, inside, top)
    }

    func testSkipPolicyIsIdempotent() async throws {
        let (store, _, _, _) = try await seeded()
        let data = try await store.export().encoded()
        let before = await store.document
        let preview = await store.previewImport(try ProfileExport.decode(data))
        XCTAssertEqual(preview.profileCount, 2); XCTAssertEqual(preview.folderCount, 1)
        XCTAssertEqual(preview.conflictingProfiles, ["payments", "local"]); XCTAssertEqual(preview.conflictingFolders, ["Payments"])

        fixture.events.reset()
        for _ in 0..<2 {
            let result = try await store.importProfiles(try ProfileExport.decode(data), policy: .skip)
            XCTAssertEqual(result, ProfileImportResult(skipped: 2))
        }
        let after = await store.document
        XCTAssertEqual(after, before, "re-importing with Skip changes nothing, not even the revision")
        XCTAssertEqual(fixture.events.events, [], "and writes nothing")
        XCTAssertEqual(fixture.secrets.item(.password, before.profiles[0].id), Data("pw".utf8))
    }

    func testFailedImportIsAtomic() async throws {
        let (store, folder, inside, _) = try await seeded()
        let before = await store.document
        let fileBefore = try Data(contentsOf: fixture.fileURL)
        // Replace changes the connection (removing the password), renames the folder and adds a profile and a folder.
        var changed = ProfileExport(before)
        changed.folders[0].name = "Renamed"; changed.folders.append(.init(id: UUID(), name: "New"))
        changed.profiles[0].settings.host = "10.0.0.2"
        changed.profiles.append(.init(id: UUID(), folderID: changed.folders[1].id, settings: .sample("added")))

        fixture.failWrites.isOn = true
        do { _ = try await store.importProfiles(changed, policy: .replace); XCTFail("The metadata write must fail") } catch {
            guard case .persistence = error else { return XCTFail("Unexpected \(error)") }
        }
        let after = await store.document
        XCTAssertEqual(after, before, "a failed import leaves every profile and folder as it was")
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), fileBefore)
        XCTAssertEqual(fixture.secrets.item(.password, inside.id), Data("pw".utf8), "the removed password is restored")

        // A record that fails validation is refused before anything is touched.
        fixture.failWrites.isOn = false; fixture.events.reset()
        var invalid = changed
        invalid.profiles.append(.init(id: UUID(), settings: ConnectionSettings(name: "x", host: "-oProxyCommand=id")))
        do { _ = try await store.importProfiles(invalid, policy: .replace); XCTFail("An invalid record must be refused") } catch {
            XCTAssertEqual(error, .invalidImport(.invalid(.host)))
        }
        let unchanged = await store.document
        XCTAssertEqual(unchanged, before); XCTAssertEqual(fixture.events.events, [])
        XCTAssertEqual(unchanged.folders.map(\.id), [folder.id])
    }

    func testRejectsNewerVersion() async throws {
        let (store, _, _, _) = try await seeded()
        let before = await store.document
        let newer = Data(#"{"format":"keel-profiles","schemaVersion":2,"folders":[],"profiles":[],"somethingNew":{"x":1}}"#.utf8)
        XCTAssertThrowsError(try ProfileExport.decode(newer)) { error in
            XCTAssertEqual(error as? ProfileImportError, .newerVersion(2))
            XCTAssertEqual((error as? ProfileImportError)?.message, "This file was exported by a newer version of Keel (format 2). Update Keel to import it.")
        }
        let after = await store.document
        XCTAssertEqual(after, before)
    }

    func testImportIntoEmptyStoreKeepsOrderAndFoldersUnderNewProfileIDs() async throws {
        let (source, folder, inside, top) = try await seeded()
        let data = try await source.export().encoded()
        let other = try ProfileFixture(); defer { other.remove() }
        let target = await other.store()
        let preview = await target.previewImport(try ProfileExport.decode(data))
        XCTAssertFalse(preview.hasConflicts)
        let result = try await target.importProfiles(try ProfileExport.decode(data), policy: .skip)
        XCTAssertEqual(result, ProfileImportResult(added: 2, foldersAdded: 1))
        let document = await target.document
        XCTAssertEqual(document.folders.map(\.id), [folder.id])
        XCTAssertEqual(document.profiles.map(\.importedFrom), [inside.id, top.id])
        XCTAssertTrue(Set(document.profiles.map(\.id)).isDisjoint(with: [inside.id, top.id]), "the Keychain is shared by every Keel copy, so IDs never are")
        XCTAssertEqual(document.profiles.map(\.folderID), [folder.id, nil])
        XCTAssertEqual(document.profiles[0].settings, inside.settings)
        XCTAssertFalse(document.profiles[0].hasPassword, "secrets never travel; the password has to be entered again")
        XCTAssertEqual(other.secrets.itemCount, 0)
    }

    /// Export from one Keel copy, import into another: both share the login Keychain, keyed by profile ID.
    func testImportedProfileNeverTouchesTheSourceCopysKeychainItems() async throws {
        let (source, _, inside, top) = try await seeded()
        let data = try await source.export().encoded()
        let other = try ProfileFixture(); defer { other.remove() }
        other.secrets.seed(Data("installed".utf8), .password, inside.id); other.secrets.seed(Data("tls".utf8), .tls, inside.id)
        other.secrets.seed(Data("installed2".utf8), .password, top.id)
        let target = await other.store()
        _ = try await target.importProfiles(try ProfileExport.decode(data), policy: .skip)
        let imported = await target.document.profiles
        XCTAssertNotEqual(imported[0].id, inside.id)

        _ = try await target.update(imported[1].id, imported[1].settings, password: .set(Data("dev".utf8)), expectedRevision: imported[1].revision)
        try await target.delete(imported[0].id)
        XCTAssertEqual(other.secrets.item(.password, inside.id), Data("installed".utf8), "deleting the import leaves the source's password")
        XCTAssertEqual(other.secrets.item(.tls, inside.id), Data("tls".utf8))
        XCTAssertEqual(other.secrets.item(.password, top.id), Data("installed2".utf8), "a password set on the import never overwrites the source's")
        XCTAssertEqual(other.secrets.item(.password, imported[1].id), Data("dev".utf8))
    }

    /// A re-import of the same file still matches the profiles it added, although they were saved under new IDs.
    func testReimportMatchesProfilesByTheirImportedID() async throws {
        let (source, _, _, _) = try await seeded()
        let data = try await source.export().encoded()
        let other = try ProfileFixture(); defer { other.remove() }
        let target = await other.store()
        _ = try await target.importProfiles(try ProfileExport.decode(data), policy: .skip)
        let before = await target.document
        let preview = await target.previewImport(try ProfileExport.decode(data))
        XCTAssertEqual(preview.conflictingProfiles, ["payments", "local"])
        let skipped = try await target.importProfiles(try ProfileExport.decode(data), policy: .skip)
        XCTAssertEqual(skipped, ProfileImportResult(skipped: 2))
        let unchanged = await target.document
        XCTAssertEqual(unchanged, before)

        var renamed = try ProfileExport.decode(data); renamed.profiles[0].settings.name = "billing"
        let result = try await target.importProfiles(renamed, policy: .replace)
        XCTAssertEqual(result, ProfileImportResult(replaced: 1, skipped: 1))
        let replaced = await target.document
        XCTAssertEqual(replaced.profiles.map(\.id), before.profiles.map(\.id), "Replace updates the saved profile in place")
        XCTAssertEqual(replaced.profiles[0].settings.name, "billing")

        // The new field survives a reload of connections.json.
        let reloaded = await other.store()
        let reloadedProfiles = await reloaded.document.profiles
        XCTAssertEqual(reloadedProfiles.map(\.importedFrom), before.profiles.map(\.importedFrom))
    }

    func testReplacePolicyOverwritesAndDropsPasswordForANewServer() async throws {
        let (store, folder, inside, top) = try await seeded()
        var export = await store.export()
        export.folders[0].name = "Billing"
        export.profiles[0].settings.name = "renamed"  // same server: password kept
        export.profiles[1].settings.host = "10.9.9.9"; export.profiles[1].folderID = folder.id
        _ = try await store.update(top.id, top.settings, password: .set(Data("pw2".utf8)), expectedRevision: top.revision)

        let result = try await store.importProfiles(export, policy: .replace)
        XCTAssertEqual(result, ProfileImportResult(replaced: 2, foldersRenamed: 1))
        let document = await store.document
        XCTAssertEqual(document.folders.map(\.name), ["Billing"])
        XCTAssertEqual(document.profiles.map(\.settings.name), ["renamed", "local"])
        XCTAssertEqual(document.profiles.map(\.folderID), [folder.id, folder.id])
        XCTAssertTrue(document.profiles[0].hasPassword); XCTAssertEqual(fixture.secrets.item(.password, inside.id), Data("pw".utf8))
        XCTAssertEqual(document.profiles[0].connectionRevision, inside.connectionRevision)
        XCTAssertFalse(document.profiles[1].hasPassword); XCTAssertNil(fixture.secrets.item(.password, top.id), "a new server never gets the old password")
        XCTAssertEqual(document.profiles[1].connectionRevision, document.revision)
    }

    func testKeepBothAddsCopiesWithNewIDs() async throws {
        let (store, folder, inside, top) = try await seeded()
        let export = await store.export()
        let result = try await store.importProfiles(export, policy: .keepBoth)
        XCTAssertEqual(result, ProfileImportResult(added: 2))
        let document = await store.document
        XCTAssertEqual(document.folders.map(\.id), [folder.id], "folders are shared, not duplicated")
        XCTAssertEqual(document.profiles.map(\.settings.name), ["payments", "payments (imported)", "local", "local (imported)"])
        XCTAssertEqual(Set(document.profiles.map(\.id)).count, 4)
        XCTAssertEqual(document.profiles.filter { $0.id != inside.id && $0.id != top.id }.map(\.hasPassword), [false, false])
        XCTAssertEqual(ProfileStore.importedName(String(repeating: "n", count: 128)).count, ConnectionSettings.nameLimit)
    }

    func testReadOnlyStoreRefusesImport() async throws {
        let store = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)  // never loaded
        do { _ = try await store.importProfiles(ProfileExport(profiles: [.init(id: UUID(), settings: .sample())]), policy: .skip); XCTFail("Must be refused") } catch {
            XCTAssertEqual(error, .readOnly)
        }
    }
}
