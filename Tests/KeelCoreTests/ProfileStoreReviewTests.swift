import XCTest
@testable import KeelCore

final class ProfileStoreReviewTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    /// A password lookup made while a host change with a new password is mid-commit (Keychain already written,
    /// metadata not yet) must not hand the new server's password to a connect resolved at the old connection.
    func testPasswordLookupWaitsForAnInFlightCommit() async throws {
        let gate = DispatchSemaphore(value: 0), entered = FailSwitch()
        let blocking = FailSwitch()
        let persistence = Persistence<ConnectionsDocument>(
            directory: fixture.directory,
            beforeReplace: { _ in
                if blocking.isOn { blocking.isOn = false; entered.isOn = true; _ = gate.wait(timeout: .now() + 5) }
            })
        let store = ProfileStore(persistence: persistence, secrets: fixture.secrets)
        _ = await store.load()
        let profile = try await store.create(.sample(), password: Data("old-server".utf8))
        var moved = profile.settings; moved.host = "10.0.0.2"

        blocking.isOn = true
        let update = Task { try await store.update(profile.id, moved, password: .set(Data("new-server".utf8)), expectedRevision: profile.revision) }
        for _ in 0..<500 where !entered.isOn { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(entered.isOn)
        let lookup = Task { try await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision) }
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        let updated = try await update.value
        let leaked = try await lookup.value
        XCTAssertNil(leaked, "the old connection revision never gets the new server's password")
        let bound = try await store.password(profileID: profile.id, connectionRevision: updated.connectionRevision)
        XCTAssertEqual(bound, Data("new-server".utf8))
    }

    /// A hand-edited revision at the top of the range would trap on the next edit; the file goes to recovery instead.
    func testOverflowingRevisionIsRejected() throws {
        let file = #"{"schemaVersion":1,"revision":18446744073709551615,"folders":[],"profiles":[]}"#
        XCTAssertThrowsError(try PersistenceCodec.decode(ConnectionsDocument.self, from: Data(file.utf8))) { XCTAssertEqual($0 as? PersistenceError, .corrupt) }
    }
}
