import Darwin
import XCTest
@testable import KeelCore

private struct ReviewSettings: PersistedDocument, Equatable {
    static let file = PersistedFile.settings
    static let currentVersion = 1
    var name: String
}

final class PersistenceReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-persistence-review-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func stored(_ url: URL) throws -> ReviewSettings { try PersistenceCodec.decode(ReviewSettings.self, from: Data(contentsOf: url)) }

    private func preserved() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("settings.corrupt.") }.map { directory.appendingPathComponent($0) }
    }

    /// An original over the 4 MiB read cap can't be copied within the cap; both recovery choices must still work and keep it.
    func testOversizedCorruptFileCanBeRecoveredAndIsPreserved() async throws {
        let persistence = Persistence<ReviewSettings>(directory: directory)
        _ = await persistence.load()
        try await persistence.save(ReviewSettings(name: "good"), sequence: 1)
        try await persistence.save(ReviewSettings(name: "better"), sequence: 2)
        let oversized = Data(repeating: UInt8(ascii: "a"), count: PersistenceCodec.byteLimit + 1)
        try oversized.write(to: persistence.fileURL)

        let reopened = Persistence<ReviewSettings>(directory: directory)
        guard case .recovery(.corrupt, let backup) = await reopened.load() else { return XCTFail("Expected corrupt recovery") }
        XCTAssertEqual(backup, ReviewSettings(name: "good"))
        let recovered = try await reopened.recover(.recoverBackup)
        XCTAssertEqual(recovered, ReviewSettings(name: "good"))
        XCTAssertEqual(try stored(reopened.fileURL), ReviewSettings(name: "good"))
        XCTAssertEqual(try preserved().map { try Data(contentsOf: $0) }, [oversized], "The oversized original is preserved byte for byte")

        try oversized.write(to: reopened.fileURL)
        let fresh = Persistence<ReviewSettings>(directory: directory)
        guard case .recovery(.corrupt, _) = await fresh.load() else { return XCTFail("Expected corrupt recovery") }
        try await fresh.recover(.startEmpty)
        try await fresh.save(ReviewSettings(name: "empty"), sequence: 1)
        XCTAssertEqual(try stored(fresh.fileURL), ReviewSettings(name: "empty"))
        XCTAssertEqual(try stored(try XCTUnwrap(fresh.backupURL)), ReviewSettings(name: "good"), "The unreadable file never becomes the backup")
        let copies = try preserved()
        XCTAssertEqual(copies.count, 2)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), oversized)
            var info = stat()
            XCTAssertEqual(lstat(copy.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
        }
    }

    /// Permission to replace an unreadable original belongs to one recovery; a later reload must not inherit it.
    func testStartEmptyPermissionDoesNotSurviveReload() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let persistence = Persistence<ReviewSettings>(directory: directory)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: persistence.fileURL)
        guard case .recovery(.corrupt, _) = await persistence.load() else { return XCTFail("Expected corrupt recovery") }
        try await persistence.recover(.startEmpty)

        try PersistenceCodec.encode(ReviewSettings(name: "external")).write(to: persistence.fileURL)
        guard case .loaded = await persistence.load() else { return XCTFail("Expected the external file to load") }
        let later = Data("{also not json".utf8)
        try later.write(to: persistence.fileURL)
        do { try await persistence.save(ReviewSettings(name: "x"), sequence: 1); XCTFail("Replaced an unpreserved corrupt file") } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: persistence.fileURL), later)
    }

    /// Recovery is only an answer to a `.recovery` load: after a clean load, Recover backup must not replace the good file.
    func testRecoverIsRefusedWithoutPendingRecovery() async throws {
        let persistence = Persistence<ReviewSettings>(directory: directory)
        do { try await persistence.recover(.startEmpty); XCTFail("Recovered before loading") } catch { XCTAssertEqual(error, .readOnly) }
        _ = await persistence.load()
        try await persistence.save(ReviewSettings(name: "old"), sequence: 1)
        try await persistence.save(ReviewSettings(name: "current"), sequence: 2)
        guard case .loaded = await Persistence<ReviewSettings>(directory: directory).load() else { return XCTFail("Expected a clean load") }
        do { try await persistence.recover(.recoverBackup); XCTFail("Recovered without a pending recovery") } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try stored(persistence.fileURL), ReviewSettings(name: "current"))
        XCTAssertEqual(try preserved(), [])
    }
}
