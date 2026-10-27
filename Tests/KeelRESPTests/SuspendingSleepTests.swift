import XCTest

@testable import KeelRESP

/// The cases `Task.sleep` must never see on macOS 26.6 end in the helper itself.
final class SuspendingSleepTests: XCTestCase {
    func testZeroReturnsAtOnce() async throws {
        let start = ContinuousClock.now
        try await Task.suspendingSleep(for: .zero)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(100))
    }

    func testCancelledBeforeSleepingThrowsCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Task.suspendingSleep(for: .seconds(30))
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSleepsForAPositiveDuration() async throws {
        let start = ContinuousClock.now
        try await Task.suspendingSleep(for: .milliseconds(20))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(20))
    }
}
