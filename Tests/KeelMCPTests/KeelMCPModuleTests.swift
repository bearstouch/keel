import XCTest
@testable import KeelMCP

/// Keeps the target wired into the test run until its first real tests land (KEEL-001 AC2).
final class KeelMCPModuleTests: XCTestCase {
    func testModuleIsLinked() { XCTAssertEqual(KeelMCPModule.name, "KeelMCP") }
}
