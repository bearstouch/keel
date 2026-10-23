import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A server for the connector: `HELLO` is unknown (the RESP2 path), `AUTH` checks `secret`, then `INFO`, `COMMAND`
/// and `CONFIG GET databases`. Every connection opened is kept, so tests see each trace and whether it was closed.
final class ConnectorServer: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [RecordingTransport] = []
    let version: String
    let mode: String

    init(version: String = "7.4.1", mode: String = "standalone") { self.version = version; self.mode = mode }

    var opened: [RecordingTransport] { lock.withLock { transports } }

    func makeConnection(_ endpoint: RedisEndpoint, _ tls: TLSConfiguration?, _ options: RedisConnection.Options) -> RedisConnection {
        let version = version, mode = mode
        let transport = RecordingTransport { arguments in
            switch arguments.first?.uppercased() {
            case "HELLO": return "-ERR unknown command 'HELLO'\r\n"
            case "AUTH": return arguments.last == "secret" ? "+OK\r\n" : "-WRONGPASS invalid username-password pair\r\n"
            case "CLIENT", "SELECT": return "+OK\r\n"
            case "INFO":
                let text = arguments.last == "server" ? "# Server\r\nredis_version:\(version)\r\nredis_mode:\(mode)\r\n" : "# Replication\r\nrole:master\r\n"
                return "$\(text.utf8.count)\r\n\(text)\r\n"
            case "COMMAND": return "*0\r\n"
            case "CONFIG": return "*2\r\n$9\r\ndatabases\r\n$2\r\n32\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
        lock.withLock { transports.append(transport) }
        return RedisConnection(transport: transport, options: options)
    }
}

final class SessionConnectorTests: XCTestCase {
    private func store(_ settings: ConnectionSettings, password: String? = nil) async throws -> (ProfileStore, ConnectionProfile) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-connector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: FakeSecretStore())
        _ = await store.load()
        let profile = try await store.create(settings, password: password.map { Data($0.utf8) })
        return (store, profile)
    }

    func testConnectsIdentifiesAndProbesThroughOneBrowserConnection() async throws {
        let (store, profile) = try await store(ConnectionSettings(name: "cache", database: 3, readOnly: true, separator: "/"), password: "secret")
        let server = ConnectorServer()
        let connector = ProfileSessionConnector(profiles: store, makeConnection: server.makeConnection)
        let connected = try await connector.connect(profileID: profile.id, database: 3).get()

        XCTAssertEqual(connected.identity.kind, .redis)
        XCTAssertEqual(connected.identity.version, ServerVersion("7.4.1"))
        XCTAssertEqual(connected.identity.role, "master")
        XCTAssertEqual(connected.databaseCount, 32)
        XCTAssertEqual(connected.safety, SafetyProfile(name: "cache", readOnly: true))
        XCTAssertEqual(connected.separator, NamespaceSeparator(Data("/".utf8)))
        // One connection: the handshake with the saved password and the tab's database, then identification.
        XCTAssertEqual(server.opened.count, 1)
        let commands = try XCTUnwrap(server.opened.first).commands
        XCTAssertEqual(commands.prefix(4).map { $0.first ?? "" }, ["HELLO", "AUTH", "CLIENT", "SELECT"])
        XCTAssertEqual(commands[3], ["SELECT", "3"])
        XCTAssertTrue(commands.contains(["INFO", "server"]))
        XCTAssertTrue(commands.contains(["CONFIG", "GET", "databases"]))
        XCTAssertFalse(commands.contains { $0.first == "KEYS" })

        // Commands then go through the data path and its policy: a write on a read-only profile sends nothing.
        let before = server.opened.first?.commands.count
        do {
            _ = try await connected.service.execute(.raw([Data("SET".utf8), Data("k".utf8), Data("v".utf8)]), origin: .browser, context: DataContext(profile: connected.safety, database: 3))
            XCTFail("read-only refuses SET")
        } catch {}
        XCTAssertEqual(server.opened.first?.commands.count, before)

        await connected.close()
        await connected.close()
        XCTAssertTrue(server.opened.allSatisfy(\.isClosed))
    }

    func testRefusedServerClosesEverything() async throws {
        let (store, profile) = try await store(ConnectionSettings(name: "old"))
        let server = ConnectorServer(version: "5.0.7")
        let connector = ProfileSessionConnector(profiles: store, makeConnection: server.makeConnection)
        guard case .failure(let failure) = await connector.connect(profileID: profile.id, database: 0) else { return XCTFail("Redis 5 is below the minimum") }
        XCTAssertEqual(failure.category, .unsupportedServer)
        XCTAssertFalse(server.opened.isEmpty)
        XCTAssertTrue(server.opened.allSatisfy(\.isClosed), "nothing stays open after a refused connect")
    }

    func testWrongPasswordAndMissingProfileFail() async throws {
        let (store, profile) = try await store(ConnectionSettings(name: "cache"), password: "nope")
        let server = ConnectorServer()
        let connector = ProfileSessionConnector(profiles: store, makeConnection: server.makeConnection)
        guard case .failure(let auth) = await connector.connect(profileID: profile.id, database: 0) else { return XCTFail("wrong password") }
        XCTAssertEqual(auth.category, .authFailed)
        XCTAssertTrue(server.opened.allSatisfy(\.isClosed))
        guard case .failure(let missing) = await connector.connect(profileID: UUID(), database: 0) else { return XCTFail("no such profile") }
        XCTAssertEqual(missing.message, "This connection no longer exists.")
    }

    func testRestorableWindows() {
        let kept = UUID(), deleted = UUID()
        let shared = SavedTab(profileID: kept, database: 1)
        let document = WindowsDocument(windows: [
            SavedWindow(tabs: [shared, SavedTab(profileID: deleted, database: 0)], selectedTabID: UUID()),
            // The same tab ID twice (a hand-edited file): only the first copy is restored.
            SavedWindow(tabs: [shared, SavedTab(profileID: deleted, database: 2)])
        ])
        let restored = document.restorable(profileIDs: [kept])
        XCTAssertEqual(restored.windows.map(\.tabs), [[shared], []])
        XCTAssertEqual(restored.windows.first?.selectedTabID, shared.id, "a selection naming no tab falls back to the first")
        XCTAssertNil(restored.windows.last?.selectedTabID)
        let many = WindowsDocument(windows: (0..<100).map { _ in SavedWindow(tabs: (0..<200).map { _ in SavedTab(profileID: kept, database: 0) }) })
        let bounded = many.restorable(profileIDs: [kept])
        XCTAssertEqual(bounded.windows.count, WindowsDocument.maximumWindows)
        XCTAssertEqual(bounded.windows.first?.tabs.count, WindowsDocument.maximumTabsPerWindow)
    }
}
