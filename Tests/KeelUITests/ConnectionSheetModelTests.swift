import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// An in-memory Keychain: counts every item so a test can prove nothing was written.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var writes = 0

    var itemCount: Int { lock.withLock { items.count } }
    var writeCount: Int { lock.withLock { writes } }
    func item(_ secret: ProfileSecret, _ id: UUID) -> Data? { lock.withLock { items["\(secret.rawValue)/\(id)"] } }

    func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data? { lock.withLock { items["\(secret.rawValue)/\(profileID)"] } }
    func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) {
        lock.withLock {
            writes += 1; items["\(secret.rawValue)/\(profileID)"] = data
        }
    }
    func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) { lock.withLock { items["\(secret.rawValue)/\(profileID)"] = nil } }
}

/// Records what Test was asked to connect with and answers with `result`.
final class FakeConnectionTester: ConnectionTesting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(ConnectionSettings, Data?)] = []
    let result: Result<ConnectionTestResult, ConnectionFailure>

    init(
        result: Result<ConnectionTestResult, ConnectionFailure> = .success(
            ConnectionTestResult(
                identity: ServerIdentity(kind: .redis, version: ServerVersion("7.4.1"), redisCompatibleVersion: ServerVersion("7.4.1"), mode: .standalone, role: "master"),
                roundTrip: .milliseconds(2)))
    ) {
        self.result = result
    }

    var calls: [(settings: ConnectionSettings, password: Data?)] { lock.withLock { log.map { ($0.0, $0.1) } } }

    func test(_ settings: ConnectionSettings, password: Data?, profileID: UUID?) async -> Result<ConnectionTestResult, ConnectionFailure> {
        lock.withLock { log.append((settings, password)) }
        return result
    }
}

