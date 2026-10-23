import Darwin
import KeelRESP
import XCTest
@testable import KeelCore

/// Thread-safe record of the changes passed to `@Sendable` confirm closures.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [CAChange] = []
    func record(_ change: CAChange) { lock.withLock { changes.append(change) } }
    var all: [CAChange] { lock.withLock { changes } }
}

final class KnownCATests: XCTestCase {
    private var root: URL!
    private var state: URL!
    private let profile = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keel-known-ca-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        state = root.appendingPathComponent("state", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS/\(name)"))
    }

    /// Writes `fixture` as the profile's CA file and returns its path.
    @discardableResult
    private func writeCA(_ fixture: String, name: String = "ca.pem") throws -> String {
        let url = root.appendingPathComponent(name)
        try self.fixture(fixture).write(to: url)
        return url.path
    }

    private var knownCAFile: URL { state.appendingPathComponent("known-ca.json") }

    private func stored() throws -> KnownCADocument { try PersistenceCodec.decode(KnownCADocument.self, from: Data(contentsOf: knownCAFile)) }

    private func check(_ store: KnownCAStore, _ path: String) async throws -> CATrust { try await store.check(profile: profile, caFile: path) }

    private func expectError(_ expected: KnownCAError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) } catch { XCTAssertEqual(error as? KnownCAError, expected, file: file, line: line) }
    }

    // MARK: - Story tests

    func testFirstUseStoresFingerprint() async throws {
        let path = try writeCA("keel-ca.pem")
        let store = KnownCAStore(directory: state)
        guard case .trusted(let anchors) = try await check(store, path) else { return XCTFail("first use must be trusted") }
        XCTAssertEqual(anchors.count, 1)
        let expected = CAFingerprint(of: try fixture("keel-ca.pem"))
        let document = try stored()
        XCTAssertEqual(document.profiles[profile.uuidString], .init(path: path, sha256: expected))
        XCTAssertFalse(document.recordsLost)
        var info = stat()
        XCTAssertEqual(lstat(knownCAFile.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("known-ca.backup.json").path), "known-ca keeps no backup")

        // Unchanged contents on the next connect, also after relaunch, are trusted without asking.
        guard case .trusted = try await check(KnownCAStore(directory: state), path) else { return XCTFail("same file must stay trusted") }
    }

    func testChangedFileRequiresAcceptance() async throws {
        let path = try writeCA("keel-ca.pem")
        let original = CAFingerprint(of: try fixture("keel-ca.pem")), replaced = CAFingerprint(of: try fixture("other-ca.pem"))
        _ = try await check(KnownCAStore(directory: state), path)
        try writeCA("other-ca.pem")

        // AC1: the change carries both fingerprints, and declining throws before anything else happens.
        let store = KnownCAStore(directory: state)
        let calls = Calls()
        await expectError(.declined(path: path)) {
            _ = try await store.anchors(profile: profile, caFile: path) {
                calls.record($0); return false
            }
        }
        XCTAssertEqual(calls.all.map(\.previous), [original]); XCTAssertEqual(calls.all.map(\.current), [replaced])
        XCTAssertNotEqual(original.description, replaced.description)
        XCTAssertEqual(try stored().profiles[profile.uuidString]?.sha256, original, "declining keeps the old record")
        guard case .changed = try await check(store, path) else { return XCTFail("a declined change asks again") }

        // AC2: accepting records the new fingerprint and the next connect doesn't ask.
        let anchors = try await store.anchors(profile: profile, caFile: path) {
            calls.record($0); return true
        }
        XCTAssertEqual(anchors, try TLSConfiguration.certificates(fromPEM: try fixture("other-ca.pem")))
        XCTAssertEqual(try stored().profiles[profile.uuidString]?.sha256, replaced)
        _ = try await KnownCAStore(directory: state).anchors(profile: profile, caFile: path) {
            calls.record($0); return true
        }
        XCTAssertEqual(calls.all.count, 2, "the next connect after accepting doesn't ask")
    }

    func testMissingFileIsReported() async throws {
        let path = root.appendingPathComponent("gone.pem").path
        let store = KnownCAStore(directory: state)
        await expectError(.missing(path: path)) { _ = try await check(store, path) }
        let failure = ConnectionFailure(caFile: .missing(path: path))
        XCTAssertEqual(failure.category, .tlsCAUnavailable)
        XCTAssertTrue(failure.message.contains("“\(path)”"), failure.message)
        let recorded = await store.fingerprint(profile: profile)
        XCTAssertNil(recorded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: knownCAFile.path), "nothing is recorded for a missing file")
    }

    // MARK: - Failure safety

    func testUnusableFilesNameThePathAndRecordNothing() async throws {
        let store = KnownCAStore(directory: state)
        let empty = root.appendingPathComponent("empty.pem"); try Data("no certs here".utf8).write(to: empty)
        await expectError(.invalidBundle(path: empty.path, .noCertificates)) { _ = try await check(store, empty.path) }
        await expectError(.unreadable(path: root.path, code: EISDIR)) { _ = try await check(store, root.path) }
        let fifo = root.appendingPathComponent("fifo.pem").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        await expectError(.unreadable(path: fifo, code: EFTYPE)) { _ = try await check(store, fifo) }
        let locked = try writeCA("keel-ca.pem", name: "locked.pem")
        XCTAssertEqual(chmod(locked, 0o000), 0)
        await expectError(.unreadable(path: locked, code: EACCES)) { _ = try await check(store, locked) }
        let recorded = await store.fingerprint(profile: profile)
        XCTAssertNil(recorded)

        for error in [KnownCAError.invalidBundle(path: empty.path, .noCertificates), .unreadable(path: locked, code: EACCES), .declined(path: locked)] {
            let failure = ConnectionFailure(caFile: error)
            XCTAssertTrue(failure.message.contains("“"), failure.message)
        }
        XCTAssertEqual(ConnectionFailure(caFile: .declined(path: locked)).category, .tlsCAChanged)
        XCTAssertTrue(ConnectionFailure(caFile: .unreadable(path: locked, code: EACCES)).message.contains("permission denied"))
    }

    func testSymlinkedCAFileIsFollowed() async throws {
        let target = try writeCA("keel-ca.pem")
        let link = root.appendingPathComponent("link.pem").path
        XCTAssertEqual(symlink(target, link), 0)
        guard case .trusted = try await check(KnownCAStore(directory: state), link) else { return XCTFail("a symlinked bundle is usable") }
    }

    func testChangedPathIsANewChoiceNotAChange() async throws {
        let first = try writeCA("keel-ca.pem"), second = try writeCA("other-ca.pem", name: "other.pem")
        let store = KnownCAStore(directory: state)
        _ = try await check(store, first)
        guard case .trusted = try await check(store, second) else { return XCTFail("selecting another file in the editor isn't a change") }
        XCTAssertEqual(try stored().profiles[profile.uuidString]?.path, second)
    }

    func testCorruptStoreIsPreservedAndAsksInsteadOfTrusting() async throws {
        let path = try writeCA("keel-ca.pem")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{ not json".utf8).write(to: knownCAFile)
        let store = KnownCAStore(directory: state)
        guard case .changed(let change) = try await check(store, path) else { return XCTFail("lost records must not trust on first use") }
        XCTAssertNil(change.previous)
        let names = try FileManager.default.contentsOfDirectory(atPath: state.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("known-ca.corrupt.") }, "the unreadable original is preserved: \(names)")
        XCTAssertTrue(try stored().recordsLost, "the loss is recorded on disk, so a relaunch still asks")
        _ = await store.accept(change)
        guard case .trusted = try await check(KnownCAStore(directory: state), path) else { return XCTFail("an accepted file is trusted") }
    }

    func testNewerStoreIsNeverOverwrittenAndAsks() async throws {
        let path = try writeCA("keel-ca.pem")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let newer = Data(#"{"schemaVersion": 99, "profiles": {}}"#.utf8)
        try newer.write(to: knownCAFile)
        let store = KnownCAStore(directory: state)
        guard case .changed(let change) = try await check(store, path) else { return XCTFail("an unreadable store must not trust on first use") }
        // Accepting holds for this session even though it can't be saved.
        _ = await store.accept(change)
        guard case .trusted = try await check(store, path) else { return XCTFail("accepted in memory") }
        let saveError = await store.lastSaveError
        XCTAssertEqual(saveError, .readOnly)
        XCTAssertEqual(try Data(contentsOf: knownCAFile), newer)
    }

    func testForgetRemovesTheRecord() async throws {
        let path = try writeCA("keel-ca.pem")
        let store = KnownCAStore(directory: state)
        _ = try await check(store, path)
        await store.forget(profile: profile)
        XCTAssertNil(try stored().profiles[profile.uuidString])
    }

    func testFingerprintFormatAndValidation() throws {
        let fingerprint = CAFingerprint(of: Data("abc".utf8))
        XCTAssertEqual(fingerprint.hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(fingerprint.description.hasPrefix("BA:78:16:BF:")); XCTAssertEqual(fingerprint.description.count, 95)
        XCTAssertNil(CAFingerprint(hex: "BA7816BF"))
        XCTAssertNil(CAFingerprint(hex: String(repeating: "g", count: 64)))
        let tampered = Data(#"{"schemaVersion": 1, "profiles": {"x": {"path": "/ca.pem", "sha256": "nope"}}}"#.utf8)
        XCTAssertThrowsError(try PersistenceCodec.decode(KnownCADocument.self, from: tampered))
    }
}
