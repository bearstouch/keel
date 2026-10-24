import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// KEEL-049, FR-AP09: what Core reads from the applied settings — each new scan the Browser pane, each connect the
/// Advanced and Console panes. A profile's own values win.
final class AppSettingsTests: XCTestCase {
    /// AC2 at the index: an Apply between scans changes the next scan's `COUNT`, limit and tree, never the running one.
    func testRestartTakesTheAppliedBrowserSettings() async {
        let fake = ScanServer(pages: [["a/b:1", "a/b:2"], ["a/c:3"]])
        let snapshot = SettingsSnapshot()
        let index = KeyIndex(
            service: DataCommandService(session: fake.server.session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)), separator: nil,
            defaults: { snapshot.current.browser })
        await index.loadMore()
        snapshot.current.browser = BrowserSettings(separator: "/", pageSize: 10, autoPageLimit: 1_000)
        await index.loadMore()
        XCTAssertEqual(fake.scans.map { $0.last }, ["1000", "1000"], "the scan under way keeps its page size")
        var rows = await index.namespaceEntries(await index.namespaceChildren()).map { String(decoding: $0.name, as: UTF8.self) }
        XCTAssertEqual(rows, ["a/b", "a/c"], "still split at `:`")

        await index.restart()
        await index.loadMore()
        XCTAssertEqual(fake.scans.last, ["SCAN", "0", "COUNT", "10"])
        rows = await index.namespaceEntries(await index.namespaceChildren()).map { String(decoding: $0.name, as: UTF8.self) }
        XCTAssertEqual(rows, ["a"], "split at `/` now")
        let status = await index.status
        XCTAssertEqual(status.limit, 1_000)
    }

    /// A connect uses Advanced's timeouts and `CLIENT SETNAME` choice, and only the console's connection asks for
    /// Console's protocol; a profile's own timeout wins.
    func testConnectUsesAdvancedAndConsoleSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-settings-connect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: FakeSecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache", commandTimeoutMilliseconds: 2_000), password: Data("secret".utf8))
        var document = SettingsDocument()
        document.advanced = AdvancedSettings(connectTimeoutMilliseconds: 3_000, commandTimeoutMilliseconds: 60_000, setsClientName: false)
        document.console.protocolVersion = 2
        let snapshot = SettingsSnapshot(document)
        let server = ConnectorServer()
        let options = OptionsLog()
        let connector = ProfileSessionConnector(
            profiles: store,
            makeConnection: {
                options.append($2); return server.makeConnection($0, $1, $2)
            }, settings: { snapshot.current })
        let connected = try await connector.connect(profileID: profile.id, database: 0).get()
        _ = try await connected.session.connection(for: .console(UUID()), database: 0)

        XCTAssertEqual(options.all.first?.connectTimeout, .seconds(3))
        XCTAssertEqual(options.all.first?.commandTimeout, .seconds(2), "the profile's own timeout wins")
        let browser = try XCTUnwrap(server.opened.first).commands, console = try XCTUnwrap(server.opened.last).commands
        XCTAssertEqual(server.opened.count, 2)
        XCTAssertEqual(browser.first, ["HELLO", "3", "AUTH", "default", "secret"])
        XCTAssertEqual(console.first, ["HELLO", "2", "AUTH", "default", "secret"])
        XCTAssertFalse((browser + console).contains { $0.contains("SETNAME") }, "CLIENT SETNAME is off")
        await connected.close()
    }
}

final class OptionsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [RedisConnection.Options] = []

    func append(_ value: RedisConnection.Options) { lock.withLock { options.append(value) } }
    var all: [RedisConnection.Options] { lock.withLock { options } }
}
