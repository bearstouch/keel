import Foundation
import KeelCore
import KeelSSH
import XCTest

@testable import KeelUI

/// `hosts.json` in memory; `failWrites` makes every commit fail like a full disk.
final class MemoryHostFile: HostStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var failWrites = false
    /// When set, only this many more writes succeed.
    var writesLeft: Int?
    func read() throws -> Data? { lock.withLock { stored } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if failWrites || writesLeft == 0 { throw HostLibraryError.io(EIO) }
            writesLeft = writesLeft.map { $0 - 1 }
            stored = data
        }
    }
    func preserveUnreadable() throws {}
}

/// A Keychain stand-in that counts reads, so a test can prove a saved password is never read back.
final class MemoryHostKeychain: HostSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    private var readCount = 0
    var failStores = false
    var reads: Int { lock.withLock { readCount } }
    subscript(id: UUID) -> Data? { lock.withLock { values[id] } }
    func store(_ password: Data, hostID: UUID) throws {
        try lock.withLock {
            if failStores { throw HostSecretError.unavailable(errSecAuthFailed) }
            values[hostID] = password
        }
    }
    func read(hostID: UUID) throws -> Data? {
        lock.withLock {
            readCount += 1; return values[hostID]
        }
    }
    func remove(hostID: UUID) { _ = lock.withLock { values.removeValue(forKey: hostID) } }
}

@MainActor
final class HostPickerModelTests: XCTestCase {
    private static let config = """
        Include ~/.ssh/config.d/*
        Host bastion prod-db
          User deploy
        Host *.corp
        Match exec "touch /tmp/never"
        Host staging
        """

    private static func discovering(_ text: String) -> HostPickerModel.Discover { { .success(SSHConfigDiscovery.parse(text)) } }

    func testCombinesSavedAndDiscoveredHosts() async throws {
        let library = HostLibrary(storage: MemoryHostFile())
        let saved = try await library.create(HostDraft(name: "Ops bastion", destination: "bastion"))
        let picker = HostPickerModel(library: library, discover: Self.discovering(Self.config))
        await picker.reload()
        XCTAssertEqual(picker.saved, [saved])
        // `bastion` is already saved as a destination, so it is listed once, as the saved host.
        XCTAssertEqual(picker.discovered, ["prod-db", "staging"])
        XCTAssertEqual(picker.entries.map(\.name), ["Ops bastion", "prod-db", "staging"])
        XCTAssertEqual(picker.entries.first, .saved(saved))
        // Patterns and Match blocks never appear; the unfollowed Include is labeled.
        XCTAssertEqual(picker.notes.count, 1)
        XCTAssertTrue(picker.notes[0].contains("Include ~/.ssh/config.d/*"))
        XCTAssertTrue(picker.notes[0].contains("not followed"))
    }

    func testChoosingAnAliasSavesItOnceAndSelectsIt() async throws {
        let file = MemoryHostFile()
        let library = HostLibrary(storage: file)
        let picker = HostPickerModel(library: library, discover: Self.discovering(Self.config))
        await picker.reload()
        let sheet = ConnectionSheetModel(mode: .create(folderID: nil), hosts: picker, tester: FakeConnectionTester(), store: NoStore())
        await sheet.useHost(.discovered(alias: "prod-db"))
        let host = try XCTUnwrap(picker.host(sheet.tunnelHostID))
        XCTAssertEqual(host.destination, "prod-db")
        XCTAssertEqual(host.sshArguments(), ["--", "prod-db"], "ssh resolves the alias from the user's config")
        XCTAssertEqual(sheet.tunnelKind, .savedHost)
        XCTAssertEqual(picker.discovered, ["bastion", "staging"])
        // A stale list choosing the same alias again reuses the saved host.
        await sheet.useHost(.discovered(alias: "prod-db"))
        let hosts = await library.hosts
        XCTAssertEqual(hosts.map(\.destination), ["prod-db"])
        XCTAssertEqual(sheet.tunnelHostID, host.id)
    }

