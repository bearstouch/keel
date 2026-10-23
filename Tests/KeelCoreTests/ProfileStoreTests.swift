import XCTest
@testable import KeelCore

final class ProfileStoreTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    private func names(_ profiles: [ConnectionProfile]) -> [String] { profiles.map(\.settings.name) }

    func testCrudAndOrderPersist() async throws {
        let store = await fixture.store()
        let folder = try await store.createFolder(named: "Payments")
        let a = try await store.create(.sample("a"))
        let b = try await store.create(.sample("b"), folderID: folder.id, password: Data("pw".utf8))
        let c = try await store.create(.sample("c"))
        // Edit, duplicate, reorder, move between folders, delete.
        var settings = a.settings; settings.name = "alpha"; settings.readOnly = true; settings.separator = "::"
        let edited = try await store.update(a.id, settings, expectedRevision: a.revision)
        let copy = try await store.duplicate(b.id)
        XCTAssertEqual(copy.settings.name, "b copy"); XCTAssertEqual(copy.folderID, folder.id); XCTAssertTrue(copy.hasPassword)
        XCTAssertEqual(fixture.secrets.item(.password, copy.id), Data("pw".utf8), "a duplicate gets its own copy of the password")
        let moved = try await store.move(c.id, toFolder: nil, position: 0, expectedRevision: c.revision)
        _ = try await store.move(edited.id, toFolder: folder.id, position: 1, expectedRevision: edited.revision)
        try await store.delete(b.id, expectedRevision: b.revision)
        let current = await store.document
        XCTAssertEqual(names(current.profiles), ["c", "alpha", "b copy"])
        XCTAssertEqual(current.profiles.map(\.folderID), [nil, folder.id, folder.id])
        XCTAssertEqual(moved.folderID, nil)

        // Relaunch: a fresh store over the same folder sees the same profiles, folders, order and settings.
        let relaunched = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        guard case .ready = await relaunched.load() else { return XCTFail("Expected a usable file") }
        let reloaded = await relaunched.document
        XCTAssertEqual(reloaded, current)
        XCTAssertEqual(reloaded.profiles[1].settings, settings)
        XCTAssertEqual(reloaded.folders.map(\.name), ["Payments"])
    }

    func testRevisionsRejectStaleUpdates() async throws {
        let store = await fixture.store()
        let profile = try await store.create(.sample("a"))
        var renamed = profile.settings; renamed.name = "renamed"
        let updated = try await store.update(profile.id, renamed, expectedRevision: profile.revision)
        XCTAssertGreaterThan(updated.revision, profile.revision)

        // A second editor still holding the first revision is refused, and nothing changes.
        var stale = profile.settings; stale.name = "stale"
        do {
            _ = try await store.update(profile.id, stale, expectedRevision: profile.revision)
            XCTFail("A stale update must be refused")
        } catch { XCTAssertEqual(error, .conflict(expected: profile.revision, actual: updated.revision)) }
        do {
            try await store.delete(profile.id, expectedRevision: profile.revision); XCTFail("A stale delete must be refused")
        } catch { XCTAssertEqual(error, .conflict(expected: profile.revision, actual: updated.revision)) }
        do {
            _ = try await store.move(profile.id, toFolder: nil, expectedRevision: profile.revision); XCTFail("A stale move must be refused")
        } catch { XCTAssertEqual(error, .conflict(expected: profile.revision, actual: updated.revision)) }
        let kept = await store.profile(profile.id)
        XCTAssertEqual(kept, updated)

        // An unchanged save keeps the revision, so approvals bound to it survive.
        let unchanged = try await store.update(profile.id, renamed, expectedRevision: updated.revision)
        XCTAssertEqual(unchanged.revision, updated.revision)
    }

    func testInvalidSettingsAreRejectedBeforeAnythingIsWritten() async throws {
        let store = await fixture.store()
        let cases: [(ConnectionSettings, ProfileField)] = [
            (ConnectionSettings(name: " "), .name),
            (ConnectionSettings(name: "x", host: "-oProxyCommand=id"), .host),
            (ConnectionSettings(name: "x", host: "has space"), .host),
            (ConnectionSettings(name: "x", port: 0), .port),
            (ConnectionSettings(name: "x", username: "a\nb"), .username),
            (ConnectionSettings(name: "x", database: -1), .database),
            (ConnectionSettings(name: "x", tunnel: .inline(destination: "-oProxyCommand=id", user: nil, port: nil, identityFile: nil)), .tunnel),
            (ConnectionSettings(name: "x", tunnel: .inline(destination: "ops", user: "-x", port: nil, identityFile: nil)), .tunnel),
            (ConnectionSettings(name: "x", tls: TLSSettings(caFile: "relative.pem")), .caFile),
            (ConnectionSettings(name: "x", connectTimeoutMilliseconds: 0), .connectTimeout),
            (ConnectionSettings(name: "x", separator: "12345"), .separator),
            (ConnectionSettings(name: "x", clientName: "two words"), .clientName)
        ]
        for (settings, field) in cases {
            do { _ = try await store.create(settings, password: Data("pw".utf8)); XCTFail("\(field) must be rejected") } catch {
                XCTAssertEqual(error, .invalid(field))
            }
        }
        let profiles = await store.profiles
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertEqual(fixture.secrets.itemCount, 0, "a rejected profile writes no Keychain item")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testFoldersAndLabels() async throws {
        let store = await fixture.store()
        let first = try await store.createFolder(named: "One")
        let second = try await store.createFolder(named: "Two")
        let inside = try await store.create(.sample("inside"), folderID: first.id)
        try await store.moveFolder(second.id, to: 0)
        let collapsed = try await store.setFolderCollapsed(first.id, true)
        XCTAssertTrue(collapsed.collapsed)
        let folders = await store.folders
        XCTAssertEqual(folders.map(\.name), ["Two", "One"])

        // Deleting a folder keeps its profiles at the top level.
        try await store.deleteFolder(first.id)
        let kept = await store.profile(inside.id)
        XCTAssertEqual(kept?.folderID, nil)
        XCTAssertEqual(kept?.settings.name, "inside")
        do { _ = try await store.create(.sample(), folderID: first.id); XCTFail("A missing folder must be refused") } catch { XCTAssertEqual(error, .invalid(.folder)) }

        // Labels: editable names; red is the built-in Production label and stays production.
        var settings = ConnectionSettings.sample("prod"); settings.label = .red
        let prod = try await store.create(settings)
        let isProduction = await store.isProduction(prod)
        XCTAssertTrue(isProduction)
        try await store.renameLabel(.red, to: "Live")
        try await store.setTreatAsProduction(.orange, true)
        do { try await store.setTreatAsProduction(.red, false); XCTFail("Production can't be unmarked") } catch { XCTAssertEqual(error, .invalid(.label)) }
        let labels = await store.labels
        XCTAssertEqual(labels.map(\.color), LabelColor.allCases)
        XCTAssertEqual(labels.first { $0.color == .red }, ProfileLabel(color: .red, name: "Live", treatAsProduction: true))
        XCTAssertTrue(labels.first { $0.color == .orange }?.treatAsProduction == true)

        let relaunched = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        _ = await relaunched.load()
        let reloadedLabels = await relaunched.labels
        XCTAssertEqual(reloadedLabels, labels)
    }

    func testConcurrentMutationsAreAllPersisted() async throws {
        let store = await fixture.store()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 { group.addTask { _ = try await store.create(.sample("p\(index)")) } }
            try await group.waitForAll()
        }
        let relaunched = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        _ = await relaunched.load()
        let profiles = await relaunched.profiles
        XCTAssertEqual(Set(names(profiles)), Set((0..<20).map { "p\($0)" }), "no edit is lost across the persistence suspension")
        XCTAssertEqual(Set(profiles.map(\.revision)).count, 20)
    }

    func testUnloadedOrRecoveringStoreRefusesWrites() async throws {
        let unloaded = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        do { _ = try await unloaded.create(.sample()); XCTFail("Nothing is written before load") } catch { XCTAssertEqual(error, .readOnly) }

        // A hand-edited file with an option-like tunnel destination is unusable: recovery, never a connect.
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let hostile = """
            {"schemaVersion":1,"revision":1,"folders":[],"labels":[],"profiles":[{"id":"\(id)","revision":1,"connectionRevision":1,"hasPassword":false,"hasTLSSecret":false,
            "settings":{"name":"x","label":"none","host":"127.0.0.1","port":6379,"database":0,"readOnly":false,"reconnectOnLaunch":false,
            "tunnel":{"inline":{"destination":"-oProxyCommand=id"}}}}]}
            """
        try Data(hostile.utf8).write(to: fixture.fileURL)
        let store = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        guard case .recovery(.corrupt, false) = await store.load() else { return XCTFail("Expected recovery") }
        do { _ = try await store.create(.sample()); XCTFail("Awaiting recovery") } catch { XCTAssertEqual(error, .readOnly) }
        try await store.recover(.startEmpty)
        _ = try await store.create(.sample("fresh"))
        _ = try await store.create(.sample("second"))
        let preserved = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0.hasPrefix("connections.corrupt.") }
        XCTAssertEqual(preserved.count, 1, "the unreadable original is kept")

        // A newer Keel's file: the backup can be shown, read-only, and the file is never overwritten.
        let newer = Data(#"{"schemaVersion":99,"revision":0,"folders":[],"profiles":[]}"#.utf8)
        try newer.write(to: fixture.fileURL)
        let later = ProfileStore(directory: fixture.directory, secrets: fixture.secrets)
        guard case .recovery(.newerVersion(99), true) = await later.load() else { return XCTFail("Expected a newer-version recovery") }
        try await later.recover(.recoverBackup)
        let shown = await later.profiles
        XCTAssertEqual(names(shown), ["fresh"], "the backup is shown in memory")
        let isWritable = await later.isWritable
        XCTAssertFalse(isWritable)
        do { _ = try await later.create(.sample()); XCTFail("A newer file stays read-only") } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), newer)
    }
}
