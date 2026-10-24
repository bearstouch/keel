import XCTest
@testable import KeelCore

/// FR-AP10, KEEL-046 AC2: the diagnostics file holds versions, counts, server types and error codes, never hosts, key
/// names, values or secrets.
final class DiagnosticsExportTests: XCTestCase {
    private static let fixed = Date(timeIntervalSince1970: 1_800_000_000)

    func testContainsNoSensitiveFields() throws {
        let recorder = DiagnosticsRecorder { Self.fixed }
        let log = KeelLog(.data, build: .debug, recorder: recorder) { _, _, _ in }
        // Everything a careless call site could hand over: a host, a key, a value and a password.
        log.error("connect.failed", .code("AUTH_FAILED"), .serverText("prod-cache.internal.example s3cr3t-password"))
        log.error("command.failed", .code("user:1042:session"), .serverText("{\"card\":\"4111111111111111\"}"))
        recorder.recordError("TIMEOUT")
        recorder.recordConnection(.redis); recorder.recordConnection(.redis); recorder.recordConnection(.valkey)

        let report = DiagnosticsReport.current(profileCount: 3, recorder: recorder, now: Self.fixed)
        let data = try report.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["prod-cache", "internal.example", "s3cr3t", "user:1042", "session", "4111111111111111", "card"] {
            XCTAssertFalse(text.contains(secret), "The diagnostics must not contain \(secret)")
        }

        // Only these fields, each of a type that can't hold a host, key, value or secret.
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["appVersion", "macOSVersion", "architecture", "profileCount", "serverTypes", "recentErrors", "generatedAt"])
        XCTAssertEqual(object["profileCount"] as? Int, 3)
        XCTAssertEqual(object["serverTypes"] as? [String: Int], ["redis": 2, "valkey": 1])
        XCTAssertEqual(report.recentErrors.map(\.code), ["TIMEOUT", "INVALID_CODE", "AUTH_FAILED"])
        XCTAssertTrue(Set(report.serverTypes.keys).isSubset(of: Set(ServerKind.allCases.map(\.rawValue))))
        XCTAssertEqual(report.appVersion, AppVersion.current)
        XCTAssertTrue(["arm64", "x86_64"].contains(report.architecture))
        XCTAssertNotNil(report.macOSVersion.wholeMatch(of: /\d+\.\d+\.\d+/))
    }

    func testRecentErrorsAreBoundedAndNewestFirst() {
        let recorder = DiagnosticsRecorder()
        for index in 0..<(DiagnosticsRecorder.errorLimit + 10) { recorder.recordError(index.isMultiple(of: 2) ? "TIMEOUT" : "READ_ONLY") }
        recorder.recordError("OUTCOME_UNKNOWN")
        let errors = recorder.snapshot.errors
        XCTAssertEqual(errors.count, DiagnosticsRecorder.errorLimit)
        XCTAssertEqual(errors.first?.code, "OUTCOME_UNKNOWN")
    }

    func testEmptyRunExportsCountsOnly() throws {
        let report = DiagnosticsReport.current(profileCount: 0, recorder: DiagnosticsRecorder(), now: Self.fixed)
        XCTAssertEqual(report.serverTypes, [:]); XCTAssertEqual(report.recentErrors, [])
        XCTAssertEqual(try JSONDecoder.iso8601.decode(DiagnosticsReport.self, from: report.encoded()), report)
    }
}

extension JSONDecoder {
    fileprivate static var iso8601: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