    func testFailedImportKeepsSelectionAndSaysWhy() async throws {
        let file = MemoryHostFile()
        let library = HostLibrary(storage: file)
        let picker = HostPickerModel(library: library, discover: Self.discovering(Self.config))
        await picker.reload()
        let sheet = ConnectionSheetModel(mode: .create(folderID: nil), hosts: picker, tester: FakeConnectionTester(), store: NoStore())
        file.failWrites = true
        await sheet.useHost(.discovered(alias: "staging"))
        XCTAssertNil(sheet.tunnelHostID)
        XCTAssertEqual(sheet.tunnelKind, .none)
        XCTAssertNotNil(picker.error)
        let hosts = await library.hosts
        XCTAssertTrue(hosts.isEmpty)
    }

    /// A slow alias import finishing after a later choice never overrides that choice.
    func testLateImportDoesNotOverrideALaterChoice() async throws {
        let library = HostLibrary(storage: MemoryHostFile())
        let saved = try await library.create(HostDraft(name: "Ops", destination: "ops"))
        let picker = HostPickerModel(library: library, discover: Self.discovering(Self.config))
        await picker.reload()
        let sheet = ConnectionSheetModel(mode: .create(folderID: nil), hosts: picker, tester: FakeConnectionTester(), store: NoStore())
        let late = Task { await sheet.useHost(.discovered(alias: "prod-db")) }
        while sheet.hostChoice == 0 { await Task.yield() }
        await sheet.useHost(.saved(saved))
        await late.value
        XCTAssertEqual(sheet.tunnelHostID, saved.id)
        await sheet.useHost(nil)
        XCTAssertNil(sheet.tunnelHostID)
    }

    func testUnreadableConfigIsLabeledAndSavedHostsRemain() async throws {
        let library = HostLibrary(storage: MemoryHostFile())
        _ = try await library.create(HostDraft(name: "Ops", destination: "ops"))
        let picker = HostPickerModel(library: library, discover: { .failure(.unreadable("Permission denied")) })
        await picker.reload()
        XCTAssertEqual(picker.saved.map(\.name), ["Ops"])
        XCTAssertEqual(picker.discovered, [])
        XCTAssertEqual(picker.notes, ["~/.ssh/config couldn't be read: Permission denied"])
        let missing = HostPickerModel(library: library, discover: { .failure(.missing) })
        await missing.reload()
        XCTAssertEqual(missing.notes, [])
    }
}

@MainActor
final class HostEditorModelTests: XCTestCase {
    private let secret = "s3cret-SSH-password"

    private func saved(_ editor: HostEditorModel, file: StaticString = #filePath, line: UInt = #line) async throws -> SavedHost {
        let host = await editor.save()
        return try XCTUnwrap(host, "Save failed: \(editor.saveError ?? "\(editor.fieldErrors)")", file: file, line: line)
    }

    /// AC2: the password goes to the Keychain under the host's id and is never read back into the editor.
    func testSavedPasswordIsStoredAndNeverShownAgain() async throws {
        let keychain = MemoryHostKeychain()
        let library = HostLibrary(storage: MemoryHostFile(), secrets: keychain)
        let editor = HostEditorModel(mode: .create, library: library)
        editor.destination = "bastion"; editor.user = "deploy"; editor.password = secret; editor.requiresUserPresence = true
        let host = try await saved(editor)
        XCTAssertEqual(host.name, "bastion", "A blank name takes the destination")
        XCTAssertEqual(keychain[host.id], Data(secret.utf8))
        XCTAssertEqual(host.savedPassword, SavedPasswordPolicy(requiresUserPresence: true))
        XCTAssertEqual(editor.password, "", "Wiped after Save")
        XCTAssertEqual(editor.finished, .some(host))

        let reopened = HostEditorModel(mode: .edit(host), library: library)
        XCTAssertEqual(reopened.password, "")
        XCTAssertTrue(reopened.hasSavedPassword)
        XCTAssertTrue(reopened.requiresUserPresence)
        reopened.name = "Bastion"
        _ = await reopened.save()
        XCTAssertEqual(keychain.reads, 0, "Neither editor nor Save reads the saved password")
        XCTAssertEqual(keychain[host.id], Data(secret.utf8), "A rename keeps it")
    }

