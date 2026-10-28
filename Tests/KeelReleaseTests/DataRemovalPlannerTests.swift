import Foundation
import KeelCore
import KeelSSH
import XCTest

@testable import KeelRelease

/// An in-memory Keychain holding Keel's items beside other apps' and Trellis's.
final class FakeKeychain: KeychainInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var items: Set<DataRemovalPlan.KeychainItem>
    var unreadable: Set<String> = []
    var failsRemoving: Set<String> = []

    init(_ items: [(String, String)]) { self.items = Set(items.map { DataRemovalPlan.KeychainItem(service: $0.0, account: $0.1) }) }

    var remaining: Set<DataRemovalPlan.KeychainItem> { lock.withLock { items } }

    func accounts(service: String) throws(DataRemovalError) -> [String] {
        if unreadable.contains(service) { throw .keychain(-25308) }
        return lock.withLock { items.filter { $0.service == service }.map(\.account) }
    }

    func remove(service: String, account: String) throws(DataRemovalError) {
        if failsRemoving.contains(service) { throw .keychain(-25293) }
        _ = lock.withLock { items.remove(DataRemovalPlan.KeychainItem(service: service, account: account)) }
    }
}

final class DataRemovalPlannerTests: XCTestCase {
    private var home: URL!
    private var state: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // A fake home with SSH files and a Trellis-like sibling folder, and Keel's state folder in Application Support.
        home = fm.temporaryDirectory.appendingPathComponent("keel-removal-\(UUID().uuidString)", isDirectory: true)
        state = home.appendingPathComponent("Library/Application Support/\(AppInstanceIdentity.development)", isDirectory: true)
        try StateLocation.prepare(state)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func write(_ relative: String, in base: URL? = nil) throws {
        let url = (base ?? home).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relative: String, in base: URL? = nil) -> Bool { fm.fileExists(atPath: (base ?? home).appendingPathComponent(relative).path) }

    /// AC2: only Keel's files, Keychain items and preference keys go; SSH keys and configuration, other apps' Keychain
    /// items and preferences, and other apps' folders stay.
    func testOnlyKeelOwnedItems() throws {
        let keel = PersistedFile.allCases.flatMap { [$0.fileName] + ($0.backupName.map { [$0] } ?? []) } + ["connections.corrupt.\(UUID().uuidString).json", ".windows.\(UUID().uuidString).tmp"]
        for name in keel { try write(name, in: state) }
        for name in [".ssh/id_ed25519", ".ssh/id_ed25519.pub", ".ssh/config", ".ssh/known_hosts", "Library/Application Support/Other/hosts.json"] { try write(name) }
        let profile = UUID().uuidString, host = UUID().uuidString
        let keychain = FakeKeychain([
            ("Keel Connection", profile), ("Keel TLS", profile), ("Keel SSH Host", host),
            ("Other SSH Host", host), ("Keel", profile), ("Keel Connection Extra", profile)
        ])

        let plan = DataRemovalPlanner.plan(stateDirectory: state, home: home, keychain: keychain, storedPreferenceKeys: ["keyboardShortcuts", "NSWindow Frame Main", "AppleLanguages"])
        XCTAssertEqual(Set(plan.files), Set(keel))
        XCTAssertEqual(plan.keptEntries, [])
        XCTAssertTrue(plan.removesDirectory)
        XCTAssertEqual(Set(plan.keychainItems.map(\.service)), ["Keel Connection", "Keel TLS", "Keel SSH Host"])
        XCTAssertEqual(plan.preferenceKeys, ["keyboardShortcuts"])

        var removedKeys: [String] = []
        let result = DataRemovalPlanner.execute(plan, keychain: keychain) { removedKeys.append($0) }
        XCTAssertEqual(result.failures, [])
        XCTAssertFalse(fm.fileExists(atPath: state.path), "The state folder is gone")
        for name in [".ssh/id_ed25519", ".ssh/id_ed25519.pub", ".ssh/config", ".ssh/known_hosts", "Library/Application Support/Other/hosts.json"] {
            XCTAssertTrue(exists(name), "\(name) is untouched")
        }
        XCTAssertEqual(
            keychain.remaining,
            [.init(service: "Other SSH Host", account: host), .init(service: "Keel", account: profile), .init(service: "Keel Connection Extra", account: profile)])
        XCTAssertEqual(removedKeys, ["keyboardShortcuts"])
    }

    /// MAC-22: a `--fixture` run removes its state folder only. The Keychain items it could see (the installed app's)
    /// aren't even listed, no preference key is planned, and a hand-built plan with items still removes none.
    func testStateFolderOnlyScopeNeverTouchesKeychainOrPreferences() throws {
        try write(PersistedFile.connections.fileName, in: state)
        let profile = UUID().uuidString
        let keychain = FakeKeychain([("Keel Connection", profile), ("Keel SSH Host", profile)])
        keychain.unreadable = Set(DataRemovalPlanner.keychainServices)

        var plan = DataRemovalPlanner.plan(stateDirectory: state, home: home, keychain: keychain, storedPreferenceKeys: ["keyboardShortcuts"], scope: .stateFolderOnly)
        XCTAssertEqual(plan.scope, .stateFolderOnly)
        XCTAssertEqual(plan.files, [PersistedFile.connections.fileName])
        XCTAssertEqual(plan.keychainItems, [])
        XCTAssertEqual(plan.unreadableServices, [], "The Keychain isn't queried")
        XCTAssertEqual(plan.preferenceKeys, [])

        keychain.unreadable = []
        plan.keychainItems = [.init(service: "Keel Connection", account: profile)]
        var removedKeys: [String] = []
        XCTAssertEqual(DataRemovalPlanner.execute(plan, keychain: keychain) { removedKeys.append($0) }.failures, [])
        XCTAssertFalse(fm.fileExists(atPath: state.path))
        XCTAssertEqual(keychain.remaining.count, 2)
        XCTAssertEqual(removedKeys, [])
    }

