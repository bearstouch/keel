import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// A clock for auto-refresh: each `sleep` waits until the test fires it, and a cancelled sleep ends at once.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var durations: [Duration] = []

    /// Sleeps in progress.
    var pending: Int { lock.withLock { waiting.count } }
    var requested: [Duration] { lock.withLock { durations } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    waiting[id] = continuation; durations.append(duration)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// The interval elapses for every sleep in progress.
    func fire() {
        lock.withLock {
            defer { waiting = [:] }; return Array(waiting.values)
        }.forEach { $0.resume() }
    }
}

/// An `INFO` server whose reply the test changes; it counts the `INFO` commands it was sent.
final class InfoServer: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[String]] = []
    var reply: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private var stored: String

    init(text: String) { stored = Self.bulk(text) }

    static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }

    var infoCommands: [[String]] { lock.withLock { sent.filter { $0.first == "INFO" } } }

    @MainActor func model(sleeper: ManualSleeper, now: Date = Date(timeIntervalSince1970: 1_729_673_000)) -> InfoModel {
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(
                transport: FakeTransport { arguments in
                    self.lock.withLock {
                        self.sent.append(arguments); return self.stored
                    }
                })
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            return connection
        }
        let context = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: true), database: 0)
        return InfoModel(service: DataCommandService(session: session), context: context, now: { now }, sleep: { try await sleeper.sleep($0) })
    }
}

/// Info mode's refresh (KEEL-042, FR-SI03, FR-SI05): INFO only while the mode is visible; failures keep the last report.
@MainActor
final class InfoRefreshTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/INFO/\(name).txt"),
            encoding: .utf8)
    }

    func testOnlyWhileVisible() async throws {
        let server = InfoServer(text: try fixture("full/valkey-8.x")), sleeper = ManualSleeper()
        let model = server.model(sleeper: sleeper)
        model.interval = .two
        // Not on screen: an interval alone sends nothing and starts no timer.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(server.infoCommands.isEmpty)
        XCTAssertEqual(sleeper.pending, 0)

        // Shown: one bare INFO at once (read-only profile, data path), then one per interval.
        model.appeared()
        try await waitUntil { server.infoCommands.count == 1 && sleeper.pending == 1 && model.overview != nil }
        XCTAssertEqual(server.infoCommands, [["INFO"]])
        XCTAssertEqual(sleeper.requested, [.seconds(2)])
        XCTAssertEqual(model.overview?.tiles.map(\.value), ["1.2", "48", "3,412", "12"])
        sleeper.fire()
        try await waitUntil { server.infoCommands.count == 2 && sleeper.pending == 1 }

        // Hidden: the timer is cancelled; firing it again sends nothing.
        model.disappeared()
        try await waitUntil { sleeper.pending == 0 }
        sleeper.fire()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.infoCommands.count, 2)

        // Back on screen: refreshed at once and the timer resumes; Off stops it while visible.
        model.appeared()
        try await waitUntil { server.infoCommands.count == 3 && sleeper.pending == 1 }
        model.interval = .off
        try await waitUntil { sleeper.pending == 0 }
        sleeper.fire()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.infoCommands.count, 3)
        model.disappeared()
    }

    func testFailuresKeepTheReportAndNopermIsUnavailable() async throws {
        let server = InfoServer(text: try fixture("full/redis-7.2")), sleeper = ManualSleeper()
        let model = server.model(sleeper: sleeper)
        await model.refresh()
        let report = try XCTUnwrap(model.report)
        XCTAssertNil(model.notice)

        // A server error that isn't a permission problem: the last report stays, with the reason.
        server.reply = "-ERR something broke\r\n"
        await model.refresh()
        XCTAssertEqual(model.report, report)
        XCTAssertEqual(model.notice, "ERR something broke")

        // NOPERM: every section is unavailable (AC3), and the notice says why.
        server.reply = "-NOPERM this user has no permissions to run the 'info' command\r\n"
        await model.refresh()
        XCTAssertEqual(model.report?.sectionStatuses, InfoReport.expectedSections.map { .unavailable(name: $0) })
        XCTAssertEqual(model.overview?.tiles.map(\.isAvailable), [false, false, false, false])
        XCTAssertEqual(model.notice, "This user isn't permitted to run INFO, so server details are unavailable.")

        // Recovered: the notice clears.
        server.reply = InfoServer.bulk(try fixture("full/redis-7.2"))
        await model.refresh()
        XCTAssertEqual(model.report, report)
        XCTAssertNil(model.notice)
    }

    func testBrowseCallsTheTab() throws {
        let model = InfoServer(text: "").model(sleeper: ManualSleeper())
        var browsed: [Int] = []
        model.onBrowse = { browsed.append($0) }
        model.browse(3)
        XCTAssertEqual(browsed, [3])
        model.shutdown()
        model.browse(0)
        XCTAssertEqual(browsed, [3])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}