    func testEditChangesPolicyAndRemovesPassword() async throws {
        let keychain = MemoryHostKeychain()
        let library = HostLibrary(storage: MemoryHostFile(), secrets: keychain)
        let created = HostEditorModel(mode: .create, library: library)
        created.destination = "bastion"; created.password = secret
        let host = try await saved(created)
        XCTAssertEqual(host.savedPassword, SavedPasswordPolicy(requiresUserPresence: false))

        let policy = HostEditorModel(mode: .edit(host), library: library)
        policy.requiresUserPresence = true
        let required = try await saved(policy)
        XCTAssertEqual(required.savedPassword, SavedPasswordPolicy(requiresUserPresence: true))

        let removal = HostEditorModel(mode: .edit(required), library: library)
        removal.removePassword = true
        let removed = try await saved(removal)
        XCTAssertNil(removed.savedPassword)
        XCTAssertNil(keychain[host.id])
    }

    func testKeychainRefusalSavesNoNewHost() async throws {
        let keychain = MemoryHostKeychain()
        keychain.failStores = true
        let library = HostLibrary(storage: MemoryHostFile(), secrets: keychain)
        let editor = HostEditorModel(mode: .create, library: library)
        editor.destination = "bastion"; editor.password = secret
        let result = await editor.save()
        XCTAssertNil(result)
        XCTAssertNotNil(editor.saveError)
        XCTAssertTrue(editor.finished == nil, "The sheet stays open")
        let hosts = await library.hosts
        XCTAssertTrue(hosts.isEmpty, "A host without the password it was saved with is removed")
    }

    /// The password commit and the rollback both fail: the new host stays, and the next Save finishes it
    /// instead of adding a second one.
    func testFailedRollbackRetryDoesNotDuplicateTheHost() async throws {
        let file = MemoryHostFile()
        file.writesLeft = 1
        let keychain = MemoryHostKeychain()
        let library = HostLibrary(storage: file, secrets: keychain)
        let editor = HostEditorModel(mode: .create, library: library)
        editor.destination = "bastion"; editor.password = secret
        let failed = await editor.save()
        XCTAssertNil(failed)
        XCTAssertNotNil(editor.saveError)
        file.writesLeft = nil
        let host = try await saved(editor)
        let hosts = await library.hosts
        XCTAssertEqual(hosts.map(\.id), [host.id])
        XCTAssertNotNil(host.savedPassword)
        XCTAssertEqual(keychain[host.id], Data(secret.utf8))
    }

    func testInvalidFieldsAndPasswordWriteNothing() async throws {
        let file = MemoryHostFile()
        let library = HostLibrary(storage: file, secrets: MemoryHostKeychain())
        let editor = HostEditorModel(mode: .create, library: library)
        editor.destination = "-oProxyCommand=x"
        _ = await editor.save()
        XCTAssertNotNil(editor.fieldErrors[.destination])
        editor.destination = "bastion"; editor.password = "two\nlines"
        _ = await editor.save()
        XCTAssertNotNil(editor.fieldErrors[.password])
        XCTAssertNil(try file.read(), "Nothing was written")
    }

    func testCancelWipesThePassword() async {
        let editor = HostEditorModel(mode: .create, library: HostLibrary(storage: MemoryHostFile()))
        editor.password = secret
        editor.cancel()
        XCTAssertEqual(editor.password, "")
        XCTAssertEqual(editor.finished, .some(SavedHost?.none))
    }
}

/// A profile store the host tests never reach.
private struct NoStore: ProfileSaving {
    func create(_ settings: ConnectionSettings, folderID: UUID?, password: Data?) async throws(ProfileStoreError) -> ConnectionProfile { throw .readOnly }
    func update(_ id: UUID, _ settings: ConnectionSettings, password: PasswordChange, expectedRevision: UInt64) async throws(ProfileStoreError) -> ConnectionProfile {
        throw .readOnly
    }
    func password(profileID: UUID, connectionRevision: UInt64) async throws(ProfileStoreError) -> Data? { nil }
}
