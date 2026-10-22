import Darwin
import XCTest
@testable import KeelCore

private struct TestSettings: PersistedDocument, Equatable {
    static let file = PersistedFile.settings
    static let currentVersion = 1
    var name: String
    var items: [String] = []
}

private struct TestGrants: PersistedDocument, Equatable {
    static let file = PersistedFile.grants
    static let currentVersion = 1
    var hashes: [String]
}

/// Thread-safe mutable state shared with `@Sendable` hooks.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A debounce timer that only fires when the test says so.
private actor ManualSleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep() async { await withCheckedContinuation { waiters.append($0) } }
    /// Waits until `count` debounce tasks are sleeping, then wakes them all.
    func fire(whenWaiting count: Int) async {
        while waiters.count < count { await Task.yield() }
        let fired = waiters; waiters = []; fired.forEach { $0.resume() }
    }
}

final class PersistenceTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keel-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = root.appendingPathComponent("state", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.lastPathComponent)
        return info.st_mode & 0o777
    }

    private func contents() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }

    private func stored(_ url: URL) throws -> TestSettings { try PersistenceCodec.decode(TestSettings.self, from: Data(contentsOf: url)) }

    private func loaded<D>(_ result: PersistenceLoadResult<D>) -> D? { if case .loaded(let document) = result { return document }; return nil }

    func testWritesOwnerOnlyAtomically() async throws {
        let persistence = Persistence<TestSettings>(directory: directory)
        guard case .missing = await persistence.load() else { return XCTFail("Expected a missing file") }
        try await persistence.save(TestSettings(name: "one"), sequence: 1)
        try await persistence.save(TestSettings(name: "two"), sequence: 2)

        XCTAssertEqual(mode(directory), 0o700)
        XCTAssertEqual(mode(persistence.fileURL), 0o600)
        XCTAssertEqual(mode(try XCTUnwrap(persistence.backupURL)), 0o600)
        XCTAssertEqual(try contents(), ["settings.json", "settings.backup.json"], "No temporary is left behind")
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "two"))
        XCTAssertEqual(try stored(try XCTUnwrap(persistence.backupURL)), TestSettings(name: "one"), "The previous good file becomes the backup")

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        XCTAssertEqual(raw?["schemaVersion"] as? Int, 1, "The envelope is flat: schemaVersion beside the document's keys")
        XCTAssertEqual(raw?["name"] as? String, "two")
        let reloaded = await Persistence<TestSettings>(directory: directory).load()
        XCTAssertEqual(loaded(reloaded), TestSettings(name: "two"))

        // An existing, too-open folder is tightened to 0700; files without a backup policy get none.
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        let grants = Persistence<TestGrants>(directory: directory)
        _ = await grants.load()
        try await grants.save(TestGrants(hashes: ["a"]), sequence: 1)
        try await grants.save(TestGrants(hashes: ["b"]), sequence: 2)
        XCTAssertEqual(mode(directory), 0o700)
        XCTAssertEqual(mode(grants.fileURL), 0o600)
        XCTAssertNil(grants.backupURL)
        XCTAssertEqual(try contents(), ["settings.json", "settings.backup.json", "grants.json"])
    }

    func testRefusesSymlinkedTarget() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        let original = try PersistenceCodec.encode(TestSettings(name: "elsewhere"))
        try original.write(to: elsewhere)
        let persistence = Persistence<TestSettings>(directory: directory)

        // Loading through a symlinked file is refused and leaves saving off.
        try FileManager.default.createSymbolicLink(at: persistence.fileURL, withDestinationURL: elsewhere)
        guard case .recovery(.io(ELOOP), nil) = await persistence.load() else { return XCTFail("Expected ELOOP recovery") }
        do { try await persistence.save(TestSettings(name: "x"), sequence: 1); XCTFail("Saved through a symlink") } catch { XCTAssertEqual(error, .readOnly) }

        // A symlink planted after a clean load is refused at save time.
        try FileManager.default.removeItem(at: persistence.fileURL)
        guard case .missing = await persistence.load() else { return XCTFail("Expected a missing file") }
        try FileManager.default.createSymbolicLink(at: persistence.fileURL, withDestinationURL: elsewhere)
        do { try await persistence.save(TestSettings(name: "x"), sequence: 1); XCTFail("Saved through a symlink") } catch { XCTAssertEqual(error, .io(ELOOP)) }

        // So is a symlinked backup.
        try FileManager.default.removeItem(at: persistence.fileURL)
        try await persistence.save(TestSettings(name: "first"), sequence: 2)
        try FileManager.default.createSymbolicLink(at: try XCTUnwrap(persistence.backupURL), withDestinationURL: elsewhere)
        do { try await persistence.save(TestSettings(name: "second"), sequence: 3); XCTFail("Saved through a symlinked backup") } catch { XCTAssertEqual(error, .io(ELOOP)) }
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "first"))
        XCTAssertEqual(try Data(contentsOf: elsewhere), original, "The link target is never written")

        // A symlinked state folder is refused too.
        let linkedFolder = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: directory)
        let linked = Persistence<TestGrants>(directory: linkedFolder)
        _ = await linked.load()
        do { try await linked.save(TestGrants(hashes: []), sequence: 1); XCTFail("Saved into a symlinked folder") } catch { XCTAssertEqual(error, .io(ELOOP)) }
    }

    func testSequenceGateDropsStaleSave() async throws {
        let sleeper = ManualSleeper()
        let persistence = Persistence<TestSettings>(directory: directory, sleep: { _ in await sleeper.sleep() })
        _ = await persistence.load()

        // Immediate saves: an older sequence is dropped.
        let wroteNew = try await persistence.save(TestSettings(name: "new"), sequence: 2)
        let wroteOld = try await persistence.save(TestSettings(name: "old"), sequence: 1)
        XCTAssertTrue(wroteNew); XCTAssertFalse(wroteOld)
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "new"))

        // Debounced saves coalesce to the newest; a late older one is ignored.
        await persistence.scheduleSave(TestSettings(name: "a"), sequence: 3)
        await persistence.scheduleSave(TestSettings(name: "c"), sequence: 5)
        await persistence.scheduleSave(TestSettings(name: "b"), sequence: 4)
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "new"), "Nothing is written before the debounce fires")
        await sleeper.fire(whenWaiting: 2)
        await persistence.settle()
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "c"))

        // A debounced save overtaken by a newer immediate save never lands.
        await persistence.scheduleSave(TestSettings(name: "stale"), sequence: 6)
        try await persistence.save(TestSettings(name: "fresh"), sequence: 7)
        await sleeper.fire(whenWaiting: 1)
        await persistence.settle()
        try await persistence.flush()
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "fresh"))

        // Quit: flush writes the pending save without waiting for the timer.
        await persistence.scheduleSave(TestSettings(name: "quit"), sequence: 8)
        try await persistence.flush()
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "quit"))
        await sleeper.fire(whenWaiting: 1)
        await persistence.settle()
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "quit"))
    }

    func testCorruptFileIsPreservedBeforeRecovery() async throws {
        let writes = Box<[String]>([])
        let persistence = Persistence<TestSettings>(directory: directory, beforeReplace: { writes.value.append($0.lastPathComponent) })
        _ = await persistence.load()
        try await persistence.save(TestSettings(name: "good"), sequence: 1)
        try await persistence.save(TestSettings(name: "better"), sequence: 2)
        let garbage = Data("{\"schemaVersion\": 1, \"name\": ".utf8)
        try garbage.write(to: persistence.fileURL)

        let reopened = Persistence<TestSettings>(directory: directory, beforeReplace: { writes.value.append($0.lastPathComponent) })
        guard case .recovery(.corrupt, let backup) = await reopened.load() else { return XCTFail("Expected corrupt recovery") }
        XCTAssertEqual(backup, TestSettings(name: "good"))
        do { try await reopened.save(TestSettings(name: "x"), sequence: 3); XCTFail("Saved over a corrupt file") } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL), garbage, "Nothing is written before a recovery choice")

        writes.value = []
        let recovered = try await reopened.recover(.recoverBackup)
        XCTAssertEqual(recovered, TestSettings(name: "good"))
        XCTAssertEqual(writes.value.count, 2)
        XCTAssertTrue(writes.value.first?.hasPrefix("settings.corrupt.") == true, "The original is preserved first: \(writes.value)")
        XCTAssertEqual(writes.value.last, "settings.json")
        let preserved = try contents().filter { $0.hasPrefix("settings.corrupt.") && $0.hasSuffix(".json") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(preserved.first))), garbage)
        XCTAssertEqual(mode(directory.appendingPathComponent(try XCTUnwrap(preserved.first))), 0o600)
        XCTAssertEqual(try stored(reopened.fileURL), TestSettings(name: "good"))
        try await reopened.save(TestSettings(name: "after"), sequence: 3)

        // Start empty: preserved, then the next save replaces the original without touching the good backup.
        try garbage.write(to: reopened.fileURL)
        let fresh = Persistence<TestSettings>(directory: directory)
        guard case .recovery(.corrupt, _) = await fresh.load() else { return XCTFail("Expected corrupt recovery") }
        let empty = try await fresh.recover(.startEmpty)
        XCTAssertNil(empty)
        XCTAssertEqual(try contents().filter { $0.hasPrefix("settings.corrupt.") }.count, 2)
        try await fresh.save(TestSettings(name: "empty"), sequence: 1)
        XCTAssertEqual(try stored(fresh.fileURL), TestSettings(name: "empty"))
        XCTAssertEqual(try stored(try XCTUnwrap(fresh.backupURL)), TestSettings(name: "good"), "A corrupt file never becomes the backup")

        // No usable backup: Recover backup is refused and nothing is written.
        let grants = Persistence<TestGrants>(directory: directory)
        try garbage.write(to: grants.fileURL)
        guard case .recovery(.corrupt, nil) = await grants.load() else { return XCTFail("Expected corrupt recovery without backup") }
        do { try await grants.recover(.recoverBackup); XCTFail("Recovered a missing backup") } catch { XCTAssertEqual(error, .backupUnavailable) }
        XCTAssertFalse(try contents().contains { $0.hasPrefix("grants.corrupt.") })
    }

    func testNewerVersionOpensReadOnly() async throws {
        let persistence = Persistence<TestSettings>(directory: directory)
        _ = await persistence.load()
        try await persistence.save(TestSettings(name: "v1"), sequence: 1)
        try await persistence.save(TestSettings(name: "v1 again"), sequence: 2)
        let newer = Data(#"{"schemaVersion": 99, "name": "future", "extra": true}"#.utf8)
        try newer.write(to: persistence.fileURL)

        let sleeper = ManualSleeper()
        let reopened = Persistence<TestSettings>(directory: directory, sleep: { _ in await sleeper.sleep() })
        guard case .recovery(.newerVersion(99), let backup) = await reopened.load() else { return XCTFail("Expected newer-version recovery") }
        XCTAssertEqual(backup, TestSettings(name: "v1"), "The backup is offered for use in memory")
        let writable = await reopened.isWritable
        XCTAssertFalse(writable)
        do { try await reopened.save(TestSettings(name: "x"), sequence: 1); XCTFail("Overwrote a newer file") } catch { XCTAssertEqual(error, .readOnly) }
        do { try await reopened.recover(.recoverBackup); XCTFail("Recovery overwrote a newer file") } catch { XCTAssertEqual(error, .readOnly) }
        do { try await reopened.recover(.startEmpty); XCTFail("Recovery overwrote a newer file") } catch { XCTAssertEqual(error, .readOnly) }
        await reopened.scheduleSave(TestSettings(name: "debounced"), sequence: 2)
        await sleeper.fire(whenWaiting: 1)
        await reopened.settle()
        let error = await reopened.lastSaveError
        XCTAssertEqual(error, .readOnly)
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL), newer, "The newer file is untouched")
        XCTAssertEqual(try contents(), ["settings.json", "settings.backup.json"])

        // A newer Keel writing the file mid-session also stops this one for the rest of the session.
        let active = Persistence<TestSettings>(directory: directory)
        try FileManager.default.removeItem(at: active.fileURL)
        _ = await active.load()
        try await active.save(TestSettings(name: "mine"), sequence: 1)
        try newer.write(to: active.fileURL)
        do { try await active.save(TestSettings(name: "x"), sequence: 2); XCTFail("Overwrote a newer file") } catch { XCTAssertEqual(error, .readOnly) }
        try FileManager.default.removeItem(at: active.fileURL)
        do { try await active.save(TestSettings(name: "x"), sequence: 3); XCTFail("Wrote after seeing a newer file") } catch { XCTAssertEqual(error, .readOnly) }
    }

    func testInterruptedSaveLeavesReadableState() async throws {
        struct Interrupted: Error {}
        let failOn = Box<String?>(nil)
        let persistence = Persistence<TestSettings>(directory: directory, beforeReplace: { if $0.lastPathComponent == failOn.value { throw Interrupted() } })
        _ = await persistence.load()
        try await persistence.save(TestSettings(name: "v1"), sequence: 1)
        try await persistence.save(TestSettings(name: "v2"), sequence: 2)

        // Interrupted while publishing the backup: the current file is untouched.
        failOn.value = "settings.backup.json"
        do { try await persistence.save(TestSettings(name: "v3"), sequence: 3); XCTFail("Expected the injected failure") } catch { XCTAssertEqual(error, .io(EIO)) }
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "v2"))
        XCTAssertEqual(try stored(try XCTUnwrap(persistence.backupURL)), TestSettings(name: "v1"))

        // Interrupted between the temporary's fsync and the rename of the current file: the previous file survives.
        failOn.value = "settings.json"
        do { try await persistence.save(TestSettings(name: "v3"), sequence: 3); XCTFail("Expected the injected failure") } catch { XCTAssertEqual(error, .io(EIO)) }
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "v2"))
        XCTAssertEqual(try contents(), ["settings.json", "settings.backup.json"], "The temporary is removed")
        let reloaded = await Persistence<TestSettings>(directory: directory).load()
        XCTAssertEqual(loaded(reloaded), TestSettings(name: "v2"))

        // A failed debounced save is kept so the quit flush can retry it.
        await persistence.scheduleSave(TestSettings(name: "v4"), sequence: 4)
        do { try await persistence.flush(); XCTFail("Expected the injected failure") } catch { XCTAssertEqual(error, .io(EIO)) }
        failOn.value = nil
        try await persistence.flush()
        XCTAssertEqual(try stored(persistence.fileURL), TestSettings(name: "v4"))
        let error = await persistence.lastSaveError
        XCTAssertNil(error)
    }

    func testRejectsOversizedAndDeepJSON() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let persistence = Persistence<TestSettings>(directory: directory)

        var oversized = Data(#"{"schemaVersion": 1, "name": ""#.utf8)
        oversized.append(Data(repeating: UInt8(ascii: "a"), count: PersistenceCodec.byteLimit))
        oversized.append(Data(#""}"#.utf8))
        try oversized.write(to: persistence.fileURL)
        guard case .recovery(.corrupt, _) = await persistence.load() else { return XCTFail("Expected an oversized file to be refused") }

        func nested(_ depth: Int) -> Data {
            Data((#"{"schemaVersion": 1, "name": "deep", "items": "# + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "}").utf8)
        }
        try nested(PersistenceCodec.depthLimit + 1).write(to: persistence.fileURL)
        guard case .recovery(.corrupt, _) = await persistence.load() else { return XCTFail("Expected 129 levels to be refused") }
        XCTAssertTrue(PersistenceCodec.nestingWithinLimit(nested(PersistenceCodec.depthLimit)))
        XCTAssertTrue(PersistenceCodec.nestingWithinLimit(Data(#"{"name": "[[[[ inside a \" string"}"#.utf8)), "Brackets in strings don't count")

        // A document that could not be read back is never written.
        try FileManager.default.removeItem(at: persistence.fileURL)
        _ = await persistence.load()
        let huge = TestSettings(name: String(repeating: "x", count: PersistenceCodec.byteLimit))
        do { try await persistence.save(huge, sequence: 1); XCTFail("Wrote an unreadable document") } catch { XCTAssertEqual(error, .tooLarge) }
        XCTAssertEqual(try contents(), [])
    }
}
