import Combine
import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Holds every test until `open()`, so a test can cancel the sheet while Test is still running.
private final class GatedTester: ConnectionTesting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var started = 0

    func open() {
        let pending = lock.withLock {
            isOpen = true; defer { waiters = [] }; return waiters
        }
        pending.forEach { $0.resume() }
    }

    func test(_ settings: ConnectionSettings, password: Data?, profileID: UUID?) async -> Result<ConnectionTestResult, ConnectionFailure> {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                started += 1
                if isOpen { return true }
                waiters.append(continuation); return false
            }
            if resume { continuation.resume() }
        }
        return await FakeConnectionTester().test(settings, password: password, profileID: profileID)
    }
}

final class ConnectionSheetModelReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-sheet-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    /// Typing a URL one character at a time must not apply "redis://c" and clear the field mid-word; Return applies it.
    @MainActor func testTypingAURLWaitsForReturn() async {
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: await Self.makeStore(in: directory))
        for character in "redis://cache:6380" {
            model.urlText.append(character); model.urlTextChanged()
        }
        XCTAssertEqual(model.urlText, "redis://cache:6380")
        XCTAssertEqual(model.host, "127.0.0.1")
        XCTAssertEqual(model.name, "")
        XCTAssertNil(model.urlMessage)
        XCTAssertTrue(model.applyURL(model.urlText))
        XCTAssertEqual(model.host, "cache")
        XCTAssertEqual(model.port, "6380")
        XCTAssertEqual(model.name, "cache")

        // A paste into the field still applies at once.
        model.urlText = "redis://other:7000"; model.urlTextChanged()
        XCTAssertEqual(model.host, "other")
        XCTAssertEqual(model.urlText, "")
    }

    /// Cancel while Test runs: the late result never lands on the closed sheet.
    @MainActor func testCancelDuringTestDropsTheResult() async throws {
        let tester = GatedTester()
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: tester, store: await Self.makeStore(in: directory))
        model.password = "pw"
        model.test()
        XCTAssertEqual(model.visibleTestStatus, .testing)
        model.cancel()
        tester.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.testStatus, .testing, "The cancelled test's result was dropped")
        XCTAssertEqual(model.outcome, .cancelled)
        XCTAssertEqual(model.password, "")
    }

    /// Two ⌘N in a row open one sheet, not one shown and one orphaned.
    @MainActor func testSecondNewConnectionWhilePreparingIsIgnored() async {
        let presenter = ConnectionSheetPresenter(store: await Self.makeStore(in: directory), tester: FakeConnectionTester())
        var built: [ObjectIdentifier] = []
        let watch = presenter.$model.compactMap { $0?.id }.sink { built.append($0) }
        defer { watch.cancel() }
        async let first: Void = presenter.present(.create(folderID: nil))
        async let second: Void = presenter.present(.create(folderID: nil))
        _ = await (first, second)
        let shown = presenter.model
        XCTAssertNotNil(shown)
        XCTAssertEqual(built.count, 1, "Only one sheet was built and shown")
        shown?.cancel()
        XCTAssertNil(presenter.model, "Cancel closes the only sheet")
    }
}
