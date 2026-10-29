import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class SessionConnectorReviewTests: XCTestCase {
    /// A browser task still running after Disconnect must not open a fresh connection nobody will close.
    func testNothingReopensAfterClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-connector-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: FakeSecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let server = ConnectorServer()
        let connected = try await ProfileSessionConnector(profiles: store, makeConnection: server.makeConnection).connect(profileID: profile.id, database: 0).get()
        await connected.close()
        let opened = server.opened.count

        do {
            _ = try await connected.service.execute(.operation(.info(section: Data("server".utf8))), origin: .browser, context: DataContext(profile: connected.safety, database: 0))
            XCTFail("a closed session sends nothing")
        } catch {}
        XCTAssertEqual(server.opened.count, opened, "no connection opened after close")
        XCTAssertTrue(server.opened.allSatisfy(\.isClosed))
    }

    /// The tab closed while connecting (its task cancelled mid-connect): the connect fails and nothing stays open.
    func testCancelledConnectLeavesNothingOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-connector-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: FakeSecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let server = ConnectorServer()
        // Cancels the connecting task as its first connection opens, like Close Tab during the handshake.
        let connector = ProfileSessionConnector(
            profiles: store,
            makeConnection: { endpoint, tls, options in
                withUnsafeCurrentTask { $0?.cancel() }
                return server.makeConnection(endpoint, tls, options)
            })
        let result = await Task { await connector.connect(profileID: profile.id, database: 0) }.value
        guard case .failure = result else { return XCTFail("A cancelled connect must not hand out a session") }
        XCTAssertFalse(server.opened.isEmpty)
        XCTAssertTrue(server.opened.allSatisfy(\.isClosed), "nothing stays open after a cancelled connect")
    }

    func testRepeatedWindowIDsRestoreOnce() {
        let profile = UUID()
        let window = SavedWindow(tabs: [SavedTab(profileID: profile, database: 0)])
        var copy = SavedWindow(id: window.id, tabs: [SavedTab(profileID: profile, database: 1)])
        copy.frame = SavedFrame(x: 0, y: 0, width: 800, height: 600)
        let restored = WindowsDocument(windows: [window, copy]).restorable(profileIDs: [profile])
        XCTAssertEqual(restored.windows.map(\.id), [window.id])
        XCTAssertEqual(restored.windows.first?.tabs, window.tabs)
        XCTAssertNil(restored.windows.first?.frame)
    }
}
