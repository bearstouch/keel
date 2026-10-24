import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// An in-memory keyspace that answers `SCAN cursor MATCH p COUNT n [TYPE t]` (the cursor is an offset into the keys
/// in insertion order), `UNLINK` (counting keys that still existed) and `DBSIZE`, for the bulk-delete tests.
final class BulkKeyspace: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String]
    private var present: Set<String>
    /// Called with each UNLINK's keys while its reply is being made, i.e. while the batch is in flight.
    var onUnlink: (@Sendable ([String]) -> Void)?
    /// Answers UNLINK with this instead of the count (a server error).
    var unlinkReply: String?

    init(_ keys: [String]) { self.keys = keys; present = Set(keys) }

    var remaining: Set<String> { lock.withLock { present } }

    func answer(_ arguments: [String]) -> String {
        switch arguments.first?.uppercased() {
        case "SCAN":
            let page: (cursor: Int, keys: [String]) = lock.withLock {
                let start = Int(arguments[1]) ?? 0
                let count = arguments.firstIndex(of: "COUNT").map { Int(arguments[$0 + 1]) ?? 10 } ?? 10
                let match = arguments.firstIndex(of: "MATCH").map { Data(arguments[$0 + 1].utf8) }
                let end = min(start + count, keys.count)
                let found = keys[start..<end].filter { key in present.contains(key) && (match.map { GlobPattern.matches($0, Data(key.utf8)) } ?? true) }
                return (end == keys.count ? 0 : end, found)
            }
            return "*2\r\n" + Self.bulk(String(page.cursor)) + "*\(page.keys.count)\r\n" + page.keys.map(Self.bulk).joined()
        case "UNLINK":
            let batch = Array(arguments.dropFirst())
            onUnlink?(batch)
            if let unlinkReply { return unlinkReply }
            let deleted = lock.withLock { batch.filter { present.remove($0) != nil }.count }
            return ":\(deleted)\r\n"
        case "DBSIZE":
            return ":\(lock.withLock { present.count })\r\n"
        default:
            return "+OK\r\n"
        }
    }

    static func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }
}

/// A clock that only moves when the job sleeps: the throttle's waits are recorded, not waited.
final class BulkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private(set) var sleeps: [Duration] = []

    var now: Duration { lock.withLock { time } }

    var clock: BulkDeleteJob.Clock {
        BulkDeleteJob.Clock(
            now: { self.now },
            sleep: { duration in
                self.lock.withLock {
                    self.time += duration; self.sleeps.append(duration)
                }
            })
    }
}

/// The bulk-delete tests' shared setup (no tests of its own, so subclasses don't run any twice).
class BulkDeleteJobFixture: XCTestCase {
    let writable = SafetyProfile(name: "api-staging", readOnly: false)
    let pattern = Data("tmp:import:*".utf8)

    func keyspace(matching: Int, other: Int = 0) -> BulkKeyspace {
        BulkKeyspace((0..<matching).map { "tmp:import:\($0)" } + (0..<other).map { "user:\($0)" })
    }

    func job(_ keyspace: BulkKeyspace, server: RecordingServer, throttle: Int? = nil, clock: BulkClock = BulkClock(), profile: SafetyProfile? = nil) throws -> BulkDeleteJob {
        try BulkDeleteJob(
            pattern: pattern, throttle: throttle, service: DataCommandService(session: server.session()), profile: profile ?? writable, database: 0, clock: clock.clock)
    }

    func run(_ job: BulkDeleteJob) async -> BulkDeleteJob.Report {
        await job.run(confirmation: BulkDeleteJob.confirmation(for: job.pattern, database: 0))
    }

    func unlinks(_ server: RecordingServer) -> [[String]] { server.allCommands.filter { $0.first == "UNLINK" } }
}

/// Bulk delete by pattern (FR-SF05) with its throttle (FR-SF06).
final class BulkDeleteJobTests: BulkDeleteJobFixture {
    // MARK: - Story tests

    func testCancelStopsAfterCurrentBatch() async throws {
        let keyspace = keyspace(matching: 5_000)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        // AC1: Cancel arrives while the second batch is in flight; that batch completes and no other is sent.
        keyspace.onUnlink = { [weak job] _ in if keyspace.remaining.count == 4_000 { job?.cancel() } }
        let report = await run(job)
        XCTAssertEqual(report.failure, .cancelled)
        XCTAssertEqual(unlinks(server).count, 2)
        XCTAssertEqual(report.deleted, 2_000, "the in-flight batch finished and counted")
        XCTAssertEqual(keyspace.remaining.count, 3_000)
        XCTAssertTrue(report.summary.contains("cancelled"))
    }

