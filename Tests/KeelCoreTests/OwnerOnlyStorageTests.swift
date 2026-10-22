import Darwin
import XCTest
@testable import KeelCore

/// The owner-only file helpers vendored from Trellis's workspace persistence (KEEL-002); `Persistence` builds on them in KEEL-003.
final class OwnerOnlyStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testWritesOwnerOnlyAtomicallyAndReadsBack() throws {
        let target = directory.appendingPathComponent("settings.json")
        try OwnerOnlyStorage.atomicWrite(Data("one".utf8), to: target, temporaryPrefix: ".settings.")
        try OwnerOnlyStorage.atomicWrite(Data("two".utf8), to: target, temporaryPrefix: ".settings.")
        var info = stat()
        XCTAssertEqual(stat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(try OwnerOnlyStorage.read(target, limit: 16), Data("two".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"], "No temporary is left behind")
        XCTAssertNil(try OwnerOnlyStorage.read(directory.appendingPathComponent("absent.json"), limit: 16))
    }

    func testFailureBeforeReplaceKeepsPreviousFile() throws {
        let target = directory.appendingPathComponent("settings.json")
        try OwnerOnlyStorage.atomicWrite(Data("previous".utf8), to: target, temporaryPrefix: ".settings.")
        XCTAssertThrowsError(try OwnerOnlyStorage.atomicWrite(Data("next".utf8), to: target, temporaryPrefix: ".settings.") { _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(try OwnerOnlyStorage.read(target, limit: 64), Data("previous".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testRefusesSymlinksOversizedAndNonRegularFiles() throws {
        let real = directory.appendingPathComponent("real.json"), link = directory.appendingPathComponent("link.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try OwnerOnlyStorage.read(link, limit: 16)) { XCTAssertEqual($0 as? OwnerOnlyStorageError, .io(ELOOP)) }
        XCTAssertThrowsError(try OwnerOnlyStorage.read(real, limit: 1)) { XCTAssertEqual($0 as? OwnerOnlyStorageError, .corrupt) }
        XCTAssertThrowsError(try OwnerOnlyStorage.read(directory, limit: 16))
        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try OwnerOnlyStorage.read(fifo, limit: 16), "A FIFO is refused without blocking") { XCTAssertEqual($0 as? OwnerOnlyStorageError, .corrupt) }
    }
}
