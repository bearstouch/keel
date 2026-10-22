import XCTest
@testable import KeelRESP

/// Keeps the target wired into the test run until its first real tests land (KEEL-001 AC2).
final class KeelRESPModuleTests: XCTestCase {
    func testModuleIsLinked() { XCTAssertEqual(KeelRESPModule.name, "KeelRESP") }
}
