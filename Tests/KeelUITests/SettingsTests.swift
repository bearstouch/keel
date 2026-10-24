import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// KEEL-049, FR-AP09: the defaults of every pane, `settings.json` read leniently, and new scans taking the applied
/// Browser settings (AC2).
@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsMatchSpec() throws {
        let defaults = SettingsDocument()
        XCTAssertEqual(defaults.theme, .light, "DS-11: Light on first launch")
        XCTAssertTrue(defaults.restoresWindows, "FR-AP01: windows and tabs come back")
        XCTAssertEqual(defaults.browser.separator, ":", "FR-KB03")
        XCTAssertEqual(defaults.browser.pageSize, 1_000, "FR-KB02: COUNT 1,000")
        XCTAssertEqual(defaults.browser.autoPageLimit, 1_000_000, "FR-KB02: loaded-key limit 1,000,000")
        XCTAssertEqual(defaults.browser.configuration(), KeyIndexConfiguration())
        XCTAssertEqual(defaults.editors.defaultViewer, .automatic, "JSON when it parses, else Text")
        XCTAssertNil(defaults.editors.defaultViewer.mode)
        XCTAssertEqual(defaults.console.protocolVersion, 3, "HELLO 3 when the server supports it")
        XCTAssertEqual(defaults.advanced.connectTimeout, ConnectionTester.defaultConnectTimeout)
        XCTAssertEqual(defaults.advanced.commandTimeout, ConnectionTester.defaultCommandTimeout)
        XCTAssertTrue(defaults.advanced.setsClientName, "NFR-PV04: CLIENT SETNAME keel by default")
        // A file written before KEEL-049 (theme only) or an empty one reads as the defaults.
        XCTAssertEqual(try PersistenceCodec.decode(SettingsDocument.self, from: PersistenceCodec.encode(SettingsDocument())), defaults)
        XCTAssertEqual(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)), defaults)
        XCTAssertEqual(try JSONDecoder().decode(SettingsDocument.self, from: Data(#"{"theme":"dark"}"#.utf8)), SettingsDocument(theme: .dark))
    }

    /// A hand-edited bad value reads as that field's default; the others keep their values (no recovery).
    func testInvalidValuesReadAsDefaults() throws {
        let json = #"""
            {"theme":"sepia","restoresWindows":"yes",
             "browser":{"separator":"toolong","pageSize":0,"autoPageLimit":20000000},
             "editors":{"defaultViewer":"pretty"},"console":{"protocolVersion":4},
             "advanced":{"connectTimeoutMilliseconds":5000,"commandTimeoutMilliseconds":1,"setsClientName":false}}
            """#
        let document = try JSONDecoder().decode(SettingsDocument.self, from: Data(json.utf8))
        var expected = SettingsDocument()
        expected.advanced.connectTimeoutMilliseconds = 5_000
        expected.advanced.setsClientName = false
        XCTAssertEqual(document, expected)
    }

    /// AC2: the separator, page size and limit applied in Settings reach the next scan of an open browser (Refresh,
    /// a filter or database change) and every new browser; a profile's own separator still wins.
    func testNewScansUseAppliedBrowserSettings() async {
        let settings = SettingsModel(persistence: nil, applyAppearance: { _ in })
        await settings.load()
        let browser = TabSession.browser(for: Self.server(separator: nil), database: 0, settings: settings.snapshot)
        let index = browser.list.index
        var configuration = await index.configuration
        XCTAssertEqual(configuration.pageSize, 1_000)
        XCTAssertEqual(configuration.limit, 1_000_000)
        var separator = await index.separator
        XCTAssertEqual(separator, .default)

        let draft = SettingsDraft(settings: settings)
        draft.document.browser = BrowserSettings(separator: "/", pageSize: 500, autoPageLimit: 100_000)
        XCTAssertTrue(draft.apply())
        configuration = await index.configuration
        XCTAssertEqual(configuration.pageSize, 1_000, "the scan already running keeps what it started with")

        await index.restart(filter: KeyFilter(pattern: "user:*"))
        configuration = await index.configuration
        XCTAssertEqual(configuration, KeyIndexConfiguration(pageSize: 500, limit: 100_000, filter: KeyFilter(pattern: "user:*")), "the filter is kept")
        separator = await index.separator
        XCTAssertEqual(separator, NamespaceSeparator(Data("/".utf8)))
        let status = await index.status
        XCTAssertEqual(status.limit, 100_000)

        let fresh = TabSession.browser(for: Self.server(separator: nil), database: 0, settings: settings.snapshot)
        configuration = await fresh.list.index.configuration
        XCTAssertEqual(configuration.pageSize, 500)
        separator = await fresh.list.index.separator
        XCTAssertEqual(separator, NamespaceSeparator(Data("/".utf8)))

        let own = TabSession.browser(for: Self.server(separator: NamespaceSeparator(Data("|".utf8))), database: 0, settings: settings.snapshot)
        await own.list.index.restart()
        separator = await own.list.index.separator
        XCTAssertEqual(separator, NamespaceSeparator(Data("|".utf8)), "the profile's separator wins")
    }

    /// Settings → Editors: a key pattern without a remembered viewer opens in the default one.
    func testDefaultViewerAppliesToNewBrowsers() async {
        let settings = SettingsModel(persistence: nil, applyAppearance: { _ in })
        await settings.load()
        var document = settings.applied
        document.editors.defaultViewer = .hex
        settings.apply(document)
        let browser = TabSession.browser(for: Self.server(separator: nil), database: 0, settings: settings.snapshot)
        XCTAssertEqual(browser.viewerChoices.mode(for: Data("user:*".utf8)), .hex)
        browser.viewerChoices.remember(.raw, for: Data("user:*".utf8))
        XCTAssertEqual(browser.viewerChoices.mode(for: Data("user:*".utf8)), .raw, "a choice made in the session wins")
    }

    /// General → "Reopen windows and tabs" off: launch opens one empty window, and the saved file is still read (so one
    /// waiting for recovery is never written over).
    func testRestoreOffOpensOneEmptyWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"), password: nil)
        let first = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        let restored = await first.restore()
        let window = try XCTUnwrap(restored.first?.window)
        _ = window.open(profileID: profile.id, database: 0)
        await first.flush()

        let reopened = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        let again = await reopened.restore()
        XCTAssertEqual(again.first?.window.tabs.count, 1)
        let fresh = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        let windows = await fresh.restore(reopens: false)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.window.tabs.count, 0)
    }

    private static func server(separator: NamespaceSeparator?) -> ConnectedServer {
        let session = ServerSession(open: { _, _ throws(ConnectionFailure) in throw ConnectionFailure(category: .connectionRefused, message: "offline", suggestion: "") })
        let identity = ServerIdentity(kind: .redis, version: ServerVersion("7.4.0"), redisCompatibleVersion: ServerVersion("7.4.0"), mode: .standalone, role: "master")
        return ConnectedServer(
            session: session, service: DataCommandService(session: session), identity: identity, databaseCount: 16, safety: SafetyProfile(name: "t", readOnly: true),
            separator: separator, close: {})
    }
}
