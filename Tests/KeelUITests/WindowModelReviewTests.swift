import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class WindowModelReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-windows-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A `connections.json` waiting for recovery has no profiles: its tabs can't restore, but `windows.json` keeps them
    /// for when the profiles come back.
    @MainActor func testUnusableConnectionsFileNeverDropsSavedTabs() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        try XCTUnwrap(app.windows.first).open(profileID: profile.id, database: 4)
        await app.flush()
        let saved = app.document

        try Data("{ not json".utf8).write(to: directory.appendingPathComponent(PersistedFile.connections.fileName))
        let broken = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await broken.load()
        let relaunched = AppModel(profiles: broken, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await relaunched.restore()
        XCTAssertEqual(relaunched.windows.first?.tabs.count, 0)
        relaunched.newWindow()
        await relaunched.flush()

        guard case .loaded(let onDisk) = await Persistence<WindowsDocument>(directory: directory).load() else { return XCTFail("windows.json readable") }
        XCTAssertEqual(onDisk, saved)
    }

    /// ⌘N while `windows.json` is still being read: that window stays in the model (and is saved) with the restored ones.
    @MainActor func testWindowOpenedBeforeRestoreIsKept() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let first = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await first.restore()
        try XCTUnwrap(first.windows.first).open(profileID: profile.id, database: 0)
        await first.flush()

        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        let early = app.newWindow()
        let restored = await app.restore()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(app.windows.last === early)
        early.open(profileID: profile.id, database: 2)
        XCTAssertNotNil(app.session(try XCTUnwrap(early.selectedID)))
        XCTAssertEqual(app.document.windows.count, 2)
    }
}
