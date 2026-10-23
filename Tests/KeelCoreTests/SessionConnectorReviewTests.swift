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
