import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review extras for KEEL-037: a lock that lands while a save is past its first check, and ACL refusals that don't
/// mean the server refuses writes.
final class ReadOnlyModeReviewTests: XCTestCase {
    private let writable = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: false, production: true))

    private final class Box: @unchecked Sendable { var service: DataCommandService? }

    /// The profile is made read-only while a guarded save waits for its guard read: no MULTI is sent, the WATCH is dropped.
    func testLockDuringGuardReadSendsNoWrite() async throws {
        let box = Box()
        let server = RecordingServer { arguments in
            guard arguments[0] == "GET" else { return "+OK\r\n" }
            let locked = DispatchSemaphore(value: 0)
            Task {
                await box.service?.lockReadOnly(); locked.signal()
            }
            _ = locked.wait(timeout: .now() + 5)
            return "$1\r\nv\r\n"
        }
        let service = DataCommandService(session: server.session())
        box.service = service
        let key = Data("k".utf8)
        do {
            _ = try await service.executeTransaction(
                [.stringSet(key: key, value: Data("w".utf8), keepTTL: true)], unchanged: WatchGuard(key: key, reads: [.get(key: key)], expected: [.bulkString(Data("v".utf8))]),
                context: writable)
            XCTFail("the save ran after the lock")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        XCTAssertEqual(server.allCommands.map { $0[0] }, ["WATCH", "GET", "UNWATCH"])
    }

    /// `-@admin` / `-@dangerous` users can't run CONFIG SET or FLUSHALL but can still write keys: not server read-only.
    func testRefusedAdminCommandIsNotServerReadOnly() {
        let config = RESPValue.error(Data("NOPERM User ops has no permissions to run the 'config|set' command".utf8))
        XCTAssertFalse(ServerReadOnly.refusesWrites(config, of: .admin))
        XCTAssertFalse(ServerReadOnly.refusesWrites(.error(Data("NOPERM User ops has no permissions to run the 'flushall' command".utf8)), of: .destructive))
        XCTAssertTrue(ServerReadOnly.refusesWrites(config, of: .write))
        XCTAssertTrue(ServerReadOnly.refusesWrites(.error(Data("READONLY You can't write against a read only replica.".utf8)), of: .admin), "a replica refuses every write")
    }
}
