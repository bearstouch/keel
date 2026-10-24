import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Multi-key delete (FR-SF04): `UNLINK` batches of 500 under the typed confirmation's yes for exactly those keys.
final class MultiKeyDeleteTests: XCTestCase {
    private let writable = SafetyProfile(name: "api-staging", readOnly: false)

    private func keys(_ count: Int) -> [Data] { (0..<count).map { Data("tmp:\($0)".utf8) } }

    private func confirmed(_ keys: [Data], profile: SafetyProfile? = nil, database: Int = 0) -> DataContext {
        DataContext(profile: profile ?? writable, database: database, confirmation: MultiKeyDelete.confirmation(for: keys, database: database))
    }

    private func unlinks(_ server: RecordingServer) -> [[String]] { server.allCommands.filter { $0.first == "UNLINK" } }

    // MARK: - Story tests

    func testBatchesOf500() async {
        let server = RecordingServer { arguments in arguments.first == "UNLINK" ? ":\(arguments.count - 1)\r\n" : "+OK\r\n" }
        let selection = keys(2_000)
        let report = await MultiKeyDelete.run(selection, service: DataCommandService(session: server.session()), context: confirmed(selection))
        // AC2: 2,000 selected keys are 4 UNLINK commands of 500, in selection order.
        let sent = unlinks(server)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent.map { $0.count - 1 }, [500, 500, 500, 500])
        XCTAssertEqual(sent.flatMap { $0.dropFirst() }, selection.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.deleted, 2_000)
        XCTAssertEqual(report.removed.count, 2_000)
    }

    // MARK: - Failure safety

    func testUnconfirmedDeleteSendsNothing() async {
        let server = RecordingServer()
        let selection = keys(3)
        let report = await MultiKeyDelete.run(selection, service: DataCommandService(session: server.session()), context: DataContext(profile: writable))
        XCTAssertEqual(report.failure.map(Self.code), "CONFIRMATION_REQUIRED")
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertTrue(unlinks(server).isEmpty)
    }

    func testConfirmationForOtherKeysOrDatabaseSendsNothing() async {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let selection = keys(3)
        // Confirmed for two of the three keys: the first batch names one more and is refused before sending.
        var context = DataContext(profile: writable, confirmation: MultiKeyDelete.confirmation(for: Array(selection.prefix(2)), database: 0))
        var report = await MultiKeyDelete.run(selection, service: service, context: context)
        XCTAssertEqual(report.failure.map(Self.code), "CONFIRMATION_REQUIRED")
        // Confirmed in db0, run in db1.
        context = DataContext(profile: writable, database: 1, confirmation: MultiKeyDelete.confirmation(for: selection, database: 0))
        report = await MultiKeyDelete.run(selection, service: service, context: context)
        XCTAssertEqual(report.failure.map(Self.code), "CONFIRMATION_REQUIRED")
        XCTAssertTrue(unlinks(server).isEmpty)
    }

    func testReadOnlySendsNothing() async {
        let server = RecordingServer()
        let selection = keys(600)
        let readOnly = SafetyProfile(name: "payments-prod", readOnly: true)
        let report = await MultiKeyDelete.run(selection, service: DataCommandService(session: server.session()), context: confirmed(selection, profile: readOnly))
        XCTAssertEqual(report.failure.map(Self.code), "READ_ONLY")
        XCTAssertTrue(server.allCommands.isEmpty)
    }

    func testServerErrorStopsAndKeepsEarlierBatches() async {
        // The second batch is refused (an ACL on some keys); the third is never sent.
        let server = RecordingServer { arguments in
            guard arguments.first == "UNLINK" else { return "+OK\r\n" }
            return arguments[1] == "tmp:500" ? "-NOPERM No permissions to access a key\r\n" : ":\(arguments.count - 1)\r\n"
        }
        let selection = keys(1_200)
        let report = await MultiKeyDelete.run(selection, service: DataCommandService(session: server.session()), context: confirmed(selection))
        XCTAssertEqual(unlinks(server).count, 2)
        XCTAssertEqual(report.removed, Array(selection.prefix(500)))
        XCTAssertEqual(report.deleted, 500)
        guard case .server(let message)? = report.failure else { return XCTFail("expected a server error, got \(String(describing: report.failure))") }
        XCTAssertTrue(message.hasPrefix("NOPERM"))
    }

    func testDuplicateKeysAreCountedOnce() async {
        let server = RecordingServer { arguments in arguments.first == "UNLINK" ? ":\(arguments.count - 1)\r\n" : "+OK\r\n" }
        let selection = [Data("a".utf8), Data("b".utf8), Data("a".utf8)]
        XCTAssertEqual(MultiKeyDelete.request(for: selection, profile: writable, database: 0).expectedText, "2")
        let report = await MultiKeyDelete.run(selection, service: DataCommandService(session: server.session()), context: confirmed(selection))
        XCTAssertEqual(unlinks(server), [["UNLINK", "a", "b"]])
        XCTAssertEqual(report.requested, 2)
    }

    func testCancelledRunSendsNothingMore() async {
        let server = RecordingServer { arguments in arguments.first == "UNLINK" ? ":\(arguments.count - 1)\r\n" : "+OK\r\n" }
        let selection = keys(1_000)
        let service = DataCommandService(session: server.session()), context = confirmed(selection)
        let task = Task { () async -> MultiKeyDelete.Report in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MultiKeyDelete.run(selection, service: service, context: context)
        }
        let report = await task.value
        XCTAssertEqual(report.failure, .cancelled)
        XCTAssertTrue(unlinks(server).isEmpty)
    }

    private static func code(_ failure: MultiKeyDelete.Failure) -> String {
        if case .command(let error) = failure { return error.code }
        return "\(failure)"
    }
}
