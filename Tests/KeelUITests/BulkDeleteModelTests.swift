import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The browser's bulk delete by pattern (FR-SF05): offered from ⋯ for the filter's pattern, typed confirmation, run,
/// report.
final class BulkDeleteModelTests: XCTestCase {
    @MainActor private func browser(_ keyspace: BrowserKeyspace, pattern: String?, readOnly: Bool = false) async -> BrowserModel {
        let list = keyspace.list(readOnly: readOnly)
        let filter = KeyFilterModel(list: list) { _ in }
        if let pattern { filter.patternText = pattern; await filter.applyPattern() }
        let model = BrowserModel(list: list, filter: filter, database: 0)
        await model.start()
        return model
    }

    private func unlinks(_ keyspace: BrowserKeyspace) -> [[String]] { keyspace.commands.map(\.arguments).filter { $0.first == "UNLINK" } }

    @MainActor func testTypedPatternRunsAndReports() async throws {
        let keyspace = BrowserKeyspace([0: ["tmp:1", "tmp:2", "tmp:3", "user:1"]])
        let model = await browser(keyspace, pattern: "tmp:*")
        XCTAssertNotNil(model.list.onBulkDelete)
        await model.requestBulkDelete()
        let sheet = try XCTUnwrap(model.bulkDelete)
        // Not before the count is in: the sample and the run never share the job connection.
        sheet.typed = "tmp:*"
        XCTAssertFalse(sheet.canConfirm)
        await sheet.loadSample()
        XCTAssertEqual(sheet.confirmation.message, "3 keys match tmp:* in payments-prod db0. This can't be undone.")
        // FR-SF03: the pattern exactly; near misses never run.
        for near in ["tmp:", "TMP:*", "tmp:* "] {
            sheet.typed = near
            await sheet.confirm()
            XCTAssertEqual(sheet.stage, .confirm)
        }
        XCTAssertTrue(unlinks(keyspace).isEmpty)
        sheet.typed = "tmp:*"
        await sheet.confirm()
        guard case .finished(let report) = sheet.stage else { return XCTFail("not finished: \(sheet.stage)") }
        XCTAssertEqual(report.deleted, 3)
        XCTAssertTrue(report.summary.contains(BulkDeleteJob.Report.caveat))
        XCTAssertEqual(unlinks(keyspace).map { Set($0.dropFirst()) }, [["tmp:1", "tmp:2", "tmp:3"]])
    }

    @MainActor func testNotOfferedWithoutPatternOrOnReadOnly() async {
        let keyspace = BrowserKeyspace([0: ["tmp:1", "tmp:2"]])
        let readOnly = await browser(keyspace, pattern: "tmp:*", readOnly: true)
        XCTAssertNil(readOnly.list.onBulkDelete)
        await readOnly.requestBulkDelete()
        XCTAssertNil(readOnly.bulkDelete)
        // No pattern (or `*`, which the filter treats as none): nothing to delete by.
        for pattern in [nil, "*"] as [String?] {
            let model = await browser(keyspace, pattern: pattern)
            await model.requestBulkDelete()
            XCTAssertNil(model.bulkDelete)
        }
    }

    @MainActor func testClosingBeforeRunSendsNoDelete() async throws {
        let keyspace = BrowserKeyspace([0: ["tmp:1", "tmp:2"]])
        let model = await browser(keyspace, pattern: "tmp:*")
        await model.requestBulkDelete()
        let sheet = try XCTUnwrap(model.bulkDelete)
        await sheet.loadSample()
        sheet.typed = "tmp:*"
        model.bulkDelete = nil
        await sheet.dismissed()
        XCTAssertTrue(sheet.job.isCancelled)
        await sheet.confirm()
        guard case .finished(let report) = sheet.stage else { return XCTFail("not finished") }
        XCTAssertEqual(report.failure, .cancelled)
        XCTAssertTrue(unlinks(keyspace).isEmpty)
    }
}
