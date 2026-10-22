import Foundation
import XCTest

/// Container-backed tests (KEEL-053) run only when `KEEL_INTEGRATION=1`, so a plain `swift test` never needs Docker
/// and never reaches a real server.
enum IntegrationGate {
    static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["KEEL_INTEGRATION"] == "1"
    }
}

final class IntegrationGateTests: XCTestCase {
    func testMatrixIsOptIn() {
        XCTAssertFalse(IntegrationGate.isEnabled([:]))
        XCTAssertFalse(IntegrationGate.isEnabled(["KEEL_INTEGRATION": "true"]), "Only the exact value 1 opts in")
        XCTAssertTrue(IntegrationGate.isEnabled(["KEEL_INTEGRATION": "1"]))
    }
}
