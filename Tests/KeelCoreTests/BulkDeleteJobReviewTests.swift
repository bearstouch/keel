import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Bulk delete failure safety and the confirmation's numbers.
final class BulkDeleteJobReviewTests: BulkDeleteJobFixture {
    func testReadOnlySendsNoDelete() async throws {
        let keyspace = keyspace(matching: 1_200)
        let server = RecordingServer { keyspace.answer($0) }
        let report = await run(try job(keyspace, server: server, profile: SafetyProfile(name: "ro", readOnly: true)))
        XCTAssertEqual(report.failure, .command(.refused(.readOnly(message: "Write commands are blocked on this connection (ro is read-only)."))))
        XCTAssertTrue(unlinks(server).isEmpty)
        XCTAssertEqual(keyspace.remaining.count, 1_200)
    }

    func testConfirmationForAnotherPatternSendsNoMultiKeyDelete() async throws {
        let keyspace = keyspace(matching: 1_200)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        let report = await job.run(confirmation: BulkDeleteJob.confirmation(for: Data("tmp:*:x".utf8), database: 0))
        XCTAssertEqual(report.failure.map { if case .command(let error) = $0 { error.code } else { "" } }, "CONFIRMATION_REQUIRED")
        XCTAssertTrue(unlinks(server).isEmpty)
    }

    func testServerErrorStopsAndKeepsEarlierBatches() async throws {
        let keyspace = keyspace(matching: 3_000)
        let server = RecordingServer { keyspace.answer($0) }
        keyspace.onUnlink = { _ in if keyspace.remaining.count == 2_000 { keyspace.unlinkReply = "-NOPERM no permissions to access a key\r\n" } }
        let report = await run(try job(keyspace, server: server))
        XCTAssertEqual(report.failure, .server("NOPERM no permissions to access a key"))
        XCTAssertEqual(report.deleted, 1_000)
        XCTAssertEqual(unlinks(server).count, 2)
    }

    func testCancelBeforeStartSendsNoDelete() async throws {
        let keyspace = keyspace(matching: 10)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        job.cancel()
        let report = await run(job)
        XCTAssertEqual(report.failure, .cancelled)
        XCTAssertTrue(unlinks(server).isEmpty)
    }

    func testRunsOnce() async throws {
        let keyspace = keyspace(matching: 10)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        _ = await run(job)
        let again = await run(job)
        XCTAssertEqual(again.failure.map { if case .command(let error) = $0 { error.code } else { "" } }, "INVALID_PARAMS")
        XCTAssertEqual(unlinks(server).count, 1)
    }

    func testSampleEstimatesAndPreviews() async throws {
        // Whole database sampled: the count is exact.
        let small = keyspace(matching: 40, other: 60)
        let exact = await (try job(small, server: RecordingServer { small.answer($0) })).sample()
        XCTAssertTrue(exact.complete)
        XCTAssertEqual(exact.estimate, 40)
        XCTAssertEqual(exact.keys.count, 40)
        // A large database: the first 100 matches, the rest estimated from the share of examined keys.
        let large = BulkKeyspace((0..<50_000).map { $0 % 2 == 0 ? "tmp:import:\($0)" : "user:\($0)" })
        let sample = await (try job(large, server: RecordingServer { large.answer($0) })).sample()
        XCTAssertFalse(sample.complete)
        XCTAssertEqual(sample.keys.count, BulkDeleteJob.previewLimit)
        XCTAssertEqual(sample.databaseSize, 50_000)
        XCTAssertEqual(sample.estimate, 25_000)
        let request = BulkDeleteJob.request(for: pattern, estimate: sample.estimate, profile: writable, database: 0)
        XCTAssertEqual(request.message, "About 25,000 keys match tmp:import:* in api-staging db0. This can't be undone.")
        XCTAssertEqual(request.title, "Delete matching keys?")
        XCTAssertTrue(request.matches("tmp:import:*"))
    }

    func testWording() {
        XCTAssertEqual(BulkDeleteJob.about(2_140_000), "About 2.1 million")
        XCTAssertEqual(BulkDeleteJob.about(3_000_000), "About 3 million")
        XCTAssertEqual(BulkDeleteJob.about(12_345), "About 12,000")
        XCTAssertEqual(BulkDeleteJob.about(57), "About 57")
        XCTAssertEqual(BulkDeleteJob.remaining(seconds: 70), "about a minute left")
        XCTAssertEqual(BulkDeleteJob.remaining(seconds: 20), "less than a minute left")
        XCTAssertEqual(BulkDeleteJob.remaining(seconds: 600), "about 10 minutes left")
        let progress = BulkDeleteJob.Progress(scans: 10, matched: 1_221_000, deleted: 1_221_000, elapsed: .seconds(100))
        XCTAssertEqual(progress.line(estimate: 2_100_000), "1,221,000 deleted · about a minute left")
        XCTAssertEqual(progress.line(estimate: nil), "1,221,000 deleted")
        XCTAssertEqual(BulkDeleteJob.Progress().fraction(estimate: nil), nil)
    }

    func testCancelDuringSampleLeavesNoConnectionOpen() async throws {
        // The sheet closes while a sample page is in flight: nothing more is sent and the job connection is closed, even
        // if the close reached the session before that page's reply.
        let keyspace = keyspace(matching: 50_000)
        let holder = Recorder<BulkDeleteJob>()
        let server = RecordingServer { arguments in
            if arguments.first == "SCAN" { holder.values.first?.cancel() }
            return keyspace.answer(arguments)
        }
        let job = try job(keyspace, server: server)
        holder.append(job)
        let sample = await job.sample()
        XCTAssertEqual(sample.scans, 1)
        XCTAssertEqual(server.allCommands.map { $0.first ?? "" }, ["SCAN"], "no DBSIZE after Cancel")
        XCTAssertTrue(server.opened.allSatisfy { $0.transport.isClosed })
    }

    func testSampleStopsOnceRunStarted() async throws {
        let keyspace = keyspace(matching: 50_000)
        let server = RecordingServer { keyspace.answer($0) }
        let job = try job(keyspace, server: server)
        _ = await run(job)
        let before = server.allCommands.count
        let sample = await job.sample()
        XCTAssertEqual(sample.scans, 0)
        XCTAssertEqual(server.allCommands.count, before, "a sample after the run sends nothing")
        XCTAssertTrue(server.opened.allSatisfy { $0.transport.isClosed })
    }

    func testBrowserRunsWhileJobWaits() async throws {
        // AC2: while the job waits out its throttle, the browser's SCAN runs on the browser connection.
        let keyspace = keyspace(matching: 3_000)
        let server = RecordingServer { keyspace.answer($0) }
        let service = DataCommandService(session: server.session())
        let browsed = Recorder<String>()
        let clock = BulkDeleteJob.Clock(
            now: { .zero },
            sleep: { _ in
                let context = DataContext(profile: SafetyProfile(name: "api-staging", readOnly: false))
                let reply = try await service.execute(.operation(.scan(cursor: Data("0".utf8), match: nil, count: 10, type: nil)), origin: .browser, context: context)
                browsed.append(reply.role.description)
            })
        let job = try BulkDeleteJob(pattern: pattern, throttle: 1, service: service, profile: writable, database: 0, clock: clock)
        let report = await run(job)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(browsed.values, ["browser(db0)", "browser(db0)"], "one browse per throttle wait, on the browser's own connection")
        XCTAssertEqual(Set(server.opened.map(\.role)), [.job(job.id), .browser(database: 0)])
    }
}