    /// The allow-lists match what Keel actually writes, so a new state file or Keychain service can't be missed.
    func testAllowListsMatchKeelNames() {
        XCTAssertEqual(Set(DataRemovalPlanner.stateFileStems), Set(PersistedFile.allCases.map(\.rawValue)))
        XCTAssertEqual(DataRemovalPlanner.keychainServices, ProfileSecret.allCases.map(\.rawValue) + [KeychainHostSecretStore.service])
        XCTAssertTrue(DataRemovalPlanner.preferenceKeys.contains("keyboardShortcuts"))
        XCTAssertTrue(DataRemovalPlanner.isKeelFile("hosts.unreadable.\(UUID().uuidString).json"))
        XCTAssertTrue(DataRemovalPlanner.isKeelFile(".hosts.\(UUID().uuidString).tmp"))
        XCTAssertEqual(DataRemovalPlanner.instanceLockFile, InstanceLock.fileName)
        XCTAssertTrue(DataRemovalPlanner.isKeelFile(InstanceLock.fileName), "The MAC-17 lock goes with the folder")
        for name in ["id_rsa", "config", "known_hosts", "connections.json.bak", "connections.corrupt.x.json", ".windows.tmp", "export.json", "trellis.json"] {
            XCTAssertFalse(DataRemovalPlanner.isKeelFile(name), name)
        }
    }

    /// Anything else in the folder stays, and so does the folder.
    func testUnknownEntriesKeepTheFolder() throws {
        try write("connections.json", in: state)
        try write("notes.txt", in: state)
        try fm.createDirectory(at: state.appendingPathComponent("settings.json"), withIntermediateDirectories: false)  // a folder with a Keel name
        let plan = DataRemovalPlanner.plan(stateDirectory: state, home: home, keychain: FakeKeychain([]), storedPreferenceKeys: [])
        XCTAssertEqual(plan.files, ["connections.json"])
        XCTAssertEqual(plan.keptEntries, ["notes.txt", "settings.json"])
        XCTAssertFalse(plan.removesDirectory)
        XCTAssertEqual(DataRemovalPlanner.execute(plan, keychain: FakeKeychain([])) { _ in }.failures, [])
        XCTAssertFalse(exists("connections.json", in: state))
        XCTAssertTrue(exists("notes.txt", in: state))
        XCTAssertTrue(exists("settings.json", in: state))
    }

    /// `--state-directory` pointed at home, above it, or into ~/.ssh: nothing there is removed.
    func testProtectedStateFoldersAreRefused() throws {
        try write(".ssh/config")
        try write("settings.json")
        for directory in [home!, home.deletingLastPathComponent(), URL(fileURLWithPath: "/"), home.appendingPathComponent(".ssh"), home.appendingPathComponent(".ssh/keel")] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let plan = DataRemovalPlanner.plan(stateDirectory: directory, home: home, keychain: FakeKeychain([]), storedPreferenceKeys: [])
            XCTAssertNotNil(plan.refusal, directory.path)
            XCTAssertEqual(plan.files, [], directory.path)
            XCTAssertFalse(plan.removesDirectory, directory.path)
            _ = DataRemovalPlanner.execute(plan, keychain: FakeKeychain([])) { _ in }
        }
        XCTAssertTrue(exists(".ssh/config"))
        XCTAssertTrue(exists("settings.json"))
    }

    /// A state folder that became a link is not followed.
    func testSymlinkedStateFolderIsRefused() throws {
        let target = home.appendingPathComponent("elsewhere", isDirectory: true)
        try write("connections.json", in: target)
        let link = home.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let plan = DataRemovalPlanner.plan(stateDirectory: link, home: home, keychain: FakeKeychain([]), storedPreferenceKeys: [])
        XCTAssertNotNil(plan.refusal)
        _ = DataRemovalPlanner.execute(plan, keychain: FakeKeychain([])) { _ in }
        XCTAssertTrue(exists("elsewhere/connections.json"))
    }

    /// A locked Keychain service is reported and its items stay; a failed removal is reported and the rest still goes.
    func testKeychainFailuresAreReported() throws {
        try write("windows.json", in: state)
        let id = UUID().uuidString
        let keychain = FakeKeychain([("Keel Connection", id), ("Keel TLS", id), ("Keel SSH Host", id)])
        keychain.unreadable = ["Keel TLS"]
        let plan = DataRemovalPlanner.plan(stateDirectory: state, home: home, keychain: keychain, storedPreferenceKeys: [])
        XCTAssertEqual(plan.unreadableServices.count, 1)
        XCTAssertTrue(plan.summary.contains { $0.contains("Keel TLS") && $0.contains("stay") })
        keychain.failsRemoving = ["Keel SSH Host"]
        let result = DataRemovalPlanner.execute(plan, keychain: keychain) { _ in }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(keychain.remaining, [.init(service: "Keel TLS", account: id), .init(service: "Keel SSH Host", account: id)])
        XCTAssertFalse(fm.fileExists(atPath: state.path))
    }

    func testMissingFolderAndNoItemsIsEmpty() {
        let plan = DataRemovalPlanner.plan(stateDirectory: home.appendingPathComponent("absent"), home: home, keychain: FakeKeychain([]), storedPreferenceKeys: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary, [])
    }
}
