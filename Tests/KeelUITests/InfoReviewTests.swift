import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review-driven checks for Info mode's visibility (KEEL-042, AC2).
@MainActor
final class InfoReviewTests: XCTestCase {
    /// A tab moved between windows appears in the new one before it leaves the old: it stays visible, then stops.
    func testOverlappingPanesKeepTheModelVisible() async throws {
        let server = InfoServer(text: "# Server\r\nredis_version:7.2.1\r\n"), sleeper = ManualSleeper()
        let model = server.model(sleeper: sleeper)
        model.interval = .five
        model.appeared(); model.appeared()
        try await waitUntil { server.infoCommands.count == 1 && sleeper.pending == 1 }
        model.disappeared()
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(sleeper.pending, 1)
        model.disappeared()
        XCTAssertFalse(model.isVisible)
        try await waitUntil { sleeper.pending == 0 }

        // A disconnect stops it whatever the count, and an extra disappear doesn't go negative.
        model.appeared(); model.appeared()
        try await waitUntil { sleeper.pending == 1 }
        model.shutdown()
        XCTAssertFalse(model.isVisible)
        try await waitUntil { sleeper.pending == 0 }
        model.disappeared()
        model.appeared()
        XCTAssertTrue(model.isVisible)
        model.disappeared()
        XCTAssertFalse(model.isVisible)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}
