import Foundation
import XCTest
@testable import KeelRESP

/// A transport whose `connect` succeeds only after cancelling the calling task, so the caller's cancellation
/// handler has already cancelled the transport when `connect` returns: the race a real socket can hit.
final class CancelDuringConnectTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func connect() async throws(TransportError) { withUnsafeCurrentTask { $0?.cancel() } }
    func send(_ data: Data) {}
    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let done = lock.withLock {
                if !cancelled { receiver = waiter }
                return cancelled
            }
            if done { waiter.resume(returning: .failure(.cancelled)) }
        }
        return try result.get()
    }
    func cancel() {
        let waiter = lock.withLock {
            defer { cancelled = true; receiver = nil }
            return receiver
        }
        waiter?.resume(returning: .failure(.cancelled))
    }
}

final class RedisConnectionReviewTests: XCTestCase {
    func testCancelledConnectIsNeverReadyEvenIfTransportConnected() async {
        let transport = CancelDuringConnectTransport()
        let connection = RedisConnection(transport: transport, sleep: { try await ManualSleeper().sleep($0) })
        let error = await Task { () -> RedisError? in
            do throws(RedisError) { try await connection.connect(); return nil } catch { return error }
        }.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertTrue(transport.isCancelled)
        let state = await connection.state
        XCTAssertEqual(state, .closed)
    }

    func testTimerFiringAfterReplyLeavesConnectionReady() async throws {
        let transport = FakeTransport(), sleeper = ManualSleeper()
        let connection = RedisConnection(transport: transport, sleep: { try await sleeper.sleep($0) })
        try await connection.connect()
        let task = Task { () -> RESPValue? in try? await connection.send([bytes("GET"), bytes("k")], mayWrite: false, timeout: .seconds(4)) }
        let armed = await eventually { sleeper.count(.seconds(4)) == 1 }
        XCTAssertTrue(armed)
        transport.reply("$1\r\nv\r\n")
        let reply = await task.value
        XCTAssertEqual(reply, .bulkString(bytes("v")))
        sleeper.fire(.seconds(4))  // a timer that lost the race with its reply must not close the connection
        let next = Task { () -> RESPValue? in try? await connection.send([bytes("PING")], mayWrite: false) }
        let sent = await eventually { transport.sent.count == 2 }
        XCTAssertTrue(sent)
        transport.reply("+PONG\r\n")
        let pong = await next.value
        XCTAssertEqual(pong, .simpleString(bytes("PONG")))
        let state = await connection.state
        XCTAssertEqual(state, .ready)
    }
}
