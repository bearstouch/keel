import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Cancels a task from inside a fake server's answer, whichever of the two comes first.
private final class Canceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var requested = false

    func hold(_ task: Task<Void, Never>) {
        lock.withLock {
            self.task = task; if requested { task.cancel() }
        }
    }
    func cancel() {
        lock.withLock {
            requested = true; task?.cancel()
        }
    }
}

final class EditorTransactionReviewTests: XCTestCase {
    private let key = Data("k".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    /// A save cancelled after its WATCH must not leave the WATCH on the shared browser connection, where it would turn
    /// the next save's EXEC into a false CONFLICT.
    func testCancelledGuardedSaveDropsItsWatch() async throws {
        let canceller = Canceller()
        let server = RecordingServer { arguments in
            if arguments.first == "GET" { canceller.cancel(); return "$3\r\nold\r\n" }
            return "+OK\r\n"
        }
        let service = DataCommandService(session: server.session())
        let guarded = WatchGuard(key: key, reads: [.get(key: key)], expected: [.bulkString(Data("old".utf8))])
        let writes: [DataOperation] = [.stringSet(key: key, value: Data("new".utf8), keepTTL: true)]
        let context = context
        let save = Task {
            do throws(DataCommandError) {
                _ = try await service.executeTransaction(writes, unchanged: guarded, context: context)
                XCTFail("expected CANCELLED")
            } catch { XCTAssertEqual(error.code, "CANCELLED") }
        }
        canceller.hold(save)
        await save.value
        let names = server.allCommands.map { $0.first ?? "" }
        XCTAssertEqual(names, ["WATCH", "GET", "UNWATCH"], "nothing queued, and the WATCH is dropped")
    }
}
