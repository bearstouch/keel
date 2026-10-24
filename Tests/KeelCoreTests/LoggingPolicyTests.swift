import XCTest
import os
@testable import KeelCore

/// NFR-PV02: server-derived strings are logged private in debug builds and not at all in release builds; codes and
/// counts are the only public text.
final class LoggingPolicyTests: XCTestCase {
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(OSLogType, String, String?)] = []
        func append(_ entry: (OSLogType, String, String?)) { lock.withLock { entries.append(entry) } }
        var all: [(OSLogType, String, String?)] { lock.withLock { entries } }
    }

    private func log(_ build: LogBuild, recorder: DiagnosticsRecorder = DiagnosticsRecorder()) -> (KeelLog, Captured) {
        let captured = Captured()
        return (KeelLog(.connection, build: build, recorder: recorder) { captured.append(($0, $1, $2)) }, captured)
    }

    func testServerStringsArePrivate() {
        let (debug, debugLines) = log(.debug)
        debug.error("connect.failed", .code("AUTH_FAILED"), .serverText("db.internal.example:6379 user:1042"))
        let line = debugLines.all.first
        XCTAssertEqual(line?.1, "connect.failed code=AUTH_FAILED")
        XCTAssertEqual(line?.2, "db.internal.example:6379 user:1042", "Debug builds keep server text, in the private argument only")

        let (release, releaseLines) = log(.release)
        release.error("connect.failed", .code("AUTH_FAILED"), .serverText("db.internal.example:6379 user:1042"))
        XCTAssertEqual(releaseLines.all.first?.1, "connect.failed code=AUTH_FAILED")
        XCTAssertNil(releaseLines.all.first?.2, "Release builds log codes and counts only")
    }

    func testCodesThatAreNotScreamingSnakeAreReplaced() {
        let (release, lines) = log(.release)
        for code in ["user:1042", "READ ONLY", "read_only", "", "_X", String(repeating: "A", count: 65), "AUTH_FAILÉ"] { release.log(.default, "check", .code(code)) }
        XCTAssertEqual(lines.all.map(\.1), Array(repeating: "check code=INVALID_CODE", count: 7))
        XCTAssertEqual(LogMessage.safeCode("TLS_CA_UNAVAILABLE"), "TLS_CA_UNAVAILABLE")
        XCTAssertEqual(LogMessage.safeCode("DB_OUT_OF_RANGE"), "DB_OUT_OF_RANGE")
    }

    func testCountsAndServerKindsArePublic() {
        let (release, lines) = log(.release)
        release.log(.info, "bulk_delete.finished", .count("deleted", 1_221_000), .serverKind(.valkey), .code("COMPLETED"))
        XCTAssertEqual(lines.all.first?.1, "bulk_delete.finished deleted=1221000 server=valkey code=COMPLETED")
        XCTAssertEqual(lines.all.first?.0, .info)
    }

    func testErrorsRecordTheirCodesForDiagnostics() {
        let recorder = DiagnosticsRecorder()
        let (release, _) = log(.release, recorder: recorder)
        release.log(.info, "connect.succeeded", .code("IGNORED"))
        release.error("command.failed", .code("READ_ONLY"))
        release.log(.fault, "command.failed", .code("key:secret"))
        XCTAssertEqual(recorder.snapshot.errors.map(\.code), ["INVALID_CODE", "READ_ONLY"])
    }
}
