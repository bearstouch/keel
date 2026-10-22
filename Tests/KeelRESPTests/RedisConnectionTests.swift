import Foundation
import XCTest
@testable import KeelRESP

final class RedisConnectionTests: XCTestCase {
    private func connected(_ transport: FakeTransport, sleeper: ManualSleeper = ManualSleeper()) async throws -> RedisConnection {
        let connection = RedisConnection(transport: transport, sleep: { try await sleeper.sleep($0) })
        try await connection.connect()
        return connection
    }

    private func command(_ words: String...) -> [Data] { words.map(bytes) }

    /// Starts `send` in its own task and waits until its frame is on the wire.
    private func inFlight(
        _ connection: RedisConnection, _ transport: FakeTransport, _ arguments: [Data], mayWrite: Bool, timeout: Duration? = nil
    ) async -> Task<Result<RESPValue, RedisError>, Never> {
        let sentBefore = transport.sent.count
        let task = Task { () -> Result<RESPValue, RedisError> in
            do throws(RedisError) { return .success(try await connection.send(arguments, mayWrite: mayWrite, timeout: timeout)) } catch { return .failure(error) }
        }
        let onWire = await eventually { transport.sent.count > sentBefore }
        XCTAssertTrue(onWire, "command never reached the transport")
        return task
    }

    /// Starts `connect()` in its own task; the task yields the error, or nil once connected.
    private func connecting(_ connection: RedisConnection) -> Task<RedisError?, Never> {
        Task {
            do throws(RedisError) { try await connection.connect(); return nil } catch { return error }
        }
    }

    // MARK: - Story tests

    func testPipelinedRepliesKeepOrder() async throws {
        // The fake server holds every reply until all 100 commands are in flight, then answers them in order,
        // in 7-byte chunks, each reply echoing its command's argument.
        let transport = FakeTransport(onSend: { transport, frames in
            guard frames.count == 100 else { return }
            let stream = transport.commands.reduce(into: Data()) { $0.append(bytes("$\($1[1].utf8.count)\r\n\($1[1])\r\n")) }
            for start in stride(from: 0, to: stream.count, by: 7) { transport.reply(stream.subdata(in: start..<min(start + 7, stream.count))) }
        })
        let connection = try await connected(transport)
        let replies = try await withThrowingTaskGroup(of: (Int, RESPValue).self) { group in
            for index in 0..<100 {
                let arguments = command("ECHO", "reply-\(index)")
                group.addTask { (index, try await connection.send(arguments, mayWrite: false)) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        XCTAssertEqual(replies.count, 100)
        for (index, reply) in replies { XCTAssertEqual(reply, .bulkString(bytes("reply-\(index)"))) }
        XCTAssertEqual(transport.sent.count, 100)
        let state = await connection.state
        XCTAssertEqual(state, .ready)
    }

    func testTimeoutClosesConnection() async throws {
        let transport = FakeTransport(), sleeper = ManualSleeper()
        let connection = try await connected(transport, sleeper: sleeper)
        let slow = await inFlight(connection, transport, command("GET", "slow"), mayWrite: false, timeout: .seconds(1))
        let read = await inFlight(connection, transport, command("GET", "other"), mayWrite: false, timeout: .seconds(9))
        let write = await inFlight(connection, transport, command("SET", "k", "v"), mayWrite: true, timeout: .seconds(9))
        let armed = await eventually { sleeper.count(.seconds(1)) == 1 && sleeper.count(.seconds(9)) == 2 }
        XCTAssertTrue(armed)

        sleeper.fire(.seconds(1))
        let slowResult = await slow.value, readResult = await read.value, writeResult = await write.value
        XCTAssertEqual(slowResult, .failure(.timeout(.command)))
        XCTAssertEqual(readResult, .failure(.connectionLost))
        XCTAssertEqual(writeResult, .failure(.outcomeUnknown))
        let state = await connection.state
        XCTAssertEqual(state, .failed(.timeout(.command)))
        XCTAssertTrue(transport.isCancelled)

        // The late reply goes nowhere, and the next command is refused without touching the wire.
        transport.reply("+late\r\n")
        do {
            _ = try await connection.send(command("GET", "next"), mayWrite: false)
            XCTFail("sent on a timed-out connection")
        } catch { XCTAssertEqual(error, .notConnected) }
        XCTAssertEqual(transport.sent.count, 3)
        let disarmed = await eventually { sleeper.count(.seconds(9)) == 0 }
        XCTAssertTrue(disarmed, "remaining command timers were not cancelled")
    }

    func testDropAfterWriteReportsOutcomeUnknown() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        let write = await inFlight(connection, transport, command("SET", "k", "v"), mayWrite: true)
        let read = await inFlight(connection, transport, command("GET", "k"), mayWrite: false)

        transport.drop(.posix(54))  // ECONNRESET
        let writeResult = await write.value, readResult = await read.value
        XCTAssertEqual(writeResult, .failure(.outcomeUnknown))
        XCTAssertEqual(readResult, .failure(.connectionLost))
        let state = await connection.state
        XCTAssertEqual(state, .failed(.connectionFailed(.posix(54))))
        // Nothing re-sent, not even on the next attempt.
        do {
            _ = try await connection.send(command("SET", "k", "v"))
            XCTFail("sent on a dropped connection")
        } catch { XCTAssertEqual(error, .notConnected) }
        XCTAssertEqual(transport.commands, [["SET", "k", "v"], ["GET", "k"]])
    }

    func testCancellationFailsPendingCommands() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)

        // A caller that stops waiting gets CANCELLED at once; its reply, when it comes, is dropped in order.
        let abandoned = await inFlight(connection, transport, command("GET", "a"), mayWrite: false)
        let next = await inFlight(connection, transport, command("GET", "b"), mayWrite: false)
        abandoned.cancel()
        let abandonedResult = await abandoned.value
        XCTAssertEqual(abandonedResult, .failure(.cancelled))
        transport.reply("$1\r\nA\r\n$1\r\nB\r\n")
        let nextResult = await next.value
        XCTAssertEqual(nextResult, .success(.bulkString(bytes("B"))))

        // A cancelled write can't be taken back: its outcome is unknown.
        let cancelledWrite = await inFlight(connection, transport, command("DEL", "a"), mayWrite: true)
        cancelledWrite.cancel()
        let cancelledWriteResult = await cancelledWrite.value
        XCTAssertEqual(cancelledWriteResult, .failure(.outcomeUnknown))
        transport.reply(":1\r\n")

        // close() mid-flight settles everything that is waiting.
        let read = await inFlight(connection, transport, command("GET", "c"), mayWrite: false)
        let write = await inFlight(connection, transport, command("SET", "c", "1"), mayWrite: true)
        await connection.close()
        let readResult = await read.value, writeResult = await write.value
        XCTAssertEqual(readResult, .failure(.cancelled))
        XCTAssertEqual(writeResult, .failure(.outcomeUnknown))
        let state = await connection.state
        XCTAssertEqual(state, .closed)
        XCTAssertTrue(transport.isCancelled)
        XCTAssertEqual(transport.sent.count, 5)
    }