final class ConnectionSheetModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(_ secrets: MemorySecretStore, in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: secrets)
        _ = await store.load()
        return store
    }

    private var connectionsFile: URL { directory.appendingPathComponent(PersistedFile.connections.fileName) }

    @MainActor func testPasteURLFillsFields() async {
        let secrets = MemorySecretStore()
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: await Self.makeStore(secrets, in: directory))
        model.urlText = "rediss://app:p%40ss@cache.internal:6380/2?ssl_cert_reqs=none"
        model.urlTextChanged()
        XCTAssertEqual(model.host, "cache.internal")
        XCTAssertEqual(model.port, "6380")
        XCTAssertEqual(model.username, "app")
        XCTAssertEqual(model.password, "p@ss")
        XCTAssertEqual(model.database, "2")
        XCTAssertTrue(model.tlsEnabled)
        XCTAssertEqual(model.name, "cache.internal", "A blank name takes the host")
        XCTAssertEqual(model.urlText, "", "The URL, which holds the password, doesn't linger in the field")
        XCTAssertEqual(model.urlMessage, "Ignored: ssl_cert_reqs")

        // ⌘V on the sheet does the same; a refused URL changes nothing.
        XCTAssertTrue(model.paste("redis://10.0.0.5"))
        XCTAssertEqual(model.host, "10.0.0.5")
        XCTAssertFalse(model.tlsEnabled)
        XCTAssertFalse(model.paste("hello"))
        XCTAssertFalse(model.applyURL("redis://h:99999"))
        XCTAssertEqual(model.host, "10.0.0.5")
        XCTAssertEqual(model.urlMessage, RedisURLError.invalidPort.message)
        XCTAssertEqual(secrets.writeCount, 0, "Pasting never writes the Keychain")
    }

    @MainActor func testCancelLeavesNoSecrets() async {
        let secrets = MemorySecretStore()
        let store = await Self.makeStore(secrets, in: directory)
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: store)
        model.paste("redis://:hunter2@db.example:6379")
        XCTAssertEqual(model.password, "hunter2")
        model.test(); await model.waitForTest()
        model.cancel()
        XCTAssertEqual(model.outcome, .cancelled)
        XCTAssertEqual(model.password, "", "The pasted password is wiped from memory")
        XCTAssertEqual(secrets.itemCount, 0)
        XCTAssertEqual(secrets.writeCount, 0, "Nothing reached the Keychain")
        let profiles = await store.profiles
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: connectionsFile.path), "connections.json was never written")
        let saved = await model.save()
        XCTAssertNil(saved, "A cancelled sheet can't save afterwards")
        XCTAssertEqual(secrets.writeCount, 0)
    }

    @MainActor func testValidationBlocksSave() async {
        let secrets = MemorySecretStore()
        let store = await Self.makeStore(secrets, in: directory)
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: store)
        XCTAssertTrue(model.canSave, "The defaults are a valid local profile (AC1)")
        model.host = "  "
        XCTAssertEqual(model.invalidField, .host)
        XCTAssertFalse(model.canSave)
        model.host = "127.0.0.1"
        for bad in ["0", "65536", "-1", "abc", ""] {
            model.port = bad
            XCTAssertEqual(model.invalidField, .port, bad)
        }
        let blocked = await model.save()
        XCTAssertNil(blocked)
        XCTAssertEqual(model.saveError, ConnectionSheetModel.message(for: .port))
        model.password = "pw"
        model.test(); await model.waitForTest()
        XCTAssertEqual(model.visibleTestStatus, .invalid(ConnectionSheetModel.message(for: .port)), "Test refuses too, without connecting")

        // A plain local profile: no collapsed row opened, nothing but Save (AC1).
        model.port = "6379"
        let saved = await model.save()
        XCTAssertEqual(saved?.settings.host, "127.0.0.1")
        XCTAssertEqual(saved?.settings.name, "127.0.0.1")
        XCTAssertEqual(saved?.hasPassword, true)
        XCTAssertTrue(model.expanded.isEmpty)
        if let saved { XCTAssertEqual(secrets.item(.password, saved.id), Data("pw".utf8)) }
        XCTAssertEqual(model.outcome, saved.map { .saved($0) })
        XCTAssertEqual(model.password, "")
    }

    @MainActor func testTestConnectionDoesNotPersist() async throws {
        let secrets = MemorySecretStore()
        let store = await Self.makeStore(secrets, in: directory)
        let tester = FakeConnectionTester()
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: tester, store: store)
        model.host = "redis.local"; model.password = "s3cret"; model.label = .green
        model.test(); await model.waitForTest()
        XCTAssertEqual(model.visibleTestStatus, .succeeded("✓ Connected · Redis 7.4.1 · standalone · 2 ms"))
        XCTAssertEqual(tester.calls.count, 1)
        XCTAssertEqual(tester.calls.first?.settings.host, "redis.local")
        XCTAssertEqual(tester.calls.first?.password, Data("s3cret".utf8))
        XCTAssertEqual(secrets.writeCount, 0)
        let profiles = await store.profiles
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: connectionsFile.path))
        XCTAssertNil(model.outcome, "Test keeps the sheet open")

        // The line describes what was tested: editing a field hides it.
        model.host = "other.local"
        XCTAssertEqual(model.visibleTestStatus, .idle)

        let failing = FakeConnectionTester(result: .failure(ConnectionFailure(category: .authFailed, message: "This server requires a password.", suggestion: "Enter it.")))
        let failed = ConnectionSheetModel(mode: .create(folderID: nil), tester: failing, store: store)
        failed.test(); await failed.waitForTest()
        guard case .failed(let failure) = failed.visibleTestStatus else { return XCTFail("Expected the categorized failure") }
        XCTAssertEqual(failure.category, .authFailed)
    }

    @MainActor func testCollapsedSectionsKeepValues() async throws {
        let store = await Self.makeStore(MemorySecretStore(), in: directory)
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: store)
        model.expanded = [.tls, .tunnel, .advanced]
        model.tlsEnabled = true; model.tlsServerName = "cache.example"; model.tlsCAFile = "/etc/ca.pem"; model.tlsSkipVerification = true
        model.tunnelKind = .inline; model.tunnelDestination = "bastion"; model.tunnelUser = "ops"; model.tunnelPort = "2222"
        model.database = "3"; model.connectTimeout = "5000"; model.separator = "/"; model.clientName = "keel-dev"
        model.expanded = []
        XCTAssertEqual(model.tlsServerName, "cache.example")
        XCTAssertEqual(model.tunnelDestination, "bastion")
        XCTAssertEqual(model.database, "3")
        let settings = try model.settings()
        XCTAssertEqual(settings.tls, TLSSettings(serverName: "cache.example", caFile: "/etc/ca.pem", skipVerification: true))
        XCTAssertEqual(settings.tunnel, .inline(destination: "bastion", user: "ops", port: 2222, identityFile: nil))
        XCTAssertEqual(settings.database, 3)
        XCTAssertEqual(settings.connectTimeoutMilliseconds, 5000)
        XCTAssertEqual(settings.separator, "/")
        XCTAssertEqual(settings.clientName, "keel-dev")

        // A problem inside a closed row is attributed to it, so the row can say so.
        model.tunnelPort = "99999"
        XCTAssertEqual(model.invalidField, .tunnel)
        XCTAssertEqual(ConnectionSheetModel.section(of: .tunnel), .tunnel)

        // Edit Connection is the same sheet, filled from the profile; a rename keeps the saved password.
        model.tunnelPort = "2222"
        let created = await model.save()
        let saved = try XCTUnwrap(created)
        let edit = ConnectionSheetModel(mode: .edit(saved), tester: FakeConnectionTester(), store: store)
        XCTAssertEqual(edit.title, "Edit Connection")
        XCTAssertEqual(try edit.settings(), saved.settings)
        edit.name = "renamed"
        let edited = await edit.save()
        let updated = try XCTUnwrap(edited)
        XCTAssertEqual(updated.settings.name, "renamed")
        XCTAssertEqual(updated.connectionRevision, saved.connectionRevision)
    }
}
