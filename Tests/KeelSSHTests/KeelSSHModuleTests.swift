import XCTest
@testable import KeelAskpass
@testable import KeelSSH

/// Keeps the target wired into the test run until its first real tests land (KEEL-001 AC2).
final class KeelSSHModuleTests: XCTestCase {
    func testModuleIsLinked() { XCTAssertEqual(KeelSSHModule.name, "KeelSSH") }
}

final class KeelAskpassModuleTests: XCTestCase {
    func testAskpassModuleIsLinked() { XCTAssertEqual(KeelAskpassModule.name, "KeelAskpass") }
}