    func testConnectsToUnixSocketEndpoint() async throws {
        let server = try UnixSocketServer()
        defer { server.stop() }
        let connection = RedisConnection(endpoint: .unixSocket(path: server.path))
        try await connection.connect()
        let pong = try await connection.send([bytes("PING")], mayWrite: false)
        XCTAssertEqual(pong, .simpleString(bytes("PONG")))
        // Binary-safe and pipelined over the real socket.
        let replies = try await withThrowingTaskGroup(of: (Int, RESPValue).self) { group in
            for index in 0..<1_000 { group.addTask { (index, try await connection.send([bytes("ECHO"), Data([0, 13, 10, UInt8(index % 256)])], mayWrite: false)) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        for (index, reply) in replies { XCTAssertEqual(reply, .bulkString(Data([0, 13, 10, UInt8(index % 256)]))) }
        await connection.close()
    }

    // MARK: - Connecting

    func testConnectTimeoutFailsAndCancelsTransport() async throws {
        let transport = FakeTransport(holdConnect: true), sleeper = ManualSleeper()
        let connection = RedisConnection(transport: transport, options: .init(connectTimeout: .seconds(3)), sleep: { try await sleeper.sleep($0) })
        let attempt = connecting(connection)
        let armed = await eventually { sleeper.count(.seconds(3)) == 1 }
        XCTAssertTrue(armed)
        sleeper.fire(.seconds(3))
        let error = await attempt.value
        XCTAssertEqual(error, .timeout(.connect))
        XCTAssertTrue(transport.isCancelled)
        let state = await connection.state
        XCTAssertEqual(state, .failed(.timeout(.connect)))
    }

    func testConnectFailureIsReportedWithItsCause() async {
        let connection = RedisConnection(transport: FakeTransport(connectFailure: .posix(61)), sleep: { try await ManualSleeper().sleep($0) })
        do {
            try await connection.connect()
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error, .connectionFailed(.posix(61)))
            XCTAssertEqual(error.code, "CONNECTION_FAILED")
        }
        let state = await connection.state
        XCTAssertEqual(state, .failed(.connectionFailed(.posix(61))))
    }

    func testCloseWhileConnectingCancels() async throws {
        let transport = FakeTransport(holdConnect: true)
        let connection = RedisConnection(transport: transport, sleep: { try await ManualSleeper().sleep($0) })
        let attempt = connecting(connection)
        let connecting = await eventually { await connection.state == .connecting }
        XCTAssertTrue(connecting)
        await connection.close()
        let error = await attempt.value
        XCTAssertEqual(error, .cancelled)
        let state = await connection.state
        XCTAssertEqual(state, .closed)
    }

    func testMissingUnixSocketFailsToConnect() async {
        let connection = RedisConnection(endpoint: .unixSocket(path: FileManager.default.temporaryDirectory.appendingPathComponent("keel-missing-\(UUID().uuidString.prefix(8)).sock").path))
        do {
            try await connection.connect()
            XCTFail("connected to a missing socket")
        } catch {
            guard case .connectionFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testConnectionsAreSingleUse() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        await connection.close()
        do {
            try await connection.connect()
            XCTFail("reconnected a closed connection")
        } catch { XCTAssertEqual(error, .notConnected) }
    }

    // MARK: - Replies

    func testSendBeforeConnectSendsNothing() async {
        let transport = FakeTransport()
        let connection = RedisConnection(transport: transport)
        do {
            _ = try await connection.send([bytes("PING")])
            XCTFail("sent before connecting")
        } catch { XCTAssertEqual(error, .notConnected) }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testServerErrorRepliesAreValues() async throws {
        let transport = FakeTransport(onSend: { transport, _ in transport.reply("-ERR unknown command 'HELLO'\r\n") })
        let connection = try await connected(transport)
        let reply = try await connection.send([bytes("HELLO"), bytes("3")])
        XCTAssertEqual(reply, .error(bytes("ERR unknown command 'HELLO'")))
        let state = await connection.state
        XCTAssertEqual(state, .ready)
    }

    func testPushesDoNotConsumeReplies() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        let read = await inFlight(connection, transport, command("GET", "k"), mayWrite: false)
        transport.reply(">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nk\r\n$1\r\nv\r\n")
        let result = await read.value
        XCTAssertEqual(result, .success(.bulkString(bytes("v"))))
        var pushes = connection.pushes.makeAsyncIterator()
        let push = await pushes.next()
        XCTAssertEqual(push, .push([.bulkString(bytes("invalidate")), .array([.bulkString(bytes("k"))])]))
    }

    func testUnexpectedReplyClosesConnection() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        transport.reply("+OK\r\n")
        let failed = await eventually { await connection.state == .failed(.unexpectedReply) }
        XCTAssertTrue(failed)
        XCTAssertTrue(transport.isCancelled)
    }

    func testMalformedReplyFailsHeadAndCloses() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        let read = await inFlight(connection, transport, command("GET", "k"), mayWrite: false)
        let write = await inFlight(connection, transport, command("SET", "k", "v"), mayWrite: true)
        transport.reply("HTTP/1.1 400 Bad Request\r\n")
        let readResult = await read.value, writeResult = await write.value
        XCTAssertEqual(readResult, .failure(.codec(.protocolError(.unknownType))))
        XCTAssertEqual(writeResult, .failure(.outcomeUnknown))
        let state = await connection.state
        XCTAssertEqual(state, .failed(.codec(.protocolError(.unknownType))))
    }

    func testOversizedReplyFailsWithLimitExceeded() async throws {
        let transport = FakeTransport()
        let connection = RedisConnection(transport: transport, options: .init(limits: RESPLimits(maxReplyBytes: 1_024, maxDepth: 8, maxElements: 16)))
        try await connection.connect()
        let read = await inFlight(connection, transport, command("GET", "big"), mayWrite: false)
        transport.reply("$100000000\r\n")
        let result = await read.value
        XCTAssertEqual(result, .failure(.codec(.limitExceeded(.replyBytes))))
        XCTAssertEqual(RedisError.codec(.limitExceeded(.replyBytes)).code, "LIMIT_EXCEEDED")
    }

    /// AC5: the protocol layer has no logging at all, so no argument or value byte can reach a log.
    func testProtocolLayerNeverLogs() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/KeelRESP")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["print(", "debugPrint(", "dump(", "NSLog(", "os_log(", "Logger(", "FileHandle.standardError"] {
                XCTAssertFalse(text.contains(call), "\(file.lastPathComponent) calls \(call)")
            }
        }
    }
}
