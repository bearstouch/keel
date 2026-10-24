import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class WelcomeModelReviewTests: XCTestCase {
    /// Remove Keel Data… on quit: once the windows are flushed and saving stops, a later change (a tab opened, a recent
    /// recorded) writes nothing, so `windows.json` can't come back after the removal.
    @MainActor func testNothingIsSavedAfterStopSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-welcome-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "cache"))
        let persistence = Persistence<WindowsDocument>(directory: directory, debounce: .zero)
        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: persistence)
        await app.restore()
        await app.flush()
        app.stopSaving()
        try FileManager.default.removeItem(at: persistence.fileURL)
        _ = try XCTUnwrap(app.windows.first).open(profileID: profile.id, database: 0)
        await app.flush()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
        XCTAssertEqual(app.recentProfileIDs, [profile.id], "The model still updates; only the file stays gone")
    }
}