    func testThrottle() async throws {
        let keyspace = keyspace(matching: 6_000)
        let clock = BulkClock()
        let sentAt = Recorder<Duration>()
        let server = RecordingServer { arguments in
            if arguments.first == "UNLINK" { sentAt.append(clock.now) }
            return keyspace.answer(arguments)
        }
        let report = await run(try job(keyspace, server: server, throttle: 2, clock: clock))
        XCTAssertTrue(report.isComplete)
        let times = sentAt.values
        XCTAssertEqual(times.count, 6)
        // AC3: with throttle 2, no one-second window [t, t+1) holds more than 2 UNLINK batches.
        for start in times {
            XCTAssertLessThanOrEqual(times.filter { $0 >= start && $0 < start + .seconds(1) }.count, 2)
        }
        XCTAssertEqual(times.last, .milliseconds(2_500))
        // Unthrottled sends without waiting.
        let fast = BulkClock()
        let other = self.keyspace(matching: 3_000)
        _ = await run(try job(other, server: RecordingServer { other.answer($0) }, throttle: nil, clock: fast))
        XCTAssertTrue(fast.sleeps.isEmpty)
    }

    func testRefusesStarPattern() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        for refused in ["*", "**", ""] {
            XCTAssertThrowsError(try BulkDeleteJob(pattern: Data(refused.utf8), service: service, profile: writable, database: 0)) { error in
                XCTAssertEqual((error as? DataCommandError)?.code, "INVALID_PARAMS")
            }
        }
        // The policy agrees: a confirmation for `**` covers no delete.
        let context = DataContext(profile: writable, jobID: UUID(), confirmation: BulkDeleteJob.confirmation(for: Data("**".utf8), database: 0))
        do {
            _ = try await service.execute(.operation(.delete(keys: args("a", "b"))), origin: .bulk, context: context)
            XCTFail("a delete under a match-everything pattern ran")
        } catch {
            XCTAssertEqual(error.code, "CONFIRMATION_REQUIRED")
        }
        XCTAssertTrue(server.allCommands.isEmpty, "nothing was sent")
        XCTAssertNotNil(BulkDeleteJob.refusal(pattern: Data("*".utf8), type: nil)?.contains("FLUSHDB"))
    }

    func testReportCounts() async throws {
        let keyspace = keyspace(matching: 2_500, other: 700)
        let server = RecordingServer { keyspace.answer($0) }
        let report = await run(try job(keyspace, server: server))
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.progress.scans, 4, "3,200 keys at COUNT 1000")
        XCTAssertEqual(report.progress.matched, 2_500)
        XCTAssertEqual(report.deleted, 2_500)
        XCTAssertEqual(unlinks(server).map { $0.count - 1 }, [1_000, 1_000, 500])
        XCTAssertEqual(keyspace.remaining.count, 700, "keys outside the pattern stay")
        // AC4: the deleted count and the SCAN caveat.
        XCTAssertTrue(report.summary.hasPrefix("Deleted 2,500 keys matching tmp:import:*."))
        XCTAssertTrue(report.summary.contains(BulkDeleteJob.Report.caveat))
        XCTAssertTrue(report.details.hasPrefix("Scanned 4 pages · matched 2,500"))
    }

    func testRunsOnJobConnection() async throws {
        let keyspace = keyspace(matching: 1_500)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        _ = await job.sample()
        _ = await run(job)
        XCTAssertFalse(server.opened.isEmpty)
        for opened in server.opened { XCTAssertEqual(opened.role, .job(job.id)) }
        XCTAssertTrue(server.allCommands.allSatisfy { ["SCAN", "UNLINK", "DBSIZE"].contains($0.first ?? "") })
        XCTAssertTrue(server.opened.allSatisfy { $0.transport.isClosed }, "the job's connection closes when it ends")
    }
}

/// A thread-safe list for values recorded from the fake server's callbacks.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    var values: [Value] { lock.withLock { items } }
    func append(_ value: Value) { lock.withLock { items.append(value) } }
}
