import Darwin
import XCTest
@testable import KeelCore

/// MAC-17: one Keel per state folder.
final class InstanceLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keel-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try StateLocation.prepare(root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSecondLockOnTheSameFolderIsRefusedWithTheOwnerPID() throws {
        let first = try InstanceLock(directory: root)
        XCTAssertThrowsError(try InstanceLock(directory: root)) {
            XCTAssertEqual($0 as? InstanceLock.Failure, .held(path: root.path, owner: getpid()))
        }
        withExtendedLifetime(first) {}
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLockIsFreeAgainAfterReleaseOrDeinit() throws {
        let first = try InstanceLock(directory: root)
        first.release()
        var second: InstanceLock? = try InstanceLock(directory: root)
        XCTAssertNotNil(second)
        second = nil
        XCTAssertNoThrow(try InstanceLock(directory: root), "A dropped lock (as on exit or crash) never blocks the next launch")
    }

    func testSeparateFoldersHaveSeparateLocks() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try StateLocation.prepare(other)
        let first = try InstanceLock(directory: root)
        XCTAssertNoThrow(try InstanceLock(directory: other))
        withExtendedLifetime(first) {}
    }

    func testSymlinkAtTheLockPathIsRefusedAndNotFollowed() throws {
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(InstanceLock.fileName), withDestinationURL: target)
        XCTAssertThrowsError(try InstanceLock(directory: root)) {
            guard case .unusable(_, let code) = $0 as? InstanceLock.Failure else { return XCTFail("\($0)") }
            XCTAssertEqual(code, ELOOP)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "The link's target is never created")
    }

    func testFolderAtTheLockPathIsRefused() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(InstanceLock.fileName), withIntermediateDirectories: false)
        XCTAssertThrowsError(try InstanceLock(directory: root)) { XCTAssertNotNil($0 as? InstanceLock.Failure) }
    }
}
