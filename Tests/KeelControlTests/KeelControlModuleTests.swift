import XCTest
@testable import KeelControl

/// Keeps the target wired into the test run until its first real tests land (KEEL-001 AC2).
final class KeelControlModuleTests: XCTestCase {
    func testModuleIsLinked() { XCTAssertEqual(KeelControlModule.name, "KeelControl") }
}
